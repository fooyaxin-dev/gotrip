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

  // ── Heading ──
  double bearing = 0;

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
  // Key = stepIndex, Value = set of thresholds already announced (300, 100, 30)
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
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Ticker — smooth display position interpolation
  // ─────────────────────────────────────────────

  void _onTick(Duration _) {
    if (targetLatLng == null) return;
    final current = displayLatLng ?? targetLatLng!;
    const t = 0.28;
    displayLatLng = LatLng(
      current.latitude  + (targetLatLng!.latitude  - current.latitude)  * t,
      current.longitude + (targetLatLng!.longitude - current.longitude) * t,
    );
    notifyListeners();
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
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      userLatLng    = LatLng(pos.latitude, pos.longitude);
      targetLatLng  = userLatLng;
      displayLatLng = userLatLng;
      lastPos       = pos;

      if (initialRoute != null) {
        // 🔗 复用 RoutePreviewPage 已经打过的这次请求结果，
        // 不再对同一趟行程重复打一次 Google Routes API。
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

  // FIX: distance reminder dedup — only speak each threshold once per step
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

  Future<void> _loadRoute(double fromLat, double fromLng) async {
    _resetRouteState();
    notifyListeners();

    try {
      // 🔗 统一走 RouteService，不再自己重复实现一遍 HTTP 请求 + 解析逻辑。
      // 这里用于两种情况：① 完全没有 initialRoute 时的首次加载；
      // ② GPS 检测到偏离路线时的重新规划（reroute），这个必须用当前
      // 实时位置重新请求，没办法预先复用别的数据。
      final result = await RouteService.instance.fetchNavigationRoute(
        fromLat: fromLat,
        fromLng: fromLng,
        toLat:   endLat,
        toLng:   endLng,
        mode:    travelMode,
      );
      await _applyRouteResult(result);
    } catch (e) {
      error   = e.toString();
      loading = false;
      notifyListeners();
    }
  }

  // ── 把"清空状态"和"套用路线结果"拆成两个可复用的小方法 ──
  // _resetRouteState()：无论是首次加载、复用预览页数据、还是 reroute，
  //                      开始前都要把上一段路线的状态清干净。
  // _applyRouteResult()：把一份 RouteResult（不管是新请求来的，还是
  //                      RoutePreviewPage 传进来的）套用到控制器状态里，
  //                      逻辑跟原来 _loadRoute() 成功之后的部分完全一致。

  void _resetRouteState() {
    currentStepIndex       = 0;
    steps                  = [];
    stepEndPolylineIdx     = [];
    _stepConfirmCount      = 0;
    _stepConfirmForIndex   = -1;
    _offRouteCount         = 0;
    _spokenDistanceReminders.clear();
    _lastSpokenInstruction = null;
    loading                = true;
    error                  = null;
    isRerouting            = false;
    walkedPoints           = [];
    remainingPoints        = [];
    nearestIdx             = 0;
  }

  Future<void> _applyRouteResult(RouteResult result) async {
    final pts      = result.polylinePoints;
    final newSteps = result.steps;

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

      // ── 1. Update nearest polyline index (wide search window) ──
      nearestIdx = _findNearestPolylineIndex(
        rawLatLng,
        polylinePoints,
        start: (nearestIdx - 20).clamp(0, max(polylinePoints.length - 1, 0)),
        end:   (nearestIdx + 40).clamp(0, max(polylinePoints.length - 1, 0)),
      );

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
      if (isMoving && !isRerouting && polylinePoints.isNotEmpty) {
        final threshold = travelMode == TravelMode.walk ? 25.0 : _offRouteThresh;
        if (_minDistToRoute(rawLatLng) > threshold) {
          _offRouteCount++;
          if (_offRouteCount >= _offRouteConfirm) {
            isRerouting = true;
            notifyListeners();
            await _speak('Off route, recalculating');
            _loadRoute(raw.latitude, raw.longitude);
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

            // FIX: speak AFTER advancing to the new step
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
        final step = steps[currentStepIndex];
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

        // FIX: distance reminders with dedup per step
        _maybeAnnounceDistance(
            currentStepIndex, distToTurnEnd, step.instruction);
      }

      // ── 7. Snap position to route ──
      final snapped = _snapToRoute(rawLatLng);
      lastPos       = raw;
      userLatLng    = snapped;
      targetLatLng  = snapped;
      displayLatLng ??= snapped;
      _updateRouteProgress(snapped);
      notifyListeners();
    });
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
  // Snap to route — project onto nearest segment
  // ─────────────────────────────────────────────

  LatLng _snapToRoute(LatLng user) {
    if (polylinePoints.isEmpty) return user;

    final start = (nearestIdx - 5).clamp(0, polylinePoints.length - 1);
    final end   = (nearestIdx + 15).clamp(0, polylinePoints.length - 1);

    int    bestIdx       = nearestIdx;
    double bestSegDist   = double.infinity;
    LatLng bestProjected = user;

    for (int i = start; i < end && i < polylinePoints.length - 1; i++) {
      final projected = _projectOntoSegment(
          user, polylinePoints[i], polylinePoints[i + 1]);
      final d = _dist(user, projected);
      if (d < bestSegDist) {
        bestSegDist   = d;
        bestIdx       = i;
        bestProjected = projected;
      }
    }

    // Snap threshold: tighter for walk, wider for drive (GPS jitter)
    final threshold = travelMode == TravelMode.walk ? 15.0 : 30.0;
    if (bestSegDist > threshold) return user; // off-route, return raw GPS

    // Never snap backwards
    if (bestIdx < nearestIdx) bestIdx = nearestIdx;
    nearestIdx = bestIdx;

    return bestProjected;
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

  double _minDistToRoute(LatLng p) {
    if (polylinePoints.isEmpty) return double.infinity;
    final s = (nearestIdx - 10).clamp(0, polylinePoints.length - 1);
    final e = (nearestIdx + 30).clamp(0, polylinePoints.length - 1);
    double min = double.infinity;
    for (int i = s; i < e && i < polylinePoints.length - 1; i++) {
      final d = _distToSeg(p, polylinePoints[i], polylinePoints[i + 1]);
      if (d < min) min = d;
    }
    return min;
  }

  double _distToSeg(LatLng p, LatLng a, LatLng b) =>
      _dist(p, _projectOntoSegment(p, a, b));

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

  NavStep? get currentStep =>
      steps.isNotEmpty ? steps[currentStepIndex] : null;

  NavStep? get nextStep {
    if (currentStep == null) return null;
    // Show next step preview when approaching current turn
    final threshold = travelMode == TravelMode.walk ? 60.0 : 300.0;
    if (currentStepIndex < steps.length - 1 && distToTurnEnd < threshold) {
      return steps[currentStepIndex + 1];
    }
    return null;
  }

  // FIX: cameraBearing
  // - Walking + stationary → face north (bearing = 0) so map stays stable
  // - Walking + moving     → face direction of travel
  // - Driving/motor        → always face direction of travel
  double get cameraBearing {
    if (travelMode == TravelMode.walk) {
      return (lastPos?.speed ?? 0) > 1.1 ? bearing : 0;
    }
    return bearing;
  }
}