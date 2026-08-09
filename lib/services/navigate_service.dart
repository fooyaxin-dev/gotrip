import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/scheduler.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:compassx/compassx.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'route_service.dart';
import 'api_Keys.dart';

class NavigationController extends ChangeNotifier {

  // ── Config ──
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName;
  final TravelMode travelMode;
  final RouteResult? initialRoute;

  NavigationController({
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
    this.travelMode = TravelMode.drive,
    this.initialRoute,     
  });

  static const String _apiKey = ApiKeys.googleMaps;

  static const double _offRouteThresh  = 50.0; 
  static const double _arrivedThresh   = 30.0;
  static const int    _offRouteConfirm = 4;
  static const int    _stepConfirm     = 2;

  // ── Route ──
  List<LatLng>  polylinePoints  = [];
  List<LatLng>  walkedPoints    = [];
  List<LatLng>  remainingPoints = [];
  int           nearestIdx      = 0;
  LatLngBounds? routeBounds;

  // MAP-MATCH: cumulative distance (meters) from route start to each
  // polyline point. Built once per route in _applyRouteResult(). This is
  // the backbone of the new matcher — instead of hunting for "nearest
  // point index" with ad-hoc window sizes, we track *distance travelled
  // along the route* and bound the search window by how far the vehicle
  // could plausibly have moved since the last GPS fix. This is the same
  // basic idea Waze/Google Maps use (distance-along-route map matching),
  // just without the HMM-level sophistication.
  List<double> _cumDist = [];

  // MAP-MATCH: distance along the route (meters) of the current matched
  // position. This — not nearestIdx — is now the real source of truth;
  // nearestIdx is derived from it for backward-compat with the rest of
  // the code (stepEndPolylineIdx comparisons, progress splitting, etc).
  double _matchedDistAlongRoute = 0;

  // ── Steps ──
  List<NavStep> steps               = [];
  List<int>     stepEndPolylineIdx  = [];
  int           currentStepIndex   = 0;
  double        distToTurnEnd      = 0;
  int           _stepConfirmCount  = 0;
  int           _stepConfirmForIndex = -1;

  // ── ETA ──
  double remainingMeters   = 0;
  int    remainingSeconds  = 0;
  double _totalRouteMeters = 0;

  // ── Position ──
  LatLng?   userLatLng;
  LatLng?   targetLatLng;
  LatLng?   displayLatLng;
  Position? lastPos;

  // 高频位置更新专用通知器：只有地图子树监听它，箭头平滑移动不会
  // 波及 banner / ETA 面板等整页 UI。
  final ValueNotifier<LatLng?> positionNotifier = ValueNotifier<LatLng?>(null);

  // ── Heading ──
  double bearing = 0;

  // SMOOTHNESS FIX: the previous approach blended toward the target by a
  // fixed fraction (t) EVERY RENDERED FRAME, with no notion of real
  // elapsed time. That converges to a new GPS fix in ~5-6 frames
  // regardless of how far apart two fixes actually are — so the arrow
  // sits still, does a fast micro-snap, sits still again. That's the
  // "跳" (jump) you were seeing, and it's also frame-rate dependent
  // (120Hz phones converge twice as fast as 60Hz ones).
  //
  // What Waze/Google actually do (no proprietary magic involved): when a
  // new fix arrives, they animate from the CURRENT displayed position to
  // the new target over the REAL time gap since the previous fix, so the
  // glide always looks continuous no matter the fix cadence. This is
  // that same idea.
  LatLng?   _animFrom;
  double?   _animFromBearing;
  Duration? _lastTickElapsed;
  int       _animElapsedMs  = 0;
  int       _animDurationMs = 300;
  DateTime? _lastFixAt;

  /// Smoothed heading used for rendering (map/arrow rotation). `bearing`
  /// itself is the latest raw TARGET heading; this is the animated value
  /// that actually gets drawn, advancing in step with displayLatLng.
  double displayBearing = 0;

