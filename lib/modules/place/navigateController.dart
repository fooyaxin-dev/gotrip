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
import 'package:intl/intl.dart';
import '../../services/route_service.dart';

class NavStep {
  final String instruction;
  final String maneuver;
  final double distanceMeters;
  final int durationSeconds;
  final LatLng startLocation;
  final LatLng endLocation;

  NavStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.startLocation,
    required this.endLocation,
  });
}

class NavigationController extends ChangeNotifier {
  // ── Config ──
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName;
  final TravelMode travelMode;

  NavigationController({
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
    this.travelMode = TravelMode.drive,
  });

  static const String _apiKey ='AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';// String.fromEnvironment('MAPS_API_KEY');

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
  List<NavStep> steps              = [];
  List<int>     stepEndPolylineIdx = [];
  int           currentStepIndex  = 0;
  double        distToTurnEnd     = 0;
  int           _stepConfirmCount  = 0;
  int           _stepConfirmForIndex = -1;

  // ── ETA ──
  double remainingMeters  = 0;
  int    remainingSeconds = 0;
  double _totalRouteMeters = 0;

  // ── Position ──
  LatLng?   userLatLng;
  LatLng?   targetLatLng;
  LatLng?   displayLatLng;
  Position? lastPos;

  // ── Heading ──
  double bearing = 0;

  // ── State ──
  bool    loading     = true;
  String? error;
  bool    isRerouting = false;
  bool    hasArrived  = false;
  int     _offRouteCount = 0;

  // ── Icon ──
  BitmapDescriptor? arrowIcon;

  // ── Internals ──
  StreamSubscription<Position>?     _positionSub;
  StreamSubscription<CompassXEvent>? _compassSub;
  Ticker?       _ticker;
  VoidCallback? onArrived;

  // ─────────────────────────────────────────────
  // Init & dispose
  // ─────────────────────────────────────────────

  Future<void> init(TickerProvider vsync) async {
    _ticker = vsync.createTicker(_onTick)..start();
    await _createArrowIcon();
    await _initWithRealLocation();
    _startCompass();
  }

