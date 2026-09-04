import 'dart:async';
import 'dart:math';
import 'package:flutter/scheduler.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:compassx/compassx.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'route_service.dart';
import 'api_Keys.dart';

typedef RouteFetcher = Future<RouteResult> Function({
  required double fromLat,
  required double fromLng,
  required double toLat,
  required double toLng,
  required TravelMode mode,
});

enum NavigationRouteUpdateState {
  idle,
  searching,
  updated,
  failed,
}

class NavigationController extends ChangeNotifier {
  // ── Config ──
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName;
  final TravelMode travelMode;
  final RouteResult? initialRoute;
  final RouteFetcher? routeFetcher;

  NavigationController({
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
    this.travelMode = TravelMode.drive,
    this.initialRoute,
    this.routeFetcher,
  });

  static const String _apiKey = ApiKeys.googleMaps;

  static const double _offRouteThresh = 50.0;
  static const double _arrivedThresh = 30.0;
  static const int _offRouteConfirm = 4;
  static const int _stepConfirm = 2;

  // ── Route ──
  List<LatLng> polylinePoints = [];
  List<LatLng> walkedPoints = [];
  List<LatLng> remainingPoints = [];
  int nearestIdx = 0; // matched segment START index
  LatLngBounds? routeBounds;

  // Distance from route start to each polyline vertex.
  List<double> _cumDist = [];

  // Single source of truth for navigation progress.
  double _matchedDistAlongRoute = 0;

  // Last trusted point projected onto the route.
  LatLng? _lastMatchedLatLng;

  // Recovery timer: this is deliberately the time of the last REAL
  // forward route-progress acceptance, not merely the last raw GPS fix.
  // If matching temporarily stalls, the forward search window therefore
  // grows until the matcher can catch up instead of deadlocking.
  DateTime? _lastAcceptedProgressAt;

  // Step-end locations represented as distance-along-route values.
  List<double> _stepEndRouteDist = [];

  // Off-route is evaluated independently from map-match confidence.
  DateTime? _offRouteSince;
  DateTime? _lastOffRouteCheckAt;
  double _lastRawDistanceToRoute = 0;

  // Debug output is throttled so logging itself does not make map motion janky.
  DateTime? _lastDebugLogAt;

  // ── Temporary on-screen navigation diagnostics ──
  // These values are intentionally public through read-only getters below.
  // They let GuidePage record the controller's internal state during a
  // wireless road test, so a screen recording is enough to diagnose issues.
  String _debugTrackingState = 'WAIT GPS';
  double _debugRecoverySeconds = 0;
  double _debugMatchPerpDistance = double.infinity;
  double _debugSpeedMps = 0;
  double _debugGpsAccuracy = 0;
  double _debugHandleMs = 0;
  int _debugRouteVersion = 0;
  double _debugPredictionLeadMeters = 0;

  String get debugTrackingState => _debugTrackingState;
  double get debugRecoverySeconds => _debugRecoverySeconds;
  double get debugMatchPerpDistance => _debugMatchPerpDistance;
  double get debugRawDistanceToRoute => _lastRawDistanceToRoute;
  double get debugMatchedProgress => _matchedDistAlongRoute;
  double get displayDistAlongRoute => _displayDistAlongRoute;
  int get displayNearestIdx => _cumDist.length >= 2
      ? _segmentIdxAtDistance(_displayDistAlongRoute)
      : nearestIdx;

  /// Read-only production getter returning the current visual point on the
  /// active route polyline at [_displayDistAlongRoute].
  ///
  /// Always lies strictly on the route geometry and does not pull off-road
  /// even when the navigation marker temporarily renders raw GPS during recovery.
  LatLng? get displayedRoutePoint {
    if (polylinePoints.length < 2) return null;
    return _pointAtRouteDistance(_displayDistAlongRoute);
  }

  double get debugSpeedKmh => (_debugSpeedMps * 3.6).clamp(0.0, 250.0);
  double get debugSpeedMps => _debugSpeedMps;
  double get debugGpsAccuracy => _debugGpsAccuracy;

  double get debugGpsAgeSeconds {
    if (_lastGpsStreamEventAt == null) return double.infinity;
    return _currentTime.difference(_lastGpsStreamEventAt!).inMilliseconds /
        1000.0;
  }

  double get debugNavigationFixAgeSeconds {
    if (_lastNavigationFixAt == null) return double.infinity;
    return _currentTime.difference(_lastNavigationFixAt!).inMilliseconds /
        1000.0;
  }

  double get debugAcceptedProgressAgeSeconds {
    if (_lastAcceptedProgressAt == null) return double.infinity;
    return _currentTime.difference(_lastAcceptedProgressAt!).inMilliseconds /
        1000.0;
  }

  double get debugVisualLagMeters =>
      (_matchedDistAlongRoute - _displayDistAlongRoute).abs();

  /// Signed visual lead over accepted route progress:
  /// positive when Visual is ahead (e.g. dead reckoning),
  /// negative when Visual is lagging behind accepted progress.
  double get debugSignedVisualLeadMeters =>
      _displayDistAlongRoute - _matchedDistAlongRoute;

  int get debugRouteVersion => _debugRouteVersion;
  int get debugRoutePointCount => polylinePoints.length;
  double get debugPredictionLeadMeters => _debugPredictionLeadMeters;
  double get debugHandleMs => _debugHandleMs;
  double get debugCameraBearing => cameraBearing;
  int get debugNearestSegment => nearestIdx;
  int get debugCurrentStepIndex => currentStepIndex;

  // ── Steps ──
  List<NavStep> steps = [];
  List<int> stepEndPolylineIdx = [];
  int currentStepIndex = 0;
  double distToTurnEnd = 0;
  int _stepConfirmCount = 0;
  int _stepConfirmForIndex = -1;

  // ── ETA ──
  double remainingMeters = 0;
  int remainingSeconds = 0;
  double _totalRouteMeters = 0;

  // Baseline ETA from RouteResult.durationSeconds. For DRIVE/MOTOR this is
  // the traffic-aware route duration returned by Google Routes API.
  // Navigation updates scale this single baseline by remaining route
  // distance instead of mixing it with per-step staticDuration values.
  int _routeBaselineSeconds = 0;

  // ── Position ──
  LatLng? userLatLng;
  LatLng? targetLatLng;
  LatLng? displayLatLng;
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
  // Visual render state. Map matching stays GPS-driven, while the on-screen
  // vehicle advances continuously along route distance between GPS fixes.
  Duration? _lastTickElapsed;
  DateTime? _lastFixAt;
  double _displayDistAlongRoute = 0.0;
  bool _displayRouteInitialised = false;

  int _lastVisualPublishMs = 0;
  static const int _visualPublishIntervalMs = 40;

  /// Smoothed heading used for rendering (map/arrow rotation). `bearing`
  /// itself is the latest raw TARGET heading; this is the animated value
  /// that actually gets drawn, advancing in step with displayLatLng.
  double displayBearing = 0;

  // ── State ──
  bool loading = true;
  String? error;
  bool isRerouting = false;

  // Network-degraded navigation. If rerouting fails, keep the existing
  // route and GPS tracking alive instead of clearing the user's guidance.
  bool isOfflineNavigation = false;
  String? networkNotice;
  bool hasArrived = false;
  int _offRouteCount = 0;

  // Route-joining state:
  // A user may intentionally use a familiar road at the beginning and only
  // need guidance afterwards. Until the route has actually been joined once,
  // divergence is treated as a "join/rebase" situation rather than an error.
  bool _hasJoinedPlannedRoute = false;
  DateTime? _routeSessionStartedAt;

  // ── Icon ──
  BitmapDescriptor? arrowIcon;

  // ── Internals ──
  StreamSubscription<Position>? _positionSub;

  // Startup GPS acquisition helpers.
  // The live position stream is started BEFORE route loading and is not
  // restarted when the route arrives. This avoids the long "WAIT GPS"
  // period seen in the road-test video.
  DateTime? _lastGpsStreamEventAt;
  DateTime? _lastNavigationFixAt;
  DateTime? _lastSpeedSampleAt;
  Timer? _startupGpsWatchdog;

  /// Optional clock seam for deterministic unit testing.
  @visibleForTesting
  DateTime Function()? testClock;

  DateTime get _currentTime => testClock?.call() ?? DateTime.now();

  @visibleForTesting
  double? get debugLastSpeedDtFix => _debugLastSpeedDtFix;
  double? _debugLastSpeedDtFix;

  @visibleForTesting
  DateTime? get lastSpeedSampleAt => _lastSpeedSampleAt;

  // Continuous stream-health recovery. The old watchdog only protected
  // startup and cancelled itself permanently after the first live GPS fix.
  // If the Android stream later stalled, navigation could remain frozen
  // indefinitely. This watchdog stays alive for the entire navigation session.
  Timer? _gpsHealthWatchdog;
  bool _gpsHealthFallbackBusy = false;
  bool _gpsStreamRestarting = false;
  DateTime? _lastHealthFallbackAt;

  LatLng? _lastRawMotionFix;
  DateTime? _lastRawMotionFixAt;
  bool _startupFallbackBusy = false;
  int _startupFallbackAttempts = 0;
  StreamSubscription<CompassXEvent>? _compassSub;
  Ticker? _ticker;
  VoidCallback? onArrived;

  // ── TTS ──
  final FlutterTts _tts = FlutterTts();
  Future<void>? _ttsReady;
  String? _lastSpokenInstruction;
  bool _ttsEnabled = true;
  bool get ttsEnabled => _ttsEnabled;

  // Distance reminder dedup — track which distance thresholds already spoken
  final Map<int, Set<int>> _spokenDistanceReminders = {};

  // ── Traffic refresh & request gating ──
  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  bool _isRouteRequestInFlight = false;
  bool get isRouteRequestInFlight => _isRouteRequestInFlight;

  int _activeRouteGeneration = 0;
  int get activeRouteGeneration => _activeRouteGeneration;

  String _navigationSessionId = '';
  String get navigationSessionId => _navigationSessionId;

  int _trafficRequestId = 0;
  DateTime? _lastSuccessfulRouteOrRefreshAt;
  DateTime? _lastTrafficAttemptAt;
  Timer? _trafficRefreshTimer;
  DateTime? _lastTrafficCheckLogAt;
  LatLng? _pendingReroutePosition;

  bool get isTrafficRefreshActive => _trafficRefreshTimer?.isActive ?? false;

  NavigationRouteUpdateState _routeUpdateState =
      NavigationRouteUpdateState.idle;
  NavigationRouteUpdateState get routeUpdateState => _routeUpdateState;

  String? _routeUpdateMessage;
  String? get routeUpdateMessage => _routeUpdateMessage;

  Timer? _routeUpdateDismissTimer;
  int _consecutiveOffRouteFixes = 0;
  DateTime? _lastOffRouteCheckLogAt;

  void _setRouteUpdateState(
    NavigationRouteUpdateState state, {
    String? message,
    Duration? autoDismissDuration,
  }) {
    if (_isDisposed || hasArrived) return;
    _routeUpdateDismissTimer?.cancel();
    _routeUpdateState = state;
    _routeUpdateMessage = message;
    notifyListeners();

    if (autoDismissDuration != null) {
      _routeUpdateDismissTimer = Timer(autoDismissDuration, () {
        if (_isDisposed || hasArrived) return;
        _routeUpdateState = NavigationRouteUpdateState.idle;
        _routeUpdateMessage = null;
        notifyListeners();
      });
    }
  }

  void _cancelRouteUpdateFeedback() {
    _routeUpdateDismissTimer?.cancel();
    _routeUpdateDismissTimer = null;
    _routeUpdateState = NavigationRouteUpdateState.idle;
    _routeUpdateMessage = null;
  }

  // ─────────────────────────────────────────────
  // Init & dispose
  // ─────────────────────────────────────────────

  Future<void> init(TickerProvider vsync) async {
    if (!startLat.isFinite ||
        !startLng.isFinite ||
        !endLat.isFinite ||
        !endLng.isFinite ||
        (startLat == 0.0 && startLng == 0.0) ||
        (endLat == 0.0 && endLng == 0.0)) {
      error = 'Invalid route coordinates';
      loading = false;
      notifyListeners();
      return;
    }

    _navigationSessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _lastSuccessfulRouteOrRefreshAt = DateTime.now();
    _routeSessionStartedAt = DateTime.now();
    _lastSpeedSampleAt = null;
    _lastNavigationFixAt = null;
    _ticker = vsync.createTicker(_onTick)..start();

    // GPS/navigation startup is the critical path.
    // TTS setup and arrow bitmap creation must not delay location tracking.
    _startCompass();

    _ttsReady = _initTts();
    unawaited(_ttsReady!);
    unawaited(_createArrowIcon());

    startTrafficRefreshTimer();

    await _initWithRealLocation();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _activeRouteGeneration++;
    _pendingReroutePosition = null;
    _lastSpeedSampleAt = null;
    stopTrafficRefreshTimer();
    _cancelRouteUpdateFeedback();
    _ticker?.dispose();
    _positionSub?.cancel();
    _startupGpsWatchdog?.cancel();
    _gpsHealthWatchdog?.cancel();
    _compassSub?.cancel();
    try {
      _tts.stop().catchError((_) => null);
    } catch (_) {}
    positionNotifier.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Ticker — smooth display position interpolation
  // ─────────────────────────────────────────────

  void _onTick(Duration elapsed) {
    if (targetLatLng == null) return;

    final dtMs = _lastTickElapsed == null
        ? 16
        : (elapsed - _lastTickElapsed!).inMilliseconds.clamp(0, 80);
    _lastTickElapsed = elapsed;

    final dt = dtMs / 1000.0;

    if (_cumDist.length < 2 || polylinePoints.length < 2) {
      displayLatLng = targetLatLng;
      displayBearing = bearing;
      positionNotifier.value = displayLatLng;
      return;
    }

    if (!_displayRouteInitialised) {
      _displayDistAlongRoute = _matchedDistAlongRoute;
      _displayRouteInitialised = true;
    }

    final routeEnd = _cumDist.last;
    final speed = _debugSpeedMps.clamp(0.0, 45.0);

    // Route-constrained dead reckoning.
    //
    // The diagnostic overlay proved that the Android location stream can go
    // several seconds without delivering a new Position even while the car is
    // moving. The old renderer only predicted ~10 m ahead, so at ~40 km/h it
    // moved smoothly for roughly one second, reached that 10 m ceiling, then
    // froze until the next GPS burst. That is exactly the observed
    // "smooth section -> pause -> smooth section" pattern.
    //
    // Keep rendering forward along the already-known route using the last
    // trusted speed while GPS is temporarily silent. This does NOT change map
    // matching or route progress; _matchedDistAlongRoute remains GPS-driven.
    final gpsAgeSeconds = _lastNavigationFixAt == null
        ? 0.0
        : _currentTime.difference(_lastNavigationFixAt!).inMilliseconds /
            1000.0;

    // Conservative evidence-based dead-reckoning window:
    // Active only when vehicle is clearly moving (speed > 1.2 m/s), GPS accuracy is good,
    // and fix age is fresh (< 2.0s).
    final canDeadReckon = speed > 1.2 &&
        _debugGpsAccuracy.isFinite &&
        _debugGpsAccuracy <= 30.0 &&
        gpsAgeSeconds < 2.0 &&
        (_debugTrackingState == 'MATCH' || _debugTrackingState == 'MATCH~');

    // Small evidence-based forward allowance ahead of accepted route progress:
    // - Walk: at most 1.5 meters (~1 step).
    // - Drive / Motor: at most 4.0 meters (~1 car length, well within GPS accuracy).
    // During the inter-fix gap (<= 0.8s), provide subtle glide lead.
    // If GPS silence exceeds 0.8s, confidence decays smoothly to avoid overshooting
    // if the vehicle is slowing down or stopping.
    final maxPredictionLead = travelMode == TravelMode.walk ? 1.5 : 4.0;
    double predictionLead = 0.0;

    if (canDeadReckon) {
      final latencyLead = speed * 0.15;
      final deadReckonLead = speed * min(gpsAgeSeconds, 0.6) * 0.35;
      final rawLead = latencyLead + deadReckonLead;
      final decay = gpsAgeSeconds <= 0.8
          ? 1.0
          : max(0.0, 1.0 - (gpsAgeSeconds - 0.8) / 1.2);
      predictionLead = (rawLead * decay).clamp(0.0, maxPredictionLead);
    }

    _debugPredictionLeadMeters = predictionLead;

    if (gpsAgeSeconds >= 3.0 &&
        _debugTrackingState != 'OFFLINE' &&
        _debugTrackingState != 'REROUTE') {
      _debugTrackingState = 'WAIT ACCURATE GPS';
    }

    final desiredDist =
        (_matchedDistAlongRoute + predictionLead).clamp(0.0, routeEnd);

    final error = desiredDist - _displayDistAlongRoute;
    final previousVisual = _displayDistAlongRoute;

    if (error > 0.0) {
      final baseVelocity = speed > 0.8 ? speed : 1.2;
      // Proportional catch-up velocity smoothly glides towards desiredDist
      final catchUpVelocity = (error / 0.8).clamp(0.0, 6.0);
      final maxVisualVelocity = travelMode == TravelMode.walk ? 4.0 : 35.0;
      final visualVelocity =
          (baseVelocity + catchUpVelocity).clamp(0.5, maxVisualVelocity);

      final advance = (visualVelocity * dt).clamp(0.0, error);
      _displayDistAlongRoute += advance;
    }
    // When error <= 0.0, Visual holds its current progress.
    // Because predictionLead is capped at <= 4.0m (Drive/Motor) and <= 1.5m (Walk),
    // Visual never materially overshoots. When the vehicle stops, Visual settles
    // within 0 to 4.0m of accepted fresh GPS (consistent with stop line) with
    // ZERO backward movement.
    _displayDistAlongRoute =
        max(previousVisual, _displayDistAlongRoute).clamp(0.0, routeEnd);

    displayLatLng = _pointAtRouteDistance(_displayDistAlongRoute);

    // Heading is taken from the exact route segment under the rendered arrow.
    // This avoids diagonal "average" headings after a 90-degree turn.
    final headingTarget = _routeBearingAtDistance(_displayDistAlongRoute);

    final headingAlpha = 1 - exp(-dt / 0.16);
    displayBearing = _lerpBearing(displayBearing, headingTarget, headingAlpha);

    final elapsedMs = elapsed.inMilliseconds;
    if (_lastVisualPublishMs == 0 ||
        elapsedMs - _lastVisualPublishMs >= _visualPublishIntervalMs) {
      _lastVisualPublishMs = elapsedMs;
      positionNotifier.value = displayLatLng;
    }
  }

  // ─────────────────────────────────────────────
  // GPS init
  // ─────────────────────────────────────────────

  Future<void> _initWithRealLocation() async {
    try {
      var perm = await Geolocator.checkPermission();

      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }

      // Start the live stream BEFORE waiting for getCurrentPosition().
      // On real devices the stream can begin producing movement while a
      // one-shot high-accuracy request is still warming up.
      _startTracking();

      Position? seedPosition;

      try {
        seedPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
        ).timeout(const Duration(milliseconds: 1200));
      } catch (_) {
        // The live stream may already have produced a newer fix.
      }

      final bestPosition = lastPos ?? seedPosition;

      if (bestPosition != null) {
        final bestLatLng = LatLng(
          bestPosition.latitude,
          bestPosition.longitude,
        );

        // Do not overwrite a newer stream fix with an older one-shot result.
        if (_lastGpsStreamEventAt == null) {
          userLatLng = bestLatLng;
          targetLatLng = bestLatLng;
          displayLatLng = bestLatLng;
          lastPos = bestPosition;

          _debugSpeedMps =
              bestPosition.speed.isFinite ? bestPosition.speed : 0.0;
          _debugGpsAccuracy = bestPosition.accuracy.isFinite
              ? bestPosition.accuracy.abs()
              : double.infinity;

          positionNotifier.value = displayLatLng;
        }

        final routeSeed = lastPos ?? bestPosition;
        final currentGps = LatLng(routeSeed.latitude, routeSeed.longitude);
        final canReuse = shouldReuseInitialRoute(
          currentGps: currentGps,
          initialRoute: initialRoute,
          mode: travelMode,
        );

        final startGpsSource = _lastGpsStreamEventAt != null
            ? 'live_stream'
            : (seedPosition != null
                ? 'best_for_navigation'
                : 'preview_fallback');

        final previewOrigin = initialRoute?.polylinePoints.isNotEmpty == true
            ? initialRoute!.polylinePoints.first
            : LatLng(startLat, startLng);
        final distFromPreview = _dist(currentGps, previewOrigin);

        print('[NAV_ORIGIN][START]\n'
            'source=$startGpsSource\n'
            'distanceFromPreviewOriginMeters=${distFromPreview.toStringAsFixed(1)}\n'
            'action=${canReuse && initialRoute != null ? "reuse_preview_route" : "request_fresh_route"}');

        if (canReuse && initialRoute != null) {
          _resetRouteState();
          notifyListeners();
          _lastSuccessfulRouteOrRefreshAt = DateTime.now();
          await applyRouteResult(initialRoute!);
        } else {
          if (initialRoute != null) {
            print(
                '[NAV_METRIC][ROUTE] User moved away from preview route origin; requesting fresh route from current GPS.');
          }
          await _loadRoute(
            routeSeed.latitude,
            routeSeed.longitude,
          );
        }

        return;
      }

      // No usable seed yet: keep the live stream running and use the supplied
      // start coordinate only to bootstrap route loading.
      userLatLng = LatLng(startLat, startLng);
      targetLatLng = userLatLng;
      displayLatLng = userLatLng;
      positionNotifier.value = displayLatLng;

      if (initialRoute != null) {
        _resetRouteState();
        notifyListeners();
        _lastSuccessfulRouteOrRefreshAt = DateTime.now();
        await applyRouteResult(initialRoute!);
      } else {
        await _loadRoute(startLat, startLng);
      }
    } catch (_) {
      // Permission/platform fallback. Still start tracking so Android can
      // recover later if location becomes available.
      _startTracking();

      userLatLng = LatLng(startLat, startLng);
      targetLatLng = userLatLng;
      displayLatLng = userLatLng;
      positionNotifier.value = displayLatLng;

      if (initialRoute != null) {
        _resetRouteState();
        notifyListeners();
        _lastSuccessfulRouteOrRefreshAt = DateTime.now();
        await applyRouteResult(initialRoute!);
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
    final c = Canvas(rec);
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
    final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
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

    // TTS initialises in parallel with GPS startup. Wait here only when
    // speech is actually needed instead of blocking navigation startup.
    if (_ttsReady != null) {
      await _ttsReady;
    }

    _lastSpokenInstruction = text;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  void toggleTts() {
    _ttsEnabled = !_ttsEnabled;
    if (!_ttsEnabled) {
      try {
        _tts.stop().catchError((_) => null);
      } catch (_) {}
    }
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
      case TravelMode.walk:
        return 'WALK';
      case TravelMode.drive:
        return 'DRIVE';
      case TravelMode.motor:
        return 'TWO_WHEELER';
    }
  }

  Future<void> _loadRoute(
    double fromLat,
    double fromLng, {
    bool isReroute = false,
  }) async {
    if (!canInitiateRouteRequest(
      isDisposed: _isDisposed,
      hasArrived: hasArrived,
    )) {
      return;
    }

    if (_isRouteRequestInFlight) {
      if (isReroute) {
        _pendingReroutePosition = LatLng(fromLat, fromLng);
        _activeRouteGeneration++;
      }
      return;
    }

    _isRouteRequestInFlight = true;
    final currentSessionId = _navigationSessionId;
    final requestGeneration = ++_activeRouteGeneration;

    // IMPORTANT:
    // Do not clear the active route before a reroute request succeeds.
    // If the phone temporarily loses network, the user must still retain
    // the last known route, GPS marker, step guidance and debug data.
    if (!isReroute) {
      _resetRouteState(isReroute: false);
      notifyListeners();
    }

    try {
      final fetch = routeFetcher ?? RouteService.instance.fetchNavigationRoute;
      final result = await fetch(
        fromLat: fromLat,
        fromLng: fromLng,
        toLat: endLat,
        toLng: endLng,
        mode: travelMode,
      );

      if (_navigationSessionId != currentSessionId ||
          _activeRouteGeneration != requestGeneration ||
          _isDisposed ||
          hasArrived) {
        return;
      }

      isOfflineNavigation = false;
      networkNotice = null;
      _lastSuccessfulRouteOrRefreshAt = DateTime.now();

      await applyRouteResult(result);

      if (isReroute) {
        _setRouteUpdateState(
          NavigationRouteUpdateState.updated,
          message: 'Route updated',
          autoDismissDuration: const Duration(seconds: 3),
        );
        print('[NAV_REROUTE][APPLIED]\n'
            'sessionId=$currentSessionId\n'
            'generation=$requestGeneration\n'
            'newRoadDistanceMeters=${result.distanceMeters.toStringAsFixed(1)}\n'
            'newDurationSeconds=${result.durationSeconds}\n'
            'message="Route updated"');
      }
    } catch (e) {
      if (_isDisposed || hasArrived) return;

      if (isReroute) {
        isRerouting = false;
        isOfflineNavigation = true;
        networkNotice = 'Offline — continuing on current route';
        _debugTrackingState = 'OFFLINE';
        _setRouteUpdateState(
          NavigationRouteUpdateState.failed,
          message:
              'We couldn’t update the route. Continue safely and we’ll try again.',
          autoDismissDuration: const Duration(seconds: 4),
        );
        print('[NAV_REROUTE][FAILED]\n'
            'sessionId=$currentSessionId\n'
            'generation=$requestGeneration\n'
            'action=retain_existing_route\n'
            'message="We couldn’t update the route. Continue safely and we’ll try again."');
        print('[NAV_METRIC][REROUTE]\n'
            'oldRouteMeters=${_totalRouteMeters.toStringAsFixed(1)}\n'
            'newRouteMeters=${_totalRouteMeters.toStringAsFixed(1)}\n'
            'metricsReset=false\n'
            'source=retained_existing_route');
        notifyListeners();
      } else {
        error = e.toString();
        loading = false;
        notifyListeners();
      }
    } finally {
      _isRouteRequestInFlight = false;
      if (shouldLaunchPendingReroute(
        isDisposed: _isDisposed,
        hasArrived: hasArrived,
        hasPendingPosition: _pendingReroutePosition != null,
      )) {
        final pos = _pendingReroutePosition!;
        _pendingReroutePosition = null;
        _loadRoute(pos.latitude, pos.longitude, isReroute: true);
      } else {
        _pendingReroutePosition = null;
      }
    }
  }

  void _resetRouteState({bool isReroute = false}) {
    currentStepIndex = 0;
    steps = [];
    stepEndPolylineIdx = [];
    _stepConfirmCount = 0;
    _stepConfirmForIndex = -1;
    _spokenDistanceReminders.clear();
    _lastSpokenInstruction = null;
    error = null;

    if (!isReroute) {
      _offRouteCount = 0;
      loading = true;
      isRerouting = false;
      walkedPoints = [];
      remainingPoints = [];
      nearestIdx = 0;
      _matchedDistAlongRoute = 0;
      _lastMatchedLatLng = null;
      _lastAcceptedProgressAt = null;
      _stepEndRouteDist = [];
      _offRouteSince = null;
      _lastOffRouteCheckAt = null;
      _lastRawDistanceToRoute = 0;
      _lastDebugLogAt = null;
    }
  }

  Future<void> applyRouteResult(RouteResult result,
      {bool isTrafficRefresh = false}) async {
    final oldTotalMeters = _totalRouteMeters;
    final oldRemainingSeconds = remainingSeconds;
    final oldRemainingMeters = remainingMeters;
    final pts = result.polylinePoints;
    final newSteps = result.steps;

    // Diagnostic only: increments whenever a fresh route is successfully
    // applied (initial route or reroute).
    _debugRouteVersion++;

    isRerouting = false;
    _offRouteCount = 0;
    _offRouteSince = null;

    // A reroute may return fewer steps than the previous route.
    // Reset old step indexes before rebuilding the new route arrays.
    currentStepIndex = 0;
    _stepConfirmCount = 0;
    _stepConfirmForIndex = -1;
    isOfflineNavigation = false;
    networkNotice = null;
    _routeSessionStartedAt = DateTime.now();
    _hasJoinedPlannedRoute = false;

    if (!isTrafficRefresh && pts.length >= 2) {
      bearing = _calcBearing(pts[0], pts[1]);
      displayBearing = bearing;
    }

    polylinePoints = pts;
    remainingPoints = List.from(pts);
    walkedPoints = [];
    steps = newSteps;
    remainingMeters = result.distanceMeters;
    remainingSeconds = result.durationSeconds;
    _routeBaselineSeconds = result.durationSeconds;
    _totalRouteMeters = result.distanceMeters;
    routeBounds = result.bounds;
    loading = false;

    _cumDist = _buildCumDist(pts);

    // Build monotonic step-end indices. Searching from the previous step
    // prevents a loop / nearby parallel segment from mapping a later step
    // back to an earlier point in the route.
    stepEndPolylineIdx = [];
    _stepEndRouteDist = [];
    int searchStart = 0;

    for (final step in newSteps) {
      if (pts.isEmpty) {
        stepEndPolylineIdx.add(0);
        _stepEndRouteDist.add(0);
        continue;
      }

      final idx = _findNearestPolylineIndex(
        step.endLocation,
        pts,
        start: searchStart,
      ).clamp(searchStart, pts.length - 1);

      stepEndPolylineIdx.add(idx);
      _stepEndRouteDist.add(
        _cumDist.isNotEmpty ? _cumDist[idx] : 0,
      );
      searchStart = idx;
    }

    // Initialise the match from the user's current displayed position,
    // rather than blindly assuming route-distance 0. This matters when a
    // preview route was generated slightly before navigation actually starts.
    nearestIdx = 0;
    _matchedDistAlongRoute = 0;
    _lastMatchedLatLng = pts.isNotEmpty ? pts.first : null;
    _lastAcceptedProgressAt = DateTime.now();
    _displayDistAlongRoute = 0.0;
    _displayRouteInitialised = false;

    if (displayLatLng != null && pts.length >= 2) {
      final initial = _bestProjectionInSegmentRange(
        displayLatLng!,
        0,
        min(_segmentIdxAtDistance(300.0) + 1, pts.length - 2),
        useHeading: false,
        gpsHeading: 0,
      );

      if (initial != null && initial.perpDist <= 80.0) {
        nearestIdx = initial.idx;
        _matchedDistAlongRoute = initial.distAlongRoute;
        _lastMatchedLatLng = initial.snapped;
        _displayDistAlongRoute = initial.distAlongRoute;
        _displayRouteInitialised = true;

        final initialJoinThreshold =
            travelMode == TravelMode.walk ? 20.0 : 30.0;
        _hasJoinedPlannedRoute = initial.perpDist <= initialJoinThreshold;
      }
    }

    _syncStepIndexToMatchedProgress();
    _updateRouteProgress(_lastMatchedLatLng ??
        (pts.isNotEmpty ? pts.first : LatLng(startLat, startLng)));
    _updateNavigationMetrics();

    if (isTrafficRefresh) {
      print('[NAV_TRAFFIC][APPLIED]\n'
          'sessionId=$_navigationSessionId\n'
          'requestId=$_trafficRequestId\n'
          'oldRemainingSeconds=$oldRemainingSeconds\n'
          'newRemainingSeconds=$remainingSeconds\n'
          'oldRemainingMeters=${oldRemainingMeters.toStringAsFixed(1)}\n'
          'newRemainingMeters=${remainingMeters.toStringAsFixed(1)}\n'
          'source=${result.isFallback ? 'google_drive_fallback' : 'google_routes_api'}');
    } else if (_debugRouteVersion > 1) {
      print('[NAV_METRIC][REROUTE]\n'
          'oldRouteMeters=${oldTotalMeters.toStringAsFixed(1)}\n'
          'newRouteMeters=${result.distanceMeters.toStringAsFixed(1)}\n'
          'metricsReset=true\n'
          'source=${result.isFallback ? 'google_drive_fallback' : 'google_routes_api'}');
    }

    // Route is ready. Preserve any GPS data already received while the
    // route was loading instead of resetting speed/accuracy back to zero.
    final hasRecentStreamFix = _lastGpsStreamEventAt != null &&
        DateTime.now().difference(_lastGpsStreamEventAt!).inSeconds < 3;

    _debugTrackingState = hasRecentStreamFix ? 'MATCH INIT' : 'WAIT GPS';
    _debugRecoverySeconds = 0;
    _debugMatchPerpDistance = double.infinity;

    notifyListeners();

    if (!isTrafficRefresh && newSteps.isNotEmpty) {
      // First step normally contains the initial "Head/Continue" instruction.
      _speak(newSteps.first.instruction);
    }

    if (!isTrafficRefresh) {
      _startTracking();
    }
  }

  // ─────────────────────────────────────────────
  // GPS tracking
  // ─────────────────────────────────────────────

  void _startTracking() {
    // Route loads/reroutes must not restart a healthy stream.
    if (_positionSub != null) {
      _ensureGpsHealthWatchdog();
      _scheduleStartupGpsWatchdog();
      return;
    }

    _subscribePositionStream();
    _ensureGpsHealthWatchdog();
    _scheduleStartupGpsWatchdog();
  }

  void _subscribePositionStream() {
    _positionSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,

        // Default fused provider. Do not force LocationManager on this device:
        // the latest road test showed that path stopping for 30+ seconds.
        intervalDuration: const Duration(milliseconds: 500),

        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: 'Navigation is active',
          notificationTitle: 'Turn-by-turn Navigation',
          enableWakeLock: true,
        ),
      ),
    ).listen(
      (raw) {
        final now = _currentTime;
        _lastGpsStreamEventAt = now;
        _lastNavigationFixAt = now;

        // First genuine stream event means startup recovery is no longer
        // necessary. The CONTINUOUS health watchdog remains active.
        _startupGpsWatchdog?.cancel();
        _startupGpsWatchdog = null;

        _handlePosition(raw, customNow: now);
      },
      onError: (Object e) {
        debugPrint('NAV GPS STREAM ERROR: $e');
        unawaited(_restartGpsStream());
      },
      onDone: () {
        debugPrint('NAV GPS STREAM CLOSED');
        unawaited(_restartGpsStream());
      },
      cancelOnError: false,
    );
  }

  void _ensureGpsHealthWatchdog() {
    if (_gpsHealthWatchdog != null) return;

    _gpsHealthWatchdog = Timer.periodic(
      const Duration(seconds: 1),
      (_) async {
        if (hasArrived) return;

        final lastStream = _lastGpsStreamEventAt;

        if (lastStream == null) {
          // Startup watchdog handles the first-fix case.
          return;
        }

        final streamAgeMs =
            DateTime.now().difference(lastStream).inMilliseconds;

        // At >2.2s without a stream event, actively request a fresh position.
        // This keeps route progress alive while Android's continuous stream
        // is unhealthy.
        if (streamAgeMs >= 2200 &&
            !_gpsHealthFallbackBusy &&
            (_lastHealthFallbackAt == null ||
                DateTime.now()
                        .difference(_lastHealthFallbackAt!)
                        .inMilliseconds >=
                    1400)) {
          _lastHealthFallbackAt = DateTime.now();
          _gpsHealthFallbackBusy = true;

          try {
            final fresh = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.bestForNavigation,
            ).timeout(const Duration(milliseconds: 1600));

            _lastNavigationFixAt = _currentTime;

            // Do not pretend this came from the stream: GPS age continues to
            // expose the stream problem, while Fix age confirms recovery data
            // is still reaching navigation.
            _debugTrackingState = 'GPS RECOVER';
            await _handlePosition(fresh, customNow: _lastNavigationFixAt);
          } catch (_) {
            // Stream restart below is the next recovery layer.
          } finally {
            _gpsHealthFallbackBusy = false;
          }
        }

        // If the stream itself is silent for 5s, recreate the subscription.
        // This does NOT reset route/matcher/ETA/heading state.
        if (streamAgeMs >= 5000) {
          unawaited(_restartGpsStream());
        }
      },
    );
  }

  Future<void> _restartGpsStream() async {
    if (_gpsStreamRestarting || hasArrived) return;
    _gpsStreamRestarting = true;

    try {
      final oldSub = _positionSub;
      _positionSub = null;
      await oldSub?.cancel();

      debugPrint('NAV GPS STREAM RESTART');

      // Small separation helps Android release the previous request before a
      // new one is registered.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      if (!hasArrived) {
        _subscribePositionStream();
      }
    } catch (e) {
      debugPrint('NAV GPS STREAM RESTART ERROR: $e');
    } finally {
      _gpsStreamRestarting = false;
    }
  }

  void _scheduleStartupGpsWatchdog() {
    if (_lastGpsStreamEventAt != null) return;
    if (_startupGpsWatchdog != null) return;

    _startupFallbackAttempts = 0;

    _startupGpsWatchdog = Timer.periodic(
      const Duration(seconds: 1),
      (timer) async {
        if (_lastGpsStreamEventAt != null) {
          timer.cancel();
          _startupGpsWatchdog = null;
          return;
        }

        if (_startupFallbackBusy) return;

        _startupFallbackAttempts++;

        if (_startupFallbackAttempts > 4) {
          timer.cancel();
          _startupGpsWatchdog = null;
          return;
        }

        _startupFallbackBusy = true;

        try {
          final fresh = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.bestForNavigation,
          ).timeout(const Duration(milliseconds: 1500));

          if (_lastGpsStreamEventAt == null) {
            _lastNavigationFixAt = _currentTime;
            _debugTrackingState = 'START FIX';
            await _handlePosition(fresh, customNow: _lastNavigationFixAt);
          }
        } catch (_) {
          // Continuous health recovery takes over after startup.
        } finally {
          _startupFallbackBusy = false;
        }
      },
    );
  }

  Future<void> _handlePosition(Position raw, {DateTime? customNow}) async {
    final handleWatch = Stopwatch()..start();
    final now = customNow ?? _currentTime;
    final rawLatLng = LatLng(raw.latitude, raw.longitude);

    // Conservative derived speed:
    // Some Android devices briefly report speed=0 after moving. Use coordinate
    // displacement only when the time interval is sufficient (>= 0.75s) and
    // displacement clearly exceeds the GPS accuracy ellipse to prevent dividing
    // short-interval jitter by small dt (which previously produced 45 m/s / 162 km/h spikes).
    double derivedSpeed = 0.0;

    if (_lastRawMotionFix != null && _lastRawMotionFixAt != null) {
      final dt = now.difference(_lastRawMotionFixAt!).inMilliseconds / 1000.0;
      final movedMeters = _dist(_lastRawMotionFix!, rawLatLng);

      if (dt >= 0.75 &&
          dt <= 4.0 &&
          movedMeters >= 4.0 &&
          raw.accuracy.isFinite &&
          raw.accuracy <= 35.0 &&
          movedMeters >= (raw.accuracy * 0.35)) {
        derivedSpeed = movedMeters / dt;
      }
    }

    _lastRawMotionFix = rawLatLng;
    _lastRawMotionFixAt = now;

    final rawSpeed = raw.speed.isFinite ? max(raw.speed, 0.0) : 0.0;

    // Physical travel-mode maximum speed ceiling:
    // Walk: 4.0 m/s (~14.4 km/h)
    // Drive/Motor: 35.0 m/s (~126 km/h)
    final maxModeSpeed = travelMode == TravelMode.walk ? 4.0 : 35.0;

    // Prefer device Doppler speed when it reports reliable motion (> 0.5 m/s).
    // Use derivedSpeed only as a fallback when device speed is near-zero or absent.
    double candidateSpeed;
    if (rawSpeed > 0.5) {
      candidateSpeed = rawSpeed;
    } else {
      candidateSpeed = max(rawSpeed, derivedSpeed);
    }
    candidateSpeed = candidateSpeed.clamp(0.0, maxModeSpeed);

    // Rate-limit speed changes based on elapsed time to enforce physically realistic
    // acceleration limits across varying fix cadences:
    // Maximum physical acceleration: Walk 1.5 m/s^2, Drive/Motor 4.5 m/s^2.
    // Maximum physical braking deceleration: Walk 3.0 m/s^2, Drive/Motor 9.0 m/s^2.
    final dtFix = _lastSpeedSampleAt == null
        ? 1.0
        : (now.difference(_lastSpeedSampleAt!).inMilliseconds / 1000.0)
            .clamp(0.2, 3.0);
    _debugLastSpeedDtFix = dtFix;

    final maxAccel = travelMode == TravelMode.walk ? 1.5 : 4.5;
    final maxDecel = travelMode == TravelMode.walk ? 3.0 : 9.0;
    final maxSpeedIncrease = maxAccel * dtFix;
    final maxSpeedDecrease = maxDecel * dtFix;

    // Prevent abnormal first-sample or single-sample spikes from jumping
    // instantly to the mode ceiling from stopped/low speed:
    final effectiveSpeed = (_debugSpeedMps +
            (candidateSpeed - _debugSpeedMps)
                .clamp(-maxSpeedDecrease, maxSpeedIncrease))
        .clamp(0.0, maxModeSpeed);

    _lastSpeedSampleAt = now;
    _lastNavigationFixAt = now;

    final isMoving = effectiveSpeed > 0.8;

    // IMPORTANT: record every GPS fix before any quality decision.
    // The previous version returned immediately for accuracy >30m, so
    // Android could be receiving movement while the UI stayed at
    // INIT / 0 km/h / GPS ±0 for many seconds during GPS warm-up.
    _debugSpeedMps = effectiveSpeed;
    _debugGpsAccuracy =
        raw.accuracy.isFinite ? raw.accuracy.abs() : double.infinity;

    if (polylinePoints.length < 2) {
      _debugTrackingState = 'WAIT ROUTE';

      // Cache the newest live fix even before the route arrives.
      // The map itself is still behind the loading UI, so updating the
      // display here is safe and lets _applyRouteResult() align against
      // the user's latest position rather than an older startup fix.
      lastPos = raw;
      userLatLng = rawLatLng;
      targetLatLng = rawLatLng;
      displayLatLng = rawLatLng;
      positionNotifier.value = rawLatLng;

      _debugHandleMs = handleWatch.elapsedMicroseconds / 1000.0;
      notifyListeners();
      return;
    }

    // GPS quality bands. We intentionally do NOT hard-reject a 31-60m
    // fix: that is common during navigation warm-up and is still useful
    // when constrained by the planned route + heading + recovery window.
    final gpsAccuracy = _debugGpsAccuracy;
    final bool goodGps = gpsAccuracy <= 25.0;
    final bool usableGps = gpsAccuracy <= 60.0;

    final secondsSinceAccepted = _lastAcceptedProgressAt == null
        ? 1.0
        : now.difference(_lastAcceptedProgressAt!).inMilliseconds / 1000.0;

    final recoverySeconds = secondsSinceAccepted.clamp(0.2, 30.0);

    _debugRecoverySeconds = recoverySeconds;

    // Accuracy >60m is too uncertain to advance trusted route progress.
    // Do not pretend the phone is stationary: speed/accuracy still update
    // on the overlay, recovery time keeps growing, and the next usable fix
    // gets a wider search window so the matcher can catch up immediately.
    if (!usableGps) {
      _debugTrackingState = 'LOW GPS';
      _debugMatchPerpDistance = double.infinity;
      lastPos = raw;

      // Keep route progress and the snapped marker stable. Poor GPS must
      // never by itself trigger rerouting.
      _offRouteSince = null;

      // Route gap remains useful diagnostic information even when the fix
      // is poor; it is display-only in this branch.
      if (_lastOffRouteCheckAt == null ||
          now.difference(_lastOffRouteCheckAt!).inMilliseconds >= 500) {
        _lastOffRouteCheckAt = now;
        _lastRawDistanceToRoute = _distanceToRoute(rawLatLng);
      }

      _debugHandleMs = handleWatch.elapsedMicroseconds / 1000.0;
      notifyListeners();
      return;
    }

    // ── 1. Map match ────────────────────────────────────────────────
    final match = _mapMatch(
      rawLatLng,
      speedMps: effectiveSpeed,
      isMoving: isMoving,
      gpsHeading: raw.heading,
      recoverySeconds: recoverySeconds,
    );

    _debugMatchPerpDistance = match?.perpDist ?? double.infinity;

    final previousProgress = _matchedDistAlongRoute;

    LatLng routePoint = _lastMatchedLatLng ?? polylinePoints.first;
    LatLng visualPoint = routePoint;
    bool trustedMatch = false;

    if (match != null && match.perpDist.isFinite) {
      // With a good fix we keep snapping strict. During warm-up (25-60m
      // accuracy) we allow a slightly wider route snap, but only inside
      // the existing distance-along-route search window and heading score.
      final baseSnapThreshold = travelMode == TravelMode.walk ? 18.0 : 35.0;
      final snapThreshold = goodGps
          ? baseSnapThreshold
          : min(60.0, max(baseSnapThreshold, gpsAccuracy * 1.05));

      if (match.perpDist <= snapThreshold) {
        // One inaccurate forward GPS jump does not permanently advance progress.
        final maxAllowableJump = max(
          45.0,
          effectiveSpeed * recoverySeconds * 2.0 + (goodGps ? 40.0 : 20.0),
        );
        final candidateJump = match.distAlongRoute - _matchedDistAlongRoute;
        final isPlausibleJump = candidateJump <= maxAllowableJump;

        if (isPlausibleJump) {
          trustedMatch = true;

          nearestIdx = match.idx;

          // Progress is monotonic. Tiny backward GPS jitter is ignored.
          final newProgress = max(_matchedDistAlongRoute, match.distAlongRoute);

          final progressed = newProgress - _matchedDistAlongRoute;

          _matchedDistAlongRoute = newProgress;
          _lastMatchedLatLng = match.snapped;
          routePoint = match.snapped;
          visualPoint = match.snapped;

          // Only a REAL forward movement resets recovery. A repeated match
          // to the same old point must not keep shrinking the search window.
          if (progressed >= 1.0 || !isMoving) {
            _lastAcceptedProgressAt = now;
          }

          _debugTrackingState = goodGps ? 'MATCH' : 'MATCH~';
        } else {
          trustedMatch = false;
          _debugTrackingState = 'HOLD_JUMP';
        }
      }
    }

    if (!trustedMatch) {
      _debugTrackingState = 'HOLD';
      routePoint = _lastMatchedLatLng ?? routePoint;

      // Briefly hold the snapped icon through ordinary GPS noise.
      // If matching has genuinely been lost for longer, show raw GPS so
      // the car icon never appears frozen while the vehicle keeps moving.
      visualPoint = recoverySeconds <= 1.2 ? routePoint : rawLatLng;
    }

    // Do NOT rebuild walkedPoints / remainingPoints on every GPS fix.
    // GuidePage renders progress directly from polylinePoints +
    // displayNearestIdx, so these two list allocations are unnecessary in
    // the hot tracking path and can create periodic GC pauses.
    //
    // _updateRouteProgress() is still used when a route is first applied,
    // where a one-time allocation is harmless.

    // ── 2. Independent accuracy-aware off-route check ───────────────
    final isReliableFix = raw.latitude.isFinite &&
        raw.longitude.isFinite &&
        (raw.latitude != 0.0 || raw.longitude != 0.0) &&
        gpsAccuracy.isFinite &&
        gpsAccuracy >= 0.0 &&
        gpsAccuracy <= 60.0 &&
        now.difference(raw.timestamp).inSeconds <= 15;

    _lastRawDistanceToRoute = _distanceToRoute(rawLatLng);
    final effectiveThreshold = calculateEffectiveRerouteThreshold(
      mode: travelMode,
      gpsAccuracyMeters: gpsAccuracy,
    );
    final joinThreshold = travelMode == TravelMode.walk ? 18.0 : 30.0;

    if (isReliableFix && isMoving && !_isDisposed && !hasArrived) {
      if (_lastRawDistanceToRoute <= joinThreshold) {
        _hasJoinedPlannedRoute = true;
      }

      if (_lastRawDistanceToRoute > effectiveThreshold) {
        _consecutiveOffRouteFixes++;
        _offRouteSince ??= now;
      } else {
        _consecutiveOffRouteFixes = 0;
        _offRouteSince = null;
      }
    }

    final offRouteDurationMs = _offRouteSince == null
        ? 0
        : now.difference(_offRouteSince!).inMilliseconds;

    // Rate-limited diagnostic check log (once per ~1000ms)
    if (_lastOffRouteCheckLogAt == null ||
        now.difference(_lastOffRouteCheckLogAt!).inMilliseconds >= 1000) {
      _lastOffRouteCheckLogAt = now;
      final isEligible = isReliableFix &&
          !isRerouting &&
          !_isRouteRequestInFlight &&
          !hasArrived &&
          !_isDisposed &&
          evaluateRerouteCondition(
            consecutiveOffRouteFixes: _consecutiveOffRouteFixes,
            offRouteDurationMs: offRouteDurationMs,
          );
      final reason = !isReliableFix
          ? 'unreliable_gps'
          : (_isRouteRequestInFlight || isRerouting
              ? 'request_in_flight'
              : (_lastRawDistanceToRoute <= effectiveThreshold
                  ? 'on_route'
                  : (_consecutiveOffRouteFixes < 3
                      ? 'insufficient_fixes'
                      : (offRouteDurationMs < 3000
                          ? 'insufficient_duration'
                          : 'eligible'))));

      print('[NAV_REROUTE][GPS_CHECK]\n'
          'accuracyMeters=${gpsAccuracy.toStringAsFixed(1)}\n'
          'distanceFromRouteMeters=${_lastRawDistanceToRoute.toStringAsFixed(1)}\n'
          'effectiveThresholdMeters=${effectiveThreshold.toStringAsFixed(1)}\n'
          'consecutiveOffRouteFixes=$_consecutiveOffRouteFixes\n'
          'offRouteDurationMs=$offRouteDurationMs\n'
          'eligible=$isEligible\n'
          'reason=$reason');
    }

    if (isReliableFix &&
        isMoving &&
        !isRerouting &&
        !_isRouteRequestInFlight &&
        !hasArrived &&
        !_isDisposed) {
      if (!_hasJoinedPlannedRoute) {
        final startedAt = _routeSessionStartedAt ?? now;
        final elapsed = now.difference(startedAt).inSeconds;

        if (elapsed >= 4 &&
            _consecutiveOffRouteFixes >= 3 &&
            _lastRawDistanceToRoute > effectiveThreshold) {
          _triggerReroute(raw, reason: 'startup_rebase');
          return;
        }
      } else {
        if (evaluateRerouteCondition(
          consecutiveOffRouteFixes: _consecutiveOffRouteFixes,
          offRouteDurationMs: offRouteDurationMs,
        )) {
          _triggerReroute(raw, reason: 'off_route');
          return;
        }
      }
    }

    // ── 3. Bearing ──────────────────────────────────────────────────
    if (trustedMatch && isMoving && _cumDist.length >= 2) {
      // Logical route heading also uses the exact current matched segment.
      // No long look-ahead across corners.
      final currentRoadBearing =
          _routeBearingAtDistance(_matchedDistAlongRoute);

      final blend = travelMode == TravelMode.walk ? 0.45 : 0.82;
      bearing = _lerpBearing(
        bearing,
        currentRoadBearing,
        blend,
      );
    }

    // ── 4. Step / ETA / route progress from ONE source of truth ─────
    _syncStepIndexToMatchedProgress();
    _updateNavigationMetrics();

    // ── 5. Arrival ──────────────────────────────────────────────────
    final isLastStep = steps.isEmpty || currentStepIndex >= steps.length - 1;

    if (_dist(rawLatLng, LatLng(endLat, endLng)) <= _arrivedThresh &&
        isLastStep &&
        !hasArrived) {
      hasArrived = true;
      _activeRouteGeneration++;
      _pendingReroutePosition = null;
      _positionSub?.cancel();
      stopTrafficRefreshTimer();
      _cancelRouteUpdateFeedback();

      await _speak('You have arrived at your destination');
      onArrived?.call();
      notifyListeners();
      return;
    }

    // ── 6. Feed the visual renderer ─────────────────────────────────
    _lastFixAt = now;

    // Matching stays GPS-driven. The ticker continuously renders from
    // _matchedDistAlongRoute, so irregular GPS gaps cannot directly create
    // a large on-screen teleport.
    lastPos = raw;
    userLatLng = visualPoint;
    targetLatLng = visualPoint;

    final delta = _matchedDistAlongRoute - previousProgress;

    if (_lastDebugLogAt == null ||
        now.difference(_lastDebugLogAt!).inMilliseconds >= 1000) {
      _lastDebugLogAt = now;

      debugPrint(
        trustedMatch
            ? 'NAV MATCH progress=${_matchedDistAlongRoute.toStringAsFixed(1)}m '
                'delta=${delta.toStringAsFixed(1)}m '
                'recovery=${recoverySeconds.toStringAsFixed(1)}s '
                'rawRouteDist=${_lastRawDistanceToRoute.toStringAsFixed(1)}m '
                'gps±=${gpsAccuracy.toStringAsFixed(1)}m'
            : 'NAV HOLD recovery=${recoverySeconds.toStringAsFixed(1)}s '
                'rawRouteDist=${_lastRawDistanceToRoute.toStringAsFixed(1)}m '
                'gps±=${gpsAccuracy.toStringAsFixed(1)}m',
      );
    }

    _debugHandleMs = handleWatch.elapsedMicroseconds / 1000.0;
    notifyListeners();
  }

  Future<void> _triggerReroute(Position raw, {required String reason}) async {
    isRerouting = true;
    _debugTrackingState = 'REROUTE';
    _consecutiveOffRouteFixes = 0;
    _offRouteSince = null;
    _setRouteUpdateState(
      NavigationRouteUpdateState.searching,
      message: 'You’re off the planned route. Finding a new route…',
    );
    notifyListeners();

    print('[NAV_REROUTE][TRIGGERED]\n'
        'sessionId=$_navigationSessionId\n'
        'generation=$_activeRouteGeneration\n'
        'originLat=${raw.latitude}\n'
        'originLng=${raw.longitude}\n'
        'destinationLat=$endLat\n'
        'destinationLng=$endLng\n'
        'mode=${travelMode.name}');

    await _speak('Off route, recalculating');

    _loadRoute(
      raw.latitude,
      raw.longitude,
      isReroute: true,
    );
  }

  // ─────────────────────────────────────────────
  // MAP-MATCH core
  // ─────────────────────────────────────────────

  /// Returns the START index of the segment containing route-distance [d].
  ///
  /// _cumDist[i] belongs to a VERTEX. If d lies between vertex i and i+1,
  /// the segment index is i. The old "first cumDist >= d" implementation
  /// returned i+1 and could skip the segment the vehicle was actually on.
  LatLng _pointAtRouteDistance(double distance) {
    if (polylinePoints.isEmpty) {
      return targetLatLng ?? LatLng(startLat, startLng);
    }
    if (polylinePoints.length == 1 || _cumDist.length < 2) {
      return polylinePoints.first;
    }

    final d = distance.clamp(0.0, _cumDist.last);
    final segIdx = _segmentIdxAtDistance(d);
    final a = polylinePoints[segIdx];
    final b = polylinePoints[min(segIdx + 1, polylinePoints.length - 1)];

    final segStart = _cumDist[segIdx];
    final segEnd = _cumDist[min(segIdx + 1, _cumDist.length - 1)];
    final segLen = segEnd - segStart;

    if (segLen <= 0.01) return a;

    final t = ((d - segStart) / segLen).clamp(0.0, 1.0);

    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  double _routeBearingAtDistance(double distance) {
    if (polylinePoints.length < 2 || _cumDist.length < 2) {
      return bearing;
    }

    final segIdx = _segmentIdxAtDistance(
      distance.clamp(0.0, _cumDist.last),
    );

    final a = polylinePoints[segIdx];
    final b = polylinePoints[min(segIdx + 1, polylinePoints.length - 1)];

    if (_dist(a, b) < 0.5) return bearing;
    return _calcBearing(a, b);
  }

  int _segmentIdxAtDistance(double d) {
    if (polylinePoints.length < 2 || _cumDist.length < 2) return 0;

    final clamped = d.clamp(0.0, _cumDist.last);

    int lo = 0;
    int hi = _cumDist.length - 1;

    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_cumDist[mid] < clamped) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    return (lo - 1).clamp(0, polylinePoints.length - 2);
  }

  _MatchResult? _mapMatch(
    LatLng raw, {
    required double speedMps,
    required bool isMoving,
    required double gpsHeading,
    required double recoverySeconds,
  }) {
    if (polylinePoints.length < 2 || _cumDist.length < 2) return null;

    final currentDist = _matchedDistAlongRoute;

    // Window grows with time since the last REAL accepted forward match.
    // This is the recovery mechanism that prevents a stale match from
    // permanently locking the navigation position behind the vehicle.
    final double baseForward;
    final double speedFactor;
    final double maxForward;

    switch (travelMode) {
      case TravelMode.walk:
        baseForward = 15.0;
        speedFactor = 1.8;
        maxForward = 70.0;
        break;

      case TravelMode.drive:
      case TravelMode.motor:
        baseForward = 25.0;
        speedFactor = 1.7;
        maxForward = 600.0;
        break;
    }

    final predictedTravel =
        max(speedMps, isMoving ? 1.0 : 0.0) * recoverySeconds * speedFactor;

    // Recovery must not depend only on Position.speed. During GPS warm-up
    // Android can report speed=0 even after the raw location has visibly
    // moved. The straight-line displacement from the last trusted route
    // point provides a second, independent clue for how wide the forward
    // reacquisition window needs to be.
    final rawDisplacementFromTrusted =
        _lastMatchedLatLng == null ? 0.0 : _dist(raw, _lastMatchedLatLng!);

    final displacementWindow = rawDisplacementFromTrusted * 1.6 + baseForward;

    final forwardWindow = max(
      baseForward + predictedTravel,
      displacementWindow,
    ).clamp(baseForward, maxForward);

    final behindSlack = travelMode == TravelMode.walk ? 12.0 : 20.0;

    final startDist = (currentDist - behindSlack).clamp(0.0, _cumDist.last);
    final endDist = (currentDist + forwardWindow).clamp(0.0, _cumDist.last);

    final startIdx = _segmentIdxAtDistance(startDist);
    final endIdx = min(
      _segmentIdxAtDistance(endDist) + 1,
      polylinePoints.length - 2,
    );

    final candidate = _bestProjectionInSegmentRange(
      raw,
      startIdx,
      endIdx,
      useHeading: isMoving && speedMps > 2.0,
      gpsHeading: gpsHeading,
    );

    if (candidate == null) return null;

    // Backward route progress is never accepted. GPS jitter may project
    // a few metres behind the previous point; hold the trusted point instead.
    if (candidate.distAlongRoute < currentDist) {
      return _MatchResult(
        nearestIdx,
        _lastMatchedLatLng ?? candidate.snapped,
        candidate.perpDist,
        currentDist,
      );
    }

    return candidate;
  }

  _MatchResult? _bestProjectionInSegmentRange(
    LatLng raw,
    int startIdx,
    int endIdx, {
    required bool useHeading,
    required double gpsHeading,
  }) {
    if (polylinePoints.length < 2) return null;

    final from = startIdx.clamp(0, polylinePoints.length - 2);
    final to = endIdx.clamp(from, polylinePoints.length - 2);

    _MatchResult? best;
    double bestScore = double.infinity;

    for (int i = from; i <= to; i++) {
      final a = polylinePoints[i];
      final b = polylinePoints[i + 1];

      final projected = _projectOntoSegment(raw, a, b);
      final perp = _dist(raw, projected);

      // Keep moderately distant candidates available for recovery scoring,
      // but never call something >80m away a plausible route match.
      if (perp > 80.0) continue;

      double headingPenalty = 0;

      if (useHeading) {
        final segBearing = _calcBearing(a, b);
        final diff = (((gpsHeading - segBearing + 540) % 360) - 180).abs();

        // Heading is a tie-breaker, not a force strong enough to pull the
        // vehicle onto a distant parallel / post-turn segment.
        headingPenalty = (diff / 180.0) * 22.0;
      }

      // Slightly prefer progress close to the current location when two
      // segments are geometrically almost identical (parallel lanes,
      // roundabouts, stacked geometry).
      final segLen = _dist(a, b);
      final t =
          segLen <= 0 ? 0.0 : (_dist(a, projected) / segLen).clamp(0.0, 1.0);
      final distAlong = _cumDist[i] + segLen * t;

      final forwardBias = max(0.0, distAlong - _matchedDistAlongRoute) * 0.015;

      final score = perp + headingPenalty + forwardBias;

      if (score < bestScore) {
        bestScore = score;
        best = _MatchResult(
          i,
          projected,
          perp,
          distAlong,
        );
      }
    }

    return best;
  }

  /// Raw geometric distance to the planned route. This deliberately has
  /// no heading penalty and no map-match search-window restriction because
  /// its only job is deciding whether the user has actually left the route.
  double _distanceToRoute(LatLng raw) {
    if (polylinePoints.length < 2) return double.infinity;

    final lastSeg = polylinePoints.length - 2;

    // Hot-path search near the current matched segment.
    //
    // The old implementation scanned EVERY segment of the entire route every
    // 500 ms. On a dense Routes API polyline that means hundreds/thousands of
    // projections + distance calculations on Flutter's main isolate, which can
    // periodically stall Ticker, debug overlay, marker and map together.
    //
    // A driving vehicle cannot realistically jump from the current segment to
    // a segment hundreds of points away between two 500 ms checks, so search a
    // generous local window first.
    final localFrom = max(0, nearestIdx - 35);
    final localTo = min(lastSeg, nearestIdx + 90);

    double best = double.infinity;

    for (int i = localFrom; i <= localTo; i++) {
      final projected = _projectOntoSegment(
        raw,
        polylinePoints[i],
        polylinePoints[i + 1],
      );
      final d = _dist(raw, projected);
      if (d < best) best = d;

      // Already clearly on/near the route; no reason to scan more geometry.
      if (best <= 12.0) return best;
    }

    // If the local window says we're plausibly near the route, that's enough
    // for off-route detection.
    if (best <= 80.0) return best;

    // Recovery / unusual geometry fallback:
    // coarse-scan the rest of the route rather than checking every segment.
    // Then refine only around the best coarse candidate.
    const stride = 8;
    int coarseBestIdx = localFrom;
    double coarseBest = best;

    for (int i = 0; i <= lastSeg; i += stride) {
      if (i >= localFrom && i <= localTo) continue;

      final endIdx = min(i + stride, polylinePoints.length - 1);
      final projected = _projectOntoSegment(
        raw,
        polylinePoints[i],
        polylinePoints[endIdx],
      );
      final d = _dist(raw, projected);

      if (d < coarseBest) {
        coarseBest = d;
        coarseBestIdx = i;
      }
    }

    final refineFrom = max(0, coarseBestIdx - stride);
    final refineTo = min(lastSeg, coarseBestIdx + stride * 2);

    for (int i = refineFrom; i <= refineTo; i++) {
      final projected = _projectOntoSegment(
        raw,
        polylinePoints[i],
        polylinePoints[i + 1],
      );
      final d = _dist(raw, projected);
      if (d < best) best = d;
    }

    return best;
  }

  void _syncStepIndexToMatchedProgress() {
    if (steps.isEmpty || _stepEndRouteDist.isEmpty) {
      currentStepIndex = 0;
      return;
    }

    final tolerance = travelMode == TravelMode.walk ? 4.0 : 8.0;

    while (currentStepIndex < steps.length - 1 &&
        currentStepIndex < _stepEndRouteDist.length &&
        _matchedDistAlongRoute >=
            _stepEndRouteDist[currentStepIndex] - tolerance) {
      currentStepIndex++;
      _stepConfirmCount = 0;
      _stepConfirmForIndex = -1;

      // We have just entered this physical step. Speak that step's own
      // instruction; the banner itself still previews the NEXT maneuver.
      _speak(steps[currentStepIndex].instruction);
    }
  }

  DateTime? _lastLiveMetricLogAt;

  void _updateNavigationMetrics() {
    final totalPolyDist = _cumDist.isNotEmpty ? _cumDist.last : 0.0;
    final routeProgress = (totalPolyDist > 0.0 && totalPolyDist.isFinite)
        ? (_matchedDistAlongRoute / totalPolyDist).clamp(0.0, 1.0)
        : 0.0;

    // 1. Authoritative remaining road distance scaled by polyline progress
    remainingMeters = max(0.0, _totalRouteMeters * (1.0 - routeProgress));

    if (steps.isEmpty ||
        _stepEndRouteDist.isEmpty ||
        currentStepIndex >= steps.length ||
        currentStepIndex >= _stepEndRouteDist.length) {
      distToTurnEnd = 0.0;
      remainingSeconds =
          (_routeBaselineSeconds * (1.0 - routeProgress)).round();
      _logLiveMetric(routeProgress);
      return;
    }

    final step = steps[currentStepIndex];

    final stepStartRouteDist =
        currentStepIndex == 0 ? 0.0 : _stepEndRouteDist[currentStepIndex - 1];

    final stepEndRouteDist = _stepEndRouteDist[currentStepIndex];

    final routeLengthForStep =
        max(stepEndRouteDist - stepStartRouteDist, 0.001);

    final routeRemainingForStep = (stepEndRouteDist - _matchedDistAlongRoute)
        .clamp(0.0, routeLengthForStep);

    final stepRemainingRatio =
        (routeRemainingForStep / routeLengthForStep).clamp(0.0, 1.0);

    // Banner distance to the upcoming maneuver along the route
    distToTurnEnd = step.distanceMeters > 0
        ? step.distanceMeters * stepRemainingRatio
        : routeRemainingForStep;

    // 2. Remaining duration: step duration integration preserving authoritative traffic baseline
    remainingSeconds = calculateRemainingDuration(
      routeBaselineSeconds: _routeBaselineSeconds,
      steps: steps,
      currentStepIndex: currentStepIndex,
      currentStepRemainingRatio: stepRemainingRatio,
      routeProgress: routeProgress,
    );

    final upcoming = currentStep;
    if (upcoming != null) {
      _maybeAnnounceDistance(
        currentStepIndex,
        distToTurnEnd,
        upcoming.instruction,
      );
    }

    _logLiveMetric(routeProgress);
  }

  void _logLiveMetric(double routeProgress) {
    final now = DateTime.now();
    if (_lastLiveMetricLogAt != null &&
        now.difference(_lastLiveMetricLogAt!).inMilliseconds < 1000) {
      return;
    }
    _lastLiveMetricLogAt = now;

    final gpsAgeMs = _lastGpsStreamEventAt != null
        ? now.difference(_lastGpsStreamEventAt!).inMilliseconds
        : -1;
    final eta = DateTime.now().add(Duration(seconds: remainingSeconds));
    final h12 = eta.hour % 12 == 0 ? 12 : eta.hour % 12;
    final m = eta.minute.toString().padLeft(2, '0');
    final p = eta.hour >= 12 ? 'PM' : 'AM';

    print('[NAV_METRIC][LIVE]\n'
        'gpsAgeMs=$gpsAgeMs\n'
        'gpsAccuracyM=${_debugGpsAccuracy.isFinite ? _debugGpsAccuracy.toStringAsFixed(1) : 'unknown'}\n'
        'matchedPolylineMeters=${_matchedDistAlongRoute.toStringAsFixed(1)}\n'
        'progress=${(progress * 100).toStringAsFixed(1)}%\n'
        'remainingRoadMeters=${remainingMeters.toStringAsFixed(1)}\n'
        'remainingDurationSec=$remainingSeconds\n'
        'eta=$h12:$m $p\n'
        'currentStepIndex=$currentStepIndex\n'
        'nextTurnMeters=${distToTurnEnd.toStringAsFixed(1)}\n'
        'predictionState=$_debugTrackingState');
  }

  /// Pure production calculation for remaining duration preserving authoritative
  /// traffic-aware routeBaselineSeconds while distributing across steps.
  static int calculateRemainingDuration({
    required int routeBaselineSeconds,
    required List<NavStep> steps,
    required int currentStepIndex,
    required double currentStepRemainingRatio,
    required double routeProgress,
  }) {
    if (steps.isEmpty || currentStepIndex >= steps.length) {
      return max(0, (routeBaselineSeconds * (1.0 - routeProgress)).round());
    }

    int totalStaticStepSeconds = 0;
    for (final s in steps) {
      totalStaticStepSeconds += s.durationSeconds;
    }

    if (totalStaticStepSeconds > 0) {
      final curStep = steps[currentStepIndex];
      final curAdjustedStepSeconds = routeBaselineSeconds *
          (curStep.durationSeconds / totalStaticStepSeconds);
      double remaining =
          curAdjustedStepSeconds * currentStepRemainingRatio.clamp(0.0, 1.0);

      for (int i = currentStepIndex + 1; i < steps.length; i++) {
        final futStep = steps[i];
        final futAdjustedStepSeconds = routeBaselineSeconds *
            (futStep.durationSeconds / totalStaticStepSeconds);
        remaining += futAdjustedStepSeconds;
      }
      return max(0, remaining.round());
    } else {
      // Step-duration data unavailable; use proportional route-level baseline duration
      return max(0, (routeBaselineSeconds * (1.0 - routeProgress)).round());
    }
  }

  /// Pure production validation to determine if a preview route can be reused
  /// based on proximity of navigation-start GPS fix to the preview route origin.
  static bool shouldReuseInitialRoute({
    required LatLng currentGps,
    required RouteResult? initialRoute,
    required TravelMode mode,
    double? customToleranceMeters,
  }) {
    if (initialRoute == null || initialRoute.polylinePoints.isEmpty) {
      return false;
    }
    final startPoint = initialRoute.polylinePoints.first;
    final dist = Geolocator.distanceBetween(
      currentGps.latitude,
      currentGps.longitude,
      startPoint.latitude,
      startPoint.longitude,
    );
    final tolerance =
        customToleranceMeters ?? (mode == TravelMode.walk ? 50.0 : 80.0);
    return dist <= tolerance;
  }

  // ─────────────────────────────────────────────
  // Bounded Live Traffic Refresh
  // ─────────────────────────────────────────────

  void startTrafficRefreshTimer() {
    _trafficRefreshTimer?.cancel();
    _trafficRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkAndRefreshTraffic();
    });
  }

  void stopTrafficRefreshTimer() {
    _trafficRefreshTimer?.cancel();
    _trafficRefreshTimer = null;
  }

  void _checkAndRefreshTraffic({DateTime? nowOverride}) {
    if (_isDisposed || hasArrived || loading) return;

    final now = nowOverride ?? DateTime.now();
    final outReason = StringBuffer();

    final isEligible = checkTrafficRefreshEligibility(
      isNavigationActive: !loading && !hasArrived && !_isDisposed,
      isDisposed: _isDisposed,
      hasArrived: hasArrived,
      mode: travelMode,
      lastGps: lastPos,
      lastGpsTime: _lastGpsStreamEventAt ?? _lastNavigationFixAt,
      isOffline: isOfflineNavigation,
      isRequestInFlight: _isRouteRequestInFlight || isRerouting,
      lastSuccessfulRouteOrRefreshAt: _lastSuccessfulRouteOrRefreshAt,
      lastTrafficAttemptAt: _lastTrafficAttemptAt,
      remainingMeters: remainingMeters,
      now: now,
      outReason: outReason,
    );

    final gpsAgeMs = (_lastGpsStreamEventAt != null)
        ? now.difference(_lastGpsStreamEventAt!).inMilliseconds
        : -1;
    final secondsSinceSuccess = _lastSuccessfulRouteOrRefreshAt != null
        ? now.difference(_lastSuccessfulRouteOrRefreshAt!).inSeconds
        : -1;

    final shouldLogCheck = isEligible ||
        _lastTrafficCheckLogAt == null ||
        now.difference(_lastTrafficCheckLogAt!).inSeconds >= 60;

    if (shouldLogCheck) {
      _lastTrafficCheckLogAt = now;
      print('[NAV_TRAFFIC][CHECK]\n'
          'mode=${travelMode.name}\n'
          'remainingMeters=${remainingMeters.toStringAsFixed(1)}\n'
          'secondsSinceLastSuccess=$secondsSinceSuccess\n'
          'gpsAgeMs=$gpsAgeMs\n'
          'eligible=$isEligible\n'
          'reason=${outReason.toString()}');
    }

    if (!isEligible) {
      return;
    }

    _refreshTraffic();
  }

  Future<void> _refreshTraffic() async {
    if (!canInitiateRouteRequest(
      isDisposed: _isDisposed,
      hasArrived: hasArrived,
    )) {
      return;
    }

    if (_isRouteRequestInFlight) {
      print('[NAV_TRAFFIC][SKIPPED]\nreason=request_in_flight');
      return;
    }

    final raw = lastPos;
    if (raw == null ||
        !raw.latitude.isFinite ||
        !raw.longitude.isFinite ||
        (raw.latitude == 0.0 && raw.longitude == 0.0)) {
      print('[NAV_TRAFFIC][SKIPPED]\nreason=no_fresh_gps');
      return;
    }

    final originLat = raw.latitude;
    final originLng = raw.longitude;
    final currentSessionId = _navigationSessionId;
    final currentRequestId = ++_trafficRequestId;
    final currentGeneration = ++_activeRouteGeneration;

    _isRouteRequestInFlight = true;
    _lastTrafficAttemptAt = DateTime.now();

    print('[NAV_TRAFFIC][REQUEST]\n'
        'sessionId=$currentSessionId\n'
        'requestId=$currentRequestId\n'
        'originLat=$originLat\n'
        'originLng=$originLng\n'
        'destinationLat=$endLat\n'
        'destinationLng=$endLng\n'
        'mode=${travelMode.name}');

    try {
      final fetch = routeFetcher ?? RouteService.instance.fetchNavigationRoute;
      final result = await fetch(
        fromLat: originLat,
        fromLng: originLng,
        toLat: endLat,
        toLng: endLng,
        mode: travelMode,
      );

      if (_isDisposed || hasArrived) return;

      final isValid = isValidTrafficRefreshResult(
        result: result,
        requestSessionId: currentSessionId,
        currentSessionId: _navigationSessionId,
        requestGeneration: currentGeneration,
        currentGeneration: _activeRouteGeneration,
        isNavigationActive: !_isDisposed && !hasArrived && !loading,
      );

      if (!isValid) {
        print('[NAV_TRAFFIC][SKIPPED]\nreason=stale_response');
        return;
      }

      _lastSuccessfulRouteOrRefreshAt = DateTime.now();
      await applyRouteResult(result, isTrafficRefresh: true);
      notifyListeners();
    } catch (e) {
      if (_isDisposed || hasArrived) return;

      print('[NAV_TRAFFIC][FAILED]\n'
          'sessionId=$currentSessionId\n'
          'requestId=$currentRequestId\n'
          'action=retain_existing_route');
    } finally {
      _isRouteRequestInFlight = false;
      if (shouldLaunchPendingReroute(
        isDisposed: _isDisposed,
        hasArrived: hasArrived,
        hasPendingPosition: _pendingReroutePosition != null,
      )) {
        final pos = _pendingReroutePosition!;
        _pendingReroutePosition = null;
        _loadRoute(pos.latitude, pos.longitude, isReroute: true);
      } else {
        _pendingReroutePosition = null;
      }
    }
  }

  /// Pure production helper to determine if a pending reroute should be launched.
  static bool shouldLaunchPendingReroute({
    required bool isDisposed,
    required bool hasArrived,
    required bool hasPendingPosition,
  }) {
    return !isDisposed && !hasArrived && hasPendingPosition;
  }

  /// Pure production helper to determine if a new route or refresh request can begin.
  static bool canInitiateRouteRequest({
    required bool isDisposed,
    required bool hasArrived,
  }) {
    return !isDisposed && !hasArrived;
  }

  /// Pure production helper to calculate accuracy-aware reroute threshold.
  static double calculateEffectiveRerouteThreshold({
    required TravelMode mode,
    required double gpsAccuracyMeters,
  }) {
    final base = mode == TravelMode.walk ? 25.0 : 40.0;
    final safeAccuracy =
        (gpsAccuracyMeters.isFinite && gpsAccuracyMeters >= 0.0)
            ? gpsAccuracyMeters
            : 20.0;
    return max(base, safeAccuracy * 1.5);
  }

  /// Pure production helper to evaluate whether consecutive off-route conditions trigger reroute.
  static bool evaluateRerouteCondition({
    required int consecutiveOffRouteFixes,
    required int offRouteDurationMs,
    int requiredConsecutiveFixes = 3,
    int requiredDurationMs = 3000,
  }) {
    return consecutiveOffRouteFixes >= requiredConsecutiveFixes &&
        offRouteDurationMs >= requiredDurationMs;
  }

  /// Pure production helper to determine if active navigation is eligible for a
  /// bounded background traffic/ETA refresh.
  static bool checkTrafficRefreshEligibility({
    required bool isNavigationActive,
    required bool isDisposed,
    required bool hasArrived,
    required TravelMode mode,
    required Position? lastGps,
    required DateTime? lastGpsTime,
    required bool isOffline,
    required bool isRequestInFlight,
    required DateTime? lastSuccessfulRouteOrRefreshAt,
    required DateTime? lastTrafficAttemptAt,
    required double remainingMeters,
    required DateTime now,
    StringBuffer? outReason,
  }) {
    if (isDisposed) {
      outReason?.write('inactive');
      return false;
    }
    if (!isNavigationActive || hasArrived) {
      outReason?.write('inactive');
      return false;
    }
    if (mode == TravelMode.walk) {
      outReason?.write('walking');
      return false;
    }
    if (isOffline) {
      outReason?.write('offline');
      return false;
    }
    if (isRequestInFlight) {
      outReason?.write('request_in_flight');
      return false;
    }
    if (remainingMeters <= 2000.0) {
      outReason?.write('near_destination');
      return false;
    }
    if (lastGps == null ||
        !lastGps.latitude.isFinite ||
        !lastGps.longitude.isFinite ||
        (lastGps.latitude == 0.0 && lastGps.longitude == 0.0)) {
      outReason?.write('no_fresh_gps');
      return false;
    }
    if (lastGpsTime == null || now.difference(lastGpsTime).inSeconds > 15) {
      outReason?.write('no_fresh_gps');
      return false;
    }
    if (lastSuccessfulRouteOrRefreshAt != null &&
        now.difference(lastSuccessfulRouteOrRefreshAt).inSeconds < 300) {
      outReason?.write('cooldown');
      return false;
    }
    if (lastTrafficAttemptAt != null &&
        now.difference(lastTrafficAttemptAt).inSeconds < 120) {
      outReason?.write('cooldown');
      return false;
    }

    outReason?.write('eligible');
    return true;
  }

  /// Pure production helper to validate that a background traffic refresh result
  /// is structurally valid and corresponds to the active session and request.
  static bool isValidTrafficRefreshResult({
    required RouteResult? result,
    required String requestSessionId,
    required String currentSessionId,
    required int requestGeneration,
    required int currentGeneration,
    required bool isNavigationActive,
  }) {
    if (result == null) {
      return false;
    }
    if (requestSessionId.isEmpty || requestSessionId != currentSessionId) {
      return false;
    }
    if (requestGeneration <= 0 || requestGeneration != currentGeneration) {
      return false;
    }
    if (!isNavigationActive) {
      return false;
    }
    if (result.polylinePoints.length < 2) {
      return false;
    }
    if (!result.distanceMeters.isFinite || result.distanceMeters <= 0) {
      return false;
    }
    if (result.durationSeconds <= 0) {
      return false;
    }
    return true;
  }

  // ─────────────────────────────────────────────
  // Route progress (walked vs remaining polyline)
  // ─────────────────────────────────────────────

  void _updateRouteProgress(LatLng snapped) {
    if (polylinePoints.length < 2) return;

    // nearestIdx represents the START point of the matched segment:
    //
    // polylinePoints[nearestIdx]
    //          ↓
    //          A -------- snapped -------- B
    //                                      ↑
    //                          polylinePoints[nearestIdx + 1]
    //
    // Therefore:
    // walked    = route before A + snapped
    // remaining = snapped + B + everything after B

    final safeIdx = nearestIdx.clamp(0, polylinePoints.length - 2);

    final walked = <LatLng>[];

    if (safeIdx > 0) {
      walked.addAll(
        polylinePoints.take(safeIdx + 1),
      );
    } else {
      walked.add(polylinePoints.first);
    }

    // Avoid adding almost-identical points.
    if (walked.isEmpty || _dist(walked.last, snapped) > 0.5) {
      walked.add(snapped);
    }

    final remaining = <LatLng>[snapped];

    // IMPORTANT:
    // Start from safeIdx + 1, NOT safeIdx.
    //
    // Otherwise the route goes:
    // snapped -> segment start -> segment end
    // which creates the backwards / zig-zag line.
    remaining.addAll(
      polylinePoints.skip(safeIdx + 1),
    );

    walkedPoints = walked;
    remainingPoints = remaining;
  }

  // ─────────────────────────────────────────────
  // Math helpers
  // ─────────────────────────────────────────────

  double _dist(LatLng a, LatLng b) => Geolocator.distanceBetween(
      a.latitude, a.longitude, b.latitude, b.longitude);

  double _calcBearing(LatLng from, LatLng to) {
    final dLng = (to.longitude - from.longitude) * pi / 180;
    final phi1 = from.latitude * pi / 180;
    final phi2 = to.latitude * pi / 180;
    final y = sin(dLng) * cos(phi2);
    final x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  double _lerpBearing(double current, double target, double t) {
    final diff = ((target - current + 540) % 360) - 180;
    return (current + diff * t + 360) % 360;
  }

  LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude, py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    if (lenSq == 0) return a;
    final t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
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
    final from = (start ?? 0).clamp(0, poly.length - 1);
    final to = (end ?? poly.length - 1).clamp(0, poly.length - 1);
    var bestIdx = from;
    var bestDist = double.infinity;
    for (int i = from; i <= to; i++) {
      final d = _dist(point, poly[i]);
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  int _parseSecs(String s) => int.tryParse(s.replaceAll('s', '').trim()) ?? 0;

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
      shift = 0;
      result = 0;
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
    if (_cumDist.isEmpty || _cumDist.last <= 0 || !_cumDist.last.isFinite) {
      return 0.0;
    }
    if (hasArrived) return 1.0;
    final val = _matchedDistAlongRoute / _cumDist.last;
    if (!val.isFinite) return 0.0;
    return val.clamp(0.0, 0.999);
  }

  bool get isWaitingForAccurateLocation {
    if (_lastNavigationFixAt == null) return false;
    return _currentTime.difference(_lastNavigationFixAt!).inSeconds >= 4 &&
        !hasArrived &&
        !loading;
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

    // Camera and arrow use the exact same rendered route heading.
    return displayBearing;
  }

  @visibleForTesting
  Future<void> handlePositionForTesting(Position raw, {DateTime? now}) =>
      _handlePosition(raw, customNow: now);

  @visibleForTesting
  Future<void> simulateProductionGpsStreamEvent(Position raw,
      {DateTime? eventTime}) async {
    final now = eventTime ?? _currentTime;
    _lastGpsStreamEventAt = now;
    _lastNavigationFixAt = now;
    _startupGpsWatchdog?.cancel();
    _startupGpsWatchdog = null;
    await _handlePosition(raw, customNow: now);
  }

  @visibleForTesting
  void onTickForTesting(Duration elapsed) => _onTick(elapsed);

  @visibleForTesting
  void setDisplayDistForTesting(double dist) {
    _displayDistAlongRoute = dist;
    _displayRouteInitialised = true;
  }

  @visibleForTesting
  Future<void> triggerRerouteForTesting(Position raw,
          {required String reason}) =>
      _triggerReroute(raw, reason: reason);
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