  // ── State ──
  bool    loading        = true;
  String? error;
  bool    isRerouting    = false;
  bool    hasArrived     = false;
  int     _offRouteCount = 0;

  // ── Icon ──
  BitmapDescriptor? arrowIcon;

  // ── Internals ──
  StreamSubscription<Position>?      _positionSub;
  StreamSubscription<CompassXEvent>? _compassSub;
  Ticker?       _ticker;
  VoidCallback? onArrived;

  // ── TTS ──
  final FlutterTts _tts = FlutterTts();
  String? _lastSpokenInstruction;
  bool    _ttsEnabled = true;
  bool get ttsEnabled => _ttsEnabled;

  // Distance reminder dedup — track which distance thresholds already spoken
  final Map<int, Set<int>> _spokenDistanceReminders = {};

  // ─────────────────────────────────────────────
  // Init & dispose
  // ─────────────────────────────────────────────

  Future<void> init(TickerProvider vsync) async {
    _ticker = vsync.createTicker(_onTick)..start();
    await _initTts();
    await _createArrowIcon();
    await _initWithRealLocation();
    _startCompass();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _positionSub?.cancel();
    _compassSub?.cancel();
    _tts.stop();
    positionNotifier.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Ticker — smooth display position interpolation
  // ─────────────────────────────────────────────

 void _onTick(Duration elapsed) {
    if (targetLatLng == null) return;

    // Real per-frame delta, clamped so a dropped/late frame can't cause
    // a huge single jump in the animation progress.
    final dtMs = _lastTickElapsed == null
        ? 16
        : (elapsed - _lastTickElapsed!).inMilliseconds.clamp(0, 100);
    _lastTickElapsed = elapsed;

    if (_animFrom == null) {
      // No animation in flight (e.g. very first fix) — just show target.
      displayLatLng  = targetLatLng;
      displayBearing = bearing;
    } else {
      _animElapsedMs += dtMs;
      final frac  = (_animElapsedMs / _animDurationMs).clamp(0.0, 1.0);
      final eased = _easeOutCubic(frac);

      displayLatLng = LatLng(
        _animFrom!.latitude  + (targetLatLng!.latitude  - _animFrom!.latitude)  * eased,
        _animFrom!.longitude + (targetLatLng!.longitude - _animFrom!.longitude) * eased,
      );
      displayBearing = _lerpBearing(_animFromBearing ?? bearing, bearing, eased);

      // Animation segment complete — hold here until the next GPS fix
      // kicks off a new one (see step 7 of the tracking listener).
      if (frac >= 1.0) _animFrom = null;
    }

    // PERF FIX: _updateRouteProgress used to be called here, on every
    // single tick (60-120Hz) — it allocates two new Lists by
    // take()/skip()-ing the whole polyline every call. At 60fps that's
    // constant GC pressure that causes dropped frames, which is what
    // actually looked like "跳" — not a problem with the interpolation
    // math itself. The walked/remaining split only needs to move when
    // nearestIdx changes, which only happens on a new GPS fix, so the
    // call now lives in the position-stream listener instead (see
    // _startTracking, step 1.5).
    positionNotifier.value = displayLatLng;
  }

  double _easeOutCubic(double t) => 1 - pow(1 - t, 3).toDouble();

  // ─────────────────────────────────────────────
  // GPS init
  // ─────────────────────────────────────────────

  Future<void> _initWithRealLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      userLatLng    = LatLng(pos.latitude, pos.longitude);
      targetLatLng  = userLatLng;
      displayLatLng = userLatLng;
      lastPos       = pos;
      positionNotifier.value = displayLatLng;

      if (initialRoute != null) {
        _resetRouteState();
        notifyListeners();
        await _applyRouteResult(initialRoute!);
      } else {
        await _loadRoute(pos.latitude, pos.longitude);
      }
    } catch (_) {
      userLatLng    = LatLng(startLat, startLng);
      targetLatLng  = userLatLng;
      displayLatLng = userLatLng;
      positionNotifier.value = displayLatLng;

      if (initialRoute != null) {
        _resetRouteState();
        notifyListeners();
        await _applyRouteResult(initialRoute!);
      } else {
        await _loadRoute(startLat, startLng);
      }
    }
  }

  // ─────────────────────────────────────────────
  // Arrow icon
  // ─────────────────────────────────────────────

  Future<void> _createArrowIcon() async {
    const size = 72.0;
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec);
    c.drawCircle(const Offset(size / 2, size / 2 + 2), size / 2 - 2,
        Paint()..color = Colors.black26);
    c.drawCircle(const Offset(size / 2, size / 2), size / 2 - 2,
        Paint()..color = Colors.white);
    c.drawCircle(const Offset(size / 2, size / 2), size / 2 - 6,
        Paint()..color = const Color(0xFF1A73E8));
    final arrow = Path()
      ..moveTo(size / 2, 10)
      ..lineTo(size / 2 + 15, size - 14)
      ..lineTo(size / 2, size - 22)
      ..lineTo(size / 2 - 15, size - 14)
      ..close();
    c.drawPath(arrow, Paint()..color = Colors.white);
    final img   = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes != null) {
      arrowIcon = BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────
  // TTS helpers
  // ─────────────────────────────────────────────

  Future<void> _speak(String text) async {
    if (!_ttsEnabled) return;
    if (text == _lastSpokenInstruction) return;
    _lastSpokenInstruction = text;
    await _tts.stop();
    await _tts.speak(text);
  }

  void toggleTts() {
    _ttsEnabled = !_ttsEnabled;
    if (!_ttsEnabled) _tts.stop();
    notifyListeners();
  }

  void _maybeAnnounceDistance(int stepIdx, double dist, String instruction) {
    final spoken = _spokenDistanceReminders.putIfAbsent(stepIdx, () => {});

    if (dist <= 300 && dist > 250 && !spoken.contains(300)) {
      spoken.add(300);
      _speak('In 300 meters, $instruction');
    } else if (dist <= 100 && dist > 80 && !spoken.contains(100)) {
      spoken.add(100);
      _speak('In 100 meters, $instruction');
    } else if (dist <= 30 && dist > 10 && !spoken.contains(30)) {
      spoken.add(30);
      _speak(instruction);
    }
  }

  // ─────────────────────────────────────────────
  // Compass
  // ─────────────────────────────────────────────

  void _startCompass() {
    _compassSub = CompassX.events.listen((e) {
      if (e.heading == null) return;
      final isMoving = (lastPos?.speed ?? 0) > 0.5;
      if (!isMoving) {
        bearing = _lerpBearing(bearing, e.heading!, 0.18);
        // Stationary case has no GPS-fix-triggered animation running, so
        // mirror directly into the rendered value instead of leaving it
        // stuck at whatever the last driving animation ended on.
        displayBearing = bearing;
        notifyListeners();
      }
    });
  }

  // ─────────────────────────────────────────────
  // Route loading
  // ─────────────────────────────────────────────

  String get _travelModeStr {
    switch (travelMode) {
      case TravelMode.walk:  return 'WALK';
      case TravelMode.drive: return 'DRIVE';
      case TravelMode.motor: return 'TWO_WHEELER';
    }
  }

  Future<void> _loadRoute(double fromLat, double fromLng, {bool isReroute = false}) async {
    _resetRouteState(isReroute: isReroute);
    notifyListeners();

    try {
      final result = await RouteService.instance.fetchNavigationRoute(
        fromLat: fromLat, fromLng: fromLng,
        toLat: endLat,   toLng: endLng,
        mode: travelMode,
      );
      await _applyRouteResult(result);
    } catch (e) {
      if (isReroute) {
        isRerouting = false;
        notifyListeners();
      } else {
        error   = e.toString();
        loading = false;
        notifyListeners();
      }
    }
  }

  void _resetRouteState({bool isReroute = false}) {
    currentStepIndex       = 0;
    steps                  = [];
    stepEndPolylineIdx     = [];
    _stepConfirmCount      = 0;
    _stepConfirmForIndex   = -1;
    _spokenDistanceReminders.clear();
    _lastSpokenInstruction = null;
    error                  = null;

    if (!isReroute) {
      _offRouteCount         = 0;
      loading                = true;
      isRerouting             = false;
      walkedPoints            = [];
      remainingPoints         = [];
      nearestIdx              = 0;
      _matchedDistAlongRoute  = 0;
    }
  }

  Future<void> _applyRouteResult(RouteResult result) async {
    final pts      = result.polylinePoints;
    final newSteps = result.steps;

    isRerouting    = false;
    _offRouteCount = 0;

    if (pts.length >= 2) bearing = _calcBearing(pts[0], pts[1]);

    polylinePoints     = pts;
    remainingPoints    = List.from(pts);
    walkedPoints       = [];
    steps              = newSteps;
    stepEndPolylineIdx = [
      for (final step in newSteps)
        _findNearestPolylineIndex(step.endLocation, pts),
    ];
    distToTurnEnd     = newSteps.isNotEmpty ? newSteps[0].distanceMeters : 0;
    remainingMeters   = result.distanceMeters;
    remainingSeconds  = result.durationSeconds;
    _totalRouteMeters = remainingMeters;
    routeBounds       = result.bounds;
    loading           = false;

    // MAP-MATCH: rebuild the cumulative-distance table for the new route
    // and reset the "distance travelled along route" tracker. This must
    // happen every time the polyline changes (first load AND reroute),
    // otherwise the matcher will search against stale distances from the
    // previous route and jump to nonsense indices.
    _cumDist               = _buildCumDist(pts);
    nearestIdx              = 0;
    _matchedDistAlongRoute  = 0;

    if (displayLatLng != null) _updateRouteProgress(displayLatLng!);

    notifyListeners();

    if (newSteps.isNotEmpty) {
      _speak(newSteps[0].instruction);
    }

    _startTracking();
  }
  
  
  // ─────────────────────────────────────────────
  // GPS tracking
  // ─────────────────────────────────────────────

  void _startTracking() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy:         LocationAccuracy.bestForNavigation,
        distanceFilter:   0,
        intervalDuration: const Duration(milliseconds: 200),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText:  'Navigation is active',
          notificationTitle: 'Turn-by-turn Navigation',
          enableWakeLock:    true,
        ),
      ),
    ).listen((raw) async {
      if (raw.accuracy > 30) return;

      final rawLatLng = LatLng(raw.latitude, raw.longitude);
      final isMoving  = raw.speed > 0.5;

      // ── 1. Map-match this fix against the route ──
      // MAP-MATCH: single unified matcher replaces the old two-stage
      // "wide nearest-index fallback" + separate "_snapToRoute" logic.
      // It searches only the stretch of route the vehicle could
      // plausibly have reached since the last fix (bounded by speed),
      // and uses GPS heading as a tiebreaker so it doesn't jump onto a
      // parallel road / the far side of a roundabout / an unrelated
      // nearby segment just because it's geometrically closer.
      final match = _mapMatch(
        rawLatLng,
        speedMps: raw.speed,
        isMoving: isMoving,
        gpsHeading: raw.heading, // Position.heading — the LatLng param below has no such field
      );

      LatLng snapped;
      double perpDistToRoute;

      if (match != null) {
        nearestIdx             = match.idx;
        _matchedDistAlongRoute = match.distAlongRoute;
        perpDistToRoute        = match.perpDist;
        final threshold = travelMode == TravelMode.walk ? 15.0 : 30.0;
        snapped = match.perpDist <= threshold ? match.snapped : rawLatLng;
      } else {
        snapped          = rawLatLng;
        perpDistToRoute  = double.infinity;
      }

      // ── 1.5. Update walked/remaining polyline split ──
      // PERF FIX: moved here from _onTick. nearestIdx only changes on a
      // fix (every ~200ms-1s), not every animation frame, so this only
      // needs to run here — same visual result, far fewer allocations.
      if (polylinePoints.isNotEmpty) {
        _updateRouteProgress(snapped);
      }

      // ── 2. Update bearing from polyline look-ahead (moving only) ──
      if (polylinePoints.isNotEmpty && isMoving) {
        final lookAhead = travelMode == TravelMode.walk ? 2 : 5;
        final aheadIdx  = (nearestIdx + lookAhead)
            .clamp(0, polylinePoints.length - 1);
        if (aheadIdx > nearestIdx) {
          final newBearing = _calcBearing(
              polylinePoints[nearestIdx], polylinePoints[aheadIdx]);
          final t = travelMode == TravelMode.walk ? 0.16 : 0.32;
          bearing = _lerpBearing(bearing, newBearing, t);
        }
      }

      // ── 3. Arrived check ──
      final isLastStep = currentStepIndex >= steps.length - 1;
      if (_dist(rawLatLng, LatLng(endLat, endLng)) <= _arrivedThresh
          && isLastStep && !hasArrived) {
        hasArrived = true;
        _positionSub?.cancel();
        await _speak('You have arrived at your destination');
        onArrived?.call();
        notifyListeners();
        return;
      }

      // ── 4. Off-route check ──
      // MAP-MATCH: reuses the perpendicular distance the matcher already
      // computed instead of re-scanning the route a second time.
      if (isMoving && !isRerouting && polylinePoints.isNotEmpty) {
        final threshold = travelMode == TravelMode.walk ? 25.0 : _offRouteThresh;
        if (perpDistToRoute > threshold) {
          _offRouteCount++;
          if (_offRouteCount >= _offRouteConfirm) {
            isRerouting = true;
            notifyListeners();
            await _speak('Off route, recalculating');
            _loadRoute(raw.latitude, raw.longitude, isReroute: true);
            return;
          }
        } else {
          _offRouteCount = 0;
        }
      }

      // ── 5. Step advancement ──
      if (steps.isNotEmpty && currentStepIndex < steps.length - 1) {
        final distToEnd         = _dist(rawLatLng, steps[currentStepIndex].endLocation);
        final currentStepEndIdx = stepEndPolylineIdx.isNotEmpty
            ? stepEndPolylineIdx[currentStepIndex] : -1;
        final reachedByPolyline = currentStepEndIdx >= 0
            && nearestIdx >= max(0, currentStepEndIdx - 1);
        final reachedByDistance =
            distToEnd < (travelMode == TravelMode.walk ? 10 : 15);

        if (reachedByPolyline || reachedByDistance) {
          if (_stepConfirmForIndex != currentStepIndex) {
            _stepConfirmCount    = 0;
            _stepConfirmForIndex = currentStepIndex;
          }
          _stepConfirmCount++;

          if (_stepConfirmCount >= _stepConfirm) {
            _stepConfirmCount    = 0;
            _stepConfirmForIndex = -1;
            currentStepIndex++;
            distToTurnEnd = steps[currentStepIndex].distanceMeters;
            await _speak(steps[currentStepIndex].instruction);
          }
        } else {
          if (_stepConfirmForIndex == currentStepIndex) {
            _stepConfirmCount    = 0;
            _stepConfirmForIndex = -1;
          }
        }
      }

      // ── 6. ETA update ──
      if (steps.isNotEmpty) {
        final step = steps[currentStepIndex]; // physical road segment you're on — used for distance/ETA math only
        distToTurnEnd = _dist(rawLatLng, step.endLocation)
            .clamp(0.0, step.distanceMeters);

        double futureM = 0;
        int    futureS = 0;
        for (int i = currentStepIndex + 1; i < steps.length; i++) {
          futureM += steps[i].distanceMeters;
          futureS += steps[i].durationSeconds;
        }
        final ratio      = step.distanceMeters > 0
            ? distToTurnEnd / step.distanceMeters : 0.0;
        remainingMeters  = distToTurnEnd + futureM;
        remainingSeconds = (step.durationSeconds * ratio).toInt() + futureS;

        // VOICE FIX: a step's own instruction describes the maneuver
        // already performed at ITS start — the maneuver you're actually
        // counting down to (distToTurnEnd → 0) is the NEXT step's
        // instruction. Announcing the current step's own instruction
        // here made the 300m/100m/30m reminders name the wrong turn
        // (mirrors the `currentStep` getter fix below).
        final upcoming = (currentStepIndex + 1 < steps.length)
            ? steps[currentStepIndex + 1]
            : step; // last leg: no further maneuver, just arrival
        _maybeAnnounceDistance(
            currentStepIndex, distToTurnEnd, upcoming.instruction);
      }

      // ── 7. Kick off a new smooth animation segment toward this fix ──
      // SMOOTHNESS FIX: animate from wherever the arrow is RIGHT NOW to
      // the new snapped position, over the REAL time elapsed since the
      // previous fix (clamped to a sane range). The Ticker (_onTick)
      // advances this every frame using real dt, so the glide always
      // matches the actual fix cadence instead of a fixed per-frame %.
      final now   = DateTime.now();
      final gapMs = _lastFixAt == null
          ? 300
          : now.difference(_lastFixAt!).inMilliseconds;
      _lastFixAt = now;

      _animFrom        = displayLatLng ?? snapped;
      _animFromBearing = displayBearing;
      _animElapsedMs   = 0;
      _animDurationMs  = gapMs.clamp(150, 900);

      lastPos       = raw;
      userLatLng    = snapped;
      targetLatLng  = snapped;
      notifyListeners();
    });
  }

  // ─────────────────────────────────────────────
  // MAP-MATCH core
  // ─────────────────────────────────────────────

  /// Result of matching a raw GPS fix onto the route polyline.
  ///
  /// [idx] — polyline segment index the fix matched to (kept for
  /// backward-compat with step-advancement / look-ahead-bearing code).
  /// [snapped] — the projected point on that segment.
  /// [perpDist] — perpendicular distance from the raw fix to [snapped].
  /// [distAlongRoute] — cumulative distance from route start to [snapped].
  final _matchCache = <int, double>{};

  /// Finds the polyline index whose cumulative distance is >= [d].
  /// Route sizes here are small enough (a few hundred points) that a
  /// linear scan is fine — this only runs once per GPS fix, not per frame.
  int _idxAtDistance(double d) {
    for (int i = 0; i < _cumDist.length; i++) {
      if (_cumDist[i] >= d) return i;
    }
    return max(_cumDist.length - 1, 0);
  }

  /// Projects [raw] onto the route, searching only the window of route
  /// the vehicle could plausibly have reached since the last fix
  /// (bounded by speed), and using GPS heading as a tiebreaker against
  /// geometrically-close-but-wrong segments (parallel roads, the far
  /// side of a roundabout, an overlapping loop in the polyline, etc).
 _MatchResult? _mapMatch(LatLng raw, {
    required double speedMps,
    required bool isMoving,
    required double gpsHeading,
  }) {
    if (polylinePoints.length < 2 || _cumDist.isEmpty) return null;

    final currentDist = _matchedDistAlongRoute;

    // FIX: previously this was `(speedMps * 1.5).clamp(20.0, 200.0)` with
    // no upper cap other than 200m. A single noisy GPS fix reporting an
    // inflated speed (common right at a turn, where GPS course/speed is
    // least reliable) could push the search window past an entire
    // corner, and the matcher would then snap onto the segment on the
    // OTHER side of the turn — _updateRouteProgress then draws a
    // straight line from the current position to that far snapped
    // point, which is the "抄近路直线" you were seeing. Capping
    // maxAdvance per travel mode means a single bad speed reading can't
    // blow the window open wide enough to skip a corner.
    final double speedCap = travelMode == TravelMode.walk ? 25.0 : 80.0;
    final double maxAdvance = isMoving
        ? (speedMps * 1.5).clamp(20.0, speedCap)
        : 20.0;
    const double behindSlack = 15.0; // small backward search for jitter near a vertex

    final double windowStart =
        (currentDist - behindSlack).clamp(0.0, _cumDist.last);
    final double windowEnd =
        (currentDist + maxAdvance + 50.0).clamp(0.0, _cumDist.last);

    final int idxStart = _idxAtDistance(windowStart);
    final int idxEnd    = min(_idxAtDistance(windowEnd) + 1, polylinePoints.length - 1);

    int    bestIdx        = nearestIdx.clamp(0, polylinePoints.length - 2);
    double bestScore       = double.infinity;
    double bestPerp        = double.infinity;
    LatLng bestProjected   = raw;
    double bestDistAlong   = currentDist;

    for (int i = idxStart; i < idxEnd; i++) {
      final projected = _projectOntoSegment(raw, polylinePoints[i], polylinePoints[i + 1]);
      final perp       = _dist(raw, projected);

      // FIX: previously a far-but-well-oriented segment could still win
      // over a close-but-badly-oriented one purely because of the
      // additive penalty scoring — near a corner, the segment just past
      // the turn can score deceptively well the instant the phone's
      // compass starts swinging toward the new heading, even though the
      // GPS fix itself is still physically on the pre-turn segment. Skip
      // any candidate whose raw perpendicular distance is clearly too
      // far to be a plausible match (>60m) regardless of heading score,
      // so heading can only break ties between genuinely close segments,
      // never pull the match across a corner by itself.
      if (perp > 60.0) continue;

      double penalty = 0;
      if (isMoving) {
        final segBearing = _calcBearing(polylinePoints[i], polylinePoints[i + 1]);
        final diff = ((gpsHeading - segBearing + 540) % 360) - 180;
        penalty = (diff.abs() / 180.0) * 40.0;
      }

      final score = perp + penalty;
      if (score < bestScore) {
        bestScore     = score;
        bestPerp      = perp;
        bestIdx       = i;
        bestProjected = projected;
        final segLen = _dist(polylinePoints[i], polylinePoints[i + 1]);
        final t = segLen > 0
            ? (_dist(polylinePoints[i], projected) / segLen).clamp(0.0, 1.0)
            : 0.0;
        bestDistAlong = _cumDist[i] + segLen * t;
      }
    }

    // If every candidate in the window was rejected by the 60m perp-dist
    // gate above, bestScore never improved from infinity — fall back to
    // holding the previous match rather than snapping to whatever raw
    // was closest to (which could still be across the corner).
    if (bestScore == double.infinity) {
      return _MatchResult(nearestIdx, raw, double.infinity, currentDist);
    }

    // Never let matched progress move backward along the route (small
    // tolerance for GPS jitter right at a vertex) — routes don't reverse.
    if (bestDistAlong < currentDist - 5.0) {
      bestDistAlong = currentDist;
      bestIdx       = nearestIdx;
    }

    return _MatchResult(bestIdx, bestProjected, bestPerp, bestDistAlong);
  }

  // ─────────────────────────────────────────────
  // Route progress (walked vs remaining polyline)
  // ─────────────────────────────────────────────

  void _updateRouteProgress(LatLng snapped) {
    if (polylinePoints.isEmpty) return;

    final walked = <LatLng>[];
    if (nearestIdx > 0) walked.addAll(polylinePoints.take(nearestIdx));
    walked.add(snapped);

    final remaining = <LatLng>[snapped];
    if (nearestIdx < polylinePoints.length) {
      remaining.addAll(polylinePoints.skip(nearestIdx));
    }

    walkedPoints    = walked;
    remainingPoints = remaining;
  }

  // ─────────────────────────────────────────────
  // Math helpers
  // ─────────────────────────────────────────────

  double _dist(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(
          a.latitude, a.longitude, b.latitude, b.longitude);

  double _calcBearing(LatLng from, LatLng to) {
    final dLng = (to.longitude - from.longitude) * pi / 180;
    final phi1 = from.latitude * pi / 180;
    final phi2 = to.latitude   * pi / 180;
    final y    = sin(dLng) * cos(phi2);
    final x    = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  double _lerpBearing(double current, double target, double t) {
    final diff = ((target - current + 540) % 360) - 180;
    return (current + diff * t + 360) % 360;
  }

  LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude,  py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    if (lenSq == 0) return a;
    final t  = ((px - ax) * dx + (py - ay) * dy) / lenSq;
    final tc = t.clamp(0.0, 1.0);
    return LatLng(ay + tc * dy, ax + tc * dx);
  }

  List<double> _buildCumDist(List<LatLng> pts) {
    if (pts.isEmpty) return [];
    final cum = <double>[0];
    for (int i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + _dist(pts[i - 1], pts[i]));
    }
    return cum;
  }

  int _findNearestPolylineIndex(LatLng point, List<LatLng> poly,
      {int? start, int? end}) {
    if (poly.isEmpty) return 0;
    final from    = (start ?? 0).clamp(0, poly.length - 1);
    final to      = (end ?? poly.length - 1).clamp(0, poly.length - 1);
    var bestIdx   = from;
    var bestDist  = double.infinity;
    for (int i = from; i <= to; i++) {
      final d = _dist(point, poly[i]);
      if (d < bestDist) { bestDist = d; bestIdx = i; }
    }
    return bestIdx;
  }

  int _parseSecs(String s) =>
      int.tryParse(s.replaceAll('s', '').trim()) ?? 0;

  String _sanitizeInstruction(String instruction) {
    var text = instruction.replaceAll(RegExp(r'<[^>]*>'), '');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    text = text.replaceFirst(RegExp(r'^Head\s+\w+\s+'), 'Go ');
    text = text.replaceFirst(
        'Your destination is on the left', 'Destination on the left');
    text = text.replaceFirst(
        'Your destination is on the right', 'Destination on the right');
    return text;
  }

  List<LatLng> _decode(String encoded) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0; result = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      pts.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return pts;
  }

  // ─────────────────────────────────────────────
  // Public getters used by UI
  // ─────────────────────────────────────────────

  double get progress {
    if (_totalRouteMeters <= 0) return 0.0;
    final walked = _totalRouteMeters - remainingMeters;
    return (walked / _totalRouteMeters).clamp(0.0, 1.0);
  }

  // VOICE/BANNER FIX: this used to return steps[currentStepIndex] — the
  // segment you're physically driving on, whose instruction describes
  // the maneuver already performed at ITS start. What the banner (and
  // voice) should show is the UPCOMING maneuver, paired with
  // distToTurnEnd counting down to it — that's steps[currentStepIndex+1].
  // Getter name is kept the same on purpose so GuidePage needs no changes.
  // Final leg has no further maneuver, so it falls back to the last step
  // itself (which typically already reads like "Destination on the right").
  NavStep? get currentStep {
    if (steps.isEmpty) return null;
    if (currentStepIndex + 1 < steps.length) return steps[currentStepIndex + 1];
    return steps[currentStepIndex];
  }

  // "Then ..." preview — the maneuver AFTER the one currentStep now
  // points to. Shifted by one index to match the fix above.
  NavStep? get nextStep {
    if (steps.isEmpty) return null;
    final threshold = travelMode == TravelMode.walk ? 60.0 : 300.0;
    if (currentStepIndex + 2 < steps.length && distToTurnEnd < threshold) {
      return steps[currentStepIndex + 2];
    }
    return null;
  }

  double get cameraBearing {
    if (travelMode == TravelMode.walk) {
      return (lastPos?.speed ?? 0) > 1.1 ? displayBearing : 0;
    }
    return displayBearing;
  }
}

/// Result of a single map-match: which route segment a raw GPS fix landed
/// on, the projected point, how far off the route it was, and how far
/// along the route (in meters from the start) that projection is.
class _MatchResult {
  final int idx;
  final LatLng snapped;
  final double perpDist;
  final double distAlongRoute;
  _MatchResult(this.idx, this.snapped, this.perpDist, this.distAlongRoute);
}