  void dispose() {
    _ticker?.dispose();
    _positionSub?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Ticker — smooth display position
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
      lastPos = pos;
      await _loadRoute(pos.latitude, pos.longitude);
    } catch (_) {
      userLatLng    = LatLng(startLat, startLng);
      targetLatLng  = userLatLng;
      displayLatLng = userLatLng;
      await _loadRoute(startLat, startLng);
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
  // Compass
  // ─────────────────────────────────────────────

  void _startCompass() {
    _compassSub = CompassX.events.listen((e) {
      if (e.heading == null) return;
      final isMoving = (lastPos?.speed ?? 0) > 0.5;
      if (!isMoving) {
        const t = 0.18;
        bearing = _lerpBearing(bearing, e.heading!, t);
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
    currentStepIndex     = 0;
    steps                = [];
    stepEndPolylineIdx   = [];
    _stepConfirmCount    = 0;
    _stepConfirmForIndex = -1;
    _offRouteCount       = 0;
    loading              = true;
    error                = null;
    isRerouting          = false;
    walkedPoints         = [];
    remainingPoints      = [];
    nearestIdx           = 0;
    notifyListeners();

    try {
      final url  = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
      final body = jsonEncode({
        "origin":      {"location": {"latLng": {"latitude": fromLat,  "longitude": fromLng}}},
        "destination": {"location": {"latLng": {"latitude": endLat,   "longitude": endLng}}},
        "travelMode":  _travelModeStr,
        "routingPreference": travelMode == TravelMode.walk
            ? "ROUTING_PREFERENCE_UNSPECIFIED" : "TRAFFIC_AWARE",
        "computeAlternativeRoutes": false,
        if (travelMode != TravelMode.walk)
          "routeModifiers": {"avoidTolls": false, "avoidHighways": false},
        "languageCode": "en-US",
        "units": "METRIC",
      });

      final resp = await http.post(url, headers: {
        'Content-Type':     'application/json',
        'X-Goog-Api-Key':   _apiKey,
        'X-Goog-FieldMask':
            'routes.duration,routes.distanceMeters,'
            'routes.legs.steps.navigationInstruction,'
            'routes.legs.steps.distanceMeters,'
            'routes.legs.steps.staticDuration,'
            'routes.legs.steps.startLocation,'
            'routes.legs.steps.endLocation,'
            'routes.legs.steps.polyline,'
            'routes.viewport',
      }, body: body);

      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final data   = json.decode(resp.body);
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) throw Exception('No routes');

      final route    = routes[0];
      final legs     = route['legs'] as List;
      final pts      = <LatLng>[];
      final newSteps = <NavStep>[];

      for (final leg in legs) {
        for (final s in (leg['steps'] as List)) {
          if (s['polyline']?['encodedPolyline'] != null) {
            final sp = _decode(s['polyline']['encodedPolyline'] as String);
            if (pts.isNotEmpty && sp.isNotEmpty) pts.addAll(sp.skip(1));
            else pts.addAll(sp);
          }
          final nav = s['navigationInstruction'] as Map<String, dynamic>? ?? {};
          newSteps.add(NavStep(
            instruction:     _sanitizeInstruction(nav['instructions'] as String? ?? 'Continue'),
            maneuver:        (nav['maneuver'] as String? ?? '').toLowerCase(),
            distanceMeters:  (s['distanceMeters'] as num? ?? 0).toDouble(),
            durationSeconds: _parseSecs(s['staticDuration'] as String? ?? '0s'),
            startLocation: LatLng(
              (s['startLocation']['latLng']['latitude']  as num).toDouble(),
              (s['startLocation']['latLng']['longitude'] as num).toDouble(),
            ),
            endLocation: LatLng(
              (s['endLocation']['latLng']['latitude']  as num).toDouble(),
              (s['endLocation']['latLng']['longitude'] as num).toDouble(),
            ),
          ));
        }
      }

      final vp = route['viewport'];
      routeBounds = LatLngBounds(
        southwest: LatLng(
          (vp['low']['latitude']   as num).toDouble(),
          (vp['low']['longitude']  as num).toDouble(),
        ),
        northeast: LatLng(
          (vp['high']['latitude']  as num).toDouble(),
          (vp['high']['longitude'] as num).toDouble(),
        ),
      );

      if (pts.length >= 2) bearing = _calcBearing(pts[0], pts[1]);

      polylinePoints     = pts;
      remainingPoints    = List.from(pts);
      walkedPoints       = [];
      steps              = newSteps;
      stepEndPolylineIdx = [
        for (final step in newSteps)
          _findNearestPolylineIndex(step.endLocation, pts),
      ];
      distToTurnEnd    = newSteps.isNotEmpty ? newSteps[0].distanceMeters : 0;
      remainingMeters  = (route['distanceMeters'] as num).toDouble();
      remainingSeconds = _parseSecs(route['duration'] as String? ?? '0s');
      _totalRouteMeters = remainingMeters;
      loading           = false;

      if (displayLatLng != null) _updateRouteProgress(displayLatLng!);

      notifyListeners();
      _startTracking();

    } catch (e) {
      error   = e.toString();
      loading = false;
      notifyListeners();
    }
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
    ).listen((raw) {
      if (raw.accuracy > 30) return;

      final rawLatLng = LatLng(raw.latitude, raw.longitude);
      final isMoving  = raw.speed > 0.5;

      // ── FIX: wider search window so we don't lose the nearest index ──
      nearestIdx = _findNearestPolylineIndex(
        rawLatLng,
        polylinePoints,
        start: (nearestIdx - 20).clamp(0, max(polylinePoints.length - 1, 0)),
        end:   (nearestIdx + 40).clamp(0, max(polylinePoints.length - 1, 0)),
      );

      // Bearing from polyline look-ahead (only when moving)
      if (polylinePoints.isNotEmpty && isMoving) {
        final lookAhead = travelMode == TravelMode.walk ? 2 : 5;
        final aheadIdx  = (nearestIdx + lookAhead).clamp(0, polylinePoints.length - 1);
        if (aheadIdx > nearestIdx) {
          final newBearing = _calcBearing(polylinePoints[nearestIdx], polylinePoints[aheadIdx]);
          final t = travelMode == TravelMode.walk ? 0.16 : 0.32;
          bearing = _lerpBearing(bearing, newBearing, t);
        }
      }

      // Arrived check
      final isLastStep = currentStepIndex >= steps.length - 1;
      if (_dist(rawLatLng, LatLng(endLat, endLng)) <= _arrivedThresh &&
          isLastStep && !hasArrived) {
        hasArrived = true;
        _positionSub?.cancel();
        onArrived?.call();
        notifyListeners();
        return;
      }

      // Off-route
      if (isMoving && !isRerouting && polylinePoints.isNotEmpty) {
        final threshold = travelMode == TravelMode.walk ? 25.0 : _offRouteThresh;
        if (_minDistToRoute(rawLatLng) > threshold) {
          _offRouteCount++;
          if (_offRouteCount >= _offRouteConfirm) {
            isRerouting = true;
            notifyListeners();
            _loadRoute(raw.latitude, raw.longitude);
            return;
          }
        } else {
          _offRouteCount = 0;
        }
      }

      // Step advancement
      if (steps.isNotEmpty && currentStepIndex < steps.length - 1) {
        final distToEnd         = _dist(rawLatLng, steps[currentStepIndex].endLocation);
        final currentStepEndIdx = stepEndPolylineIdx.isNotEmpty
            ? stepEndPolylineIdx[currentStepIndex] : -1;
        final reachedByPolyline = currentStepEndIdx >= 0 &&
            nearestIdx >= max(0, currentStepEndIdx - 1);
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
          }
        } else {
          if (_stepConfirmForIndex == currentStepIndex) {
            _stepConfirmCount    = 0;
            _stepConfirmForIndex = -1;
          }
        }
      }

      // ETA
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
        final ratio      = step.distanceMeters > 0 ? distToTurnEnd / step.distanceMeters : 0.0;
        remainingMeters  = distToTurnEnd + futureM;
        remainingSeconds = (step.durationSeconds * ratio).toInt() + futureS;
      }

      // ── FIX: snap works for ALL modes, always project onto segment ──
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
  // Route progress
  // ─────────────────────────────────────────────

  void _updateRouteProgress(LatLng snapped) {
    if (polylinePoints.isEmpty) return;

    final walked = <LatLng>[];
    if (nearestIdx > 0) {
      walked.addAll(polylinePoints.take(nearestIdx));
    }
    walked.add(snapped);

    final remaining = <LatLng>[snapped];
    if (nearestIdx < polylinePoints.length) {
      remaining.addAll(polylinePoints.skip(nearestIdx));
    }

    walkedPoints    = walked;
    remainingPoints = remaining;
  }

  // ─────────────────────────────────────────────
  // FIXED: unified snap — works for walk, drive, any speed
  // ─────────────────────────────────────────────

  LatLng _snapToRoute(LatLng user) {
    if (polylinePoints.isEmpty) return user;

    // Search window around nearest known index
    final start = (nearestIdx - 5).clamp(0, polylinePoints.length - 1);
    final end   = (nearestIdx + 15).clamp(0, polylinePoints.length - 1);

    int    bestIdx      = nearestIdx;
    double bestSegDist  = double.infinity;
    LatLng bestProjected = user;

    // FIX: iterate over SEGMENTS (not points) and project onto each segment
    for (int i = start; i < end && i < polylinePoints.length - 1; i++) {
      final projected = _projectOntoSegment(user, polylinePoints[i], polylinePoints[i + 1]);
      final d         = _dist(user, projected);
      if (d < bestSegDist) {
        bestSegDist  = d;
        bestIdx      = i;
        bestProjected = projected;
      }
    }

    // Snap threshold:
    // - walk: 15m  (tight, pedestrian lanes, indoor paths)
    // - drive/motor: 30m (wider because GPS jitter on roads)
    final threshold = travelMode == TravelMode.walk ? 15.0 : 30.0;

    if (bestSegDist > threshold) {
      // Too far from route — return raw GPS (off-route logic will handle reroute)
      return user;
    }

    // Don't allow snapping backwards along the route
    if (bestIdx < nearestIdx) bestIdx = nearestIdx;
    nearestIdx = bestIdx;

    return bestProjected;
  }

  // ─────────────────────────────────────────────
  // Math helpers
  // ─────────────────────────────────────────────

  double _dist(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  double _calcBearing(LatLng from, LatLng to) {
    final dLng = (to.longitude - from.longitude) * pi / 180;
    final phi1 = from.latitude * pi / 180;
    final phi2 = to.latitude   * pi / 180;
    final y = sin(dLng) * cos(phi2);
    final x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLng);
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

  double _distToSeg(LatLng p, LatLng a, LatLng b) {
    final projected = _projectOntoSegment(p, a, b);
    return _dist(p, projected);
  }

  /// Projects point [p] onto the segment [a]→[b] and returns the clamped projection.
  /// This is the core fix: used by both snapping and distance-to-route calculations.
  LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude,  py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    if (lenSq == 0) return a; // Degenerate segment (same point)
    final t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
    final tc = t.clamp(0.0, 1.0);
    return LatLng(ay + tc * dy, ax + tc * dx);
  }

  int _findNearestPolylineIndex(LatLng point, List<LatLng> poly,
      {int? start, int? end}) {
    if (poly.isEmpty) return 0;
    final from = (start ?? 0).clamp(0, poly.length - 1);
    final to   = (end   ?? poly.length - 1).clamp(0, poly.length - 1);
    var bestIdx  = from;
    var bestDist = double.infinity;
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
    text = text.replaceFirst('Your destination is on the left',  'Destination on the left');
    text = text.replaceFirst('Your destination is on the right', 'Destination on the right');
    return text;
  }

  List<LatLng> _decode(String encoded) {
    final pts = <LatLng>[]; int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int b, shift = 0, result = 0;
      do { b = encoded.codeUnitAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0; result = 0;
      do { b = encoded.codeUnitAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      pts.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return pts;
  }

  // ─────────────────────────────────────────────
  // Public helpers used by UI
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
    final threshold = travelMode == TravelMode.walk ? 60.0 : 300.0;
    if (currentStepIndex < steps.length - 1 && distToTurnEnd < threshold) {
      return steps[currentStepIndex + 1];
    }
    return null;
  }

  double get cameraBearing => travelMode == TravelMode.walk
      ? ((lastPos?.speed ?? 0) > 1.1 ? bearing : 0)
      : bearing;
}