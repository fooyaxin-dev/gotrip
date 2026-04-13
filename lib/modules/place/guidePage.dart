import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:compassx/compassx.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
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

class GuidePage extends StatefulWidget {
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName;
  final TravelMode travelMode;

  const GuidePage({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
    this.travelMode = TravelMode.drive,
  });

  @override
  State<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends State<GuidePage> {
  GoogleMapController? _mapController;
  final Set<Marker>   _markers   = {};
  final Set<Polyline> _polylines = {};

  bool    _loading = true;
  String? _error;

  List<LatLng> _polylinePoints  = [];
  List<LatLng> _walkedPoints    = [];
  List<LatLng> _remainingPoints = [];

  int _nearestPolylineIdx = 0;

  // FIX: snapped position on route — icon always placed here
  LatLng? _snappedPosition;

  LatLngBounds? _routeBounds;
  double _remainingMeters  = 0;
  int    _remainingSeconds = 0;

  List<NavStep> _steps            = [];
  int           _currentStepIndex = 0;
  double        _distToCurrentTurnEnd = 0;

  int _stepEndConfirmCount = 0;
  static const int _stepConfirmThreshold = 2;

  StreamSubscription<Position>? _positionStream;
  Position? _currentPosition;

  final List<Position> _positionBuffer = [];
  static const int _bufferSize = 2;

  bool _isFollowing        = true;
  bool _isProgrammaticMove = false;
  bool _isOverview         = false;

  bool   _isRerouting = false;
  static const double _offRouteThreshold = 50.0;
  static const double _arrivedThreshold  = 30.0;
  bool   _hasArrived = false;

  int _offRouteConfirmCount = 0;
  static const int _offRouteConfirmThreshold = 4;

  BitmapDescriptor? _arrowIcon;

  // Compass — only used when stationary
  double _currentHeading      = 0;
  double _lastRenderedHeading = -999;
  static const double _headingThresholdDeg = 2.0;
  StreamSubscription<CompassXEvent>? _compassStream;

  // FIX: GPS-derived bearing with exponential smoothing
  double _gpsHeading         = 0;
  double _smoothedGpsHeading = 0;
  static const double _bearingAlpha = 0.15;

  // Camera throttle — same as Document 2
  DateTime _lastCameraUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _cameraThrottle = Duration(milliseconds: 80);

  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _currentPosition = Position(
      latitude: widget.startLat, longitude: widget.startLng,
      timestamp: DateTime.now(), accuracy: 1, altitude: 0,
      heading: 0, speed: 0, speedAccuracy: 0,
      altitudeAccuracy: 0.0, headingAccuracy: 0.0,
    );
    _snappedPosition = LatLng(widget.startLat, widget.startLng);
    _createArrowIcon().then((_) => _loadRoute(widget.startLat, widget.startLng));
    _startCompass();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _compassStream?.cancel();
    _mapController?.dispose();
    _positionBuffer.clear();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // FIX: Bearing smoothing — exponential moving average
  // Handles 359→1 wraparound correctly
  // ─────────────────────────────────────────────

  double _smoothBearing(double current, double target) {
    double diff = ((target - current + 540) % 360) - 180;
    return (current + diff * _bearingAlpha + 360) % 360;
  }

  // ─────────────────────────────────────────────
  // Arrow icon
  // ─────────────────────────────────────────────

  Future<void> _createArrowIcon() async {
    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder);
    const size     = 64.0;

    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2,
        Paint()..color = Colors.white);
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 4,
        Paint()..color = const Color(0xFF1A73E8));
    final path = Path()
      ..moveTo(size / 2, 10)
      ..lineTo(size / 2 + 14, size - 12)
      ..lineTo(size / 2, size - 20)
      ..lineTo(size / 2 - 14, size - 12)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);

    final img   = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes != null) {
      _arrowIcon = BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
    }
  }

  // ─────────────────────────────────────────────
  // Compass — only when stationary
  // ─────────────────────────────────────────────

  void _startCompass() {
    _compassStream = CompassX.events.listen((CompassXEvent event) {
      if (!mounted) return;
      final heading = event.heading;
      if (heading == null) return;
      _currentHeading = heading;

      final delta = (_currentHeading - _lastRenderedHeading).abs();
      if (delta < _headingThresholdDeg && _lastRenderedHeading != -999) return;
      _lastRenderedHeading = _currentHeading;

      final isMoving = (_currentPosition?.speed ?? 0) > 0.3;
      if (!isMoving && _snappedPosition != null) {
        setState(() => _updateMyMarker(_snappedPosition!, _currentHeading));
      }
    });
  }

  // ─────────────────────────────────────────────
  // Route loading
  // ─────────────────────────────────────────────

  String get _routesApiMode {
    switch (widget.travelMode) {
      case TravelMode.walk:  return 'WALK';
      case TravelMode.drive: return 'DRIVE';
      case TravelMode.motor: return 'TWO_WHEELER';
    }
  }

  int _parseDuration(String duration) {
    final s = duration.replaceAll('s', '').trim();
    return int.tryParse(s) ?? 0;
  }

  Future<void> _loadRoute(double fromLat, double fromLng) async {
    setState(() {
      _loading     = true;
      _error       = null;
      _isRerouting = false;
      _polylines.clear();
      _walkedPoints.clear();
      _remainingPoints.clear();
      _stepEndConfirmCount  = 0;
      _offRouteConfirmCount = 0;
      _nearestPolylineIdx   = 0;
    });

    try {
      final url  = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
      final body = jsonEncode({
        "origin": {
          "location": {"latLng": {"latitude": fromLat, "longitude": fromLng}}
        },
        "destination": {
          "location": {"latLng": {"latitude": widget.endLat, "longitude": widget.endLng}}
        },
        "travelMode": _routesApiMode,
        "routingPreference": widget.travelMode == TravelMode.walk
            ? "ROUTING_PREFERENCE_UNSPECIFIED"
            : "TRAFFIC_AWARE",
        "computeAlternativeRoutes": false,
        if (widget.travelMode != TravelMode.walk)
          "routeModifiers": {"avoidTolls": false, "avoidHighways": false},
        "languageCode": "en-US",
        "units": "METRIC",
      });

      final resp = await http.post(url, headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': _apiKey,
        'X-Goog-FieldMask':
            'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,'
            'routes.legs.steps.navigationInstruction,'
            'routes.legs.steps.distanceMeters,'
            'routes.legs.steps.staticDuration,'
            'routes.legs.steps.startLocation,'
            'routes.legs.steps.endLocation,'
            // FIX: request step-level polylines for denser points
            'routes.legs.steps.polyline,'
            'routes.viewport',
      }, body: body);

      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}: ${resp.body}');

      final data   = json.decode(resp.body);
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) throw Exception('No routes found');

      final route = routes[0];
      final legs  = (route['legs'] as List);

      // FIX: merge step-level polylines for much denser points
      // This fixes the "big chunk grey" problem
      final points = <LatLng>[];
      for (final leg in legs) {
        for (final s in (leg['steps'] as List)) {
          if (s['polyline']?['encodedPolyline'] != null) {
            final sp = _decodePolyline(s['polyline']['encodedPolyline'] as String);
            if (points.isNotEmpty && sp.isNotEmpty) {
              points.addAll(sp.skip(1)); // skip first to avoid duplicate
            } else {
              points.addAll(sp);
            }
          }
        }
      }
      // Fallback to route-level polyline if step polylines unavailable
      final finalPoints = points.isNotEmpty
          ? points
          : _decodePolyline(route['polyline']['encodedPolyline'] as String);

      final vp = route['viewport'];
      final bounds = LatLngBounds(
        southwest: LatLng(vp['low']['latitude'],  vp['low']['longitude']),
        northeast: LatLng(vp['high']['latitude'], vp['high']['longitude']),
      );

      final steps = <NavStep>[];
      for (final leg in legs) {
        for (final s in (leg['steps'] as List)) {
          final nav = s['navigationInstruction'] as Map<String, dynamic>? ?? {};
          steps.add(NavStep(
            instruction:     nav['instructions'] as String? ?? 'Continue',
            maneuver:        (nav['maneuver'] as String? ?? '').toLowerCase(),
            distanceMeters:  (s['distanceMeters'] as num? ?? 0).toDouble(),
            durationSeconds: _parseDuration(s['staticDuration'] as String? ?? '0s'),
            startLocation: LatLng(
              s['startLocation']['latLng']['latitude'],
              s['startLocation']['latLng']['longitude'],
            ),
            endLocation: LatLng(
              s['endLocation']['latLng']['latitude'],
              s['endLocation']['latLng']['longitude'],
            ),
          ));
        }
      }

      // Use API total as ground truth for initial values
      final totalDist = (route['distanceMeters'] as num).toDouble();
      final totalDur  = _parseDuration(route['duration'] as String);

      if (!mounted) return;
      setState(() {
        _polylinePoints       = finalPoints;
        _remainingPoints      = List.from(finalPoints);
        _walkedPoints         = [];
        _routeBounds          = bounds;
        _remainingMeters      = totalDist;
        _remainingSeconds     = totalDur;
        _steps                = steps;
        _currentStepIndex     = 0;
        _distToCurrentTurnEnd = steps.isNotEmpty ? steps[0].distanceMeters : 0;
        _loading              = false;
      });

      _drawRoute(fromLat, fromLng);
      _startTracking();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ─────────────────────────────────────────────
  // Map drawing
  // ─────────────────────────────────────────────

  void _drawRoute(double fromLat, double fromLng) {
    setState(() {
      _rebuildPolylines();
      _updateMyMarker(LatLng(fromLat, fromLng), _smoothedGpsHeading);
      _markers
        ..removeWhere((m) => m.markerId.value == 'destination')
        ..add(Marker(
          markerId:   const MarkerId('destination'),
          position:   LatLng(widget.endLat, widget.endLng),
          icon:       BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
        ));
    });

    Future.delayed(const Duration(milliseconds: 400), () {
      _animateCameraToUser(widget.startLat, widget.startLng);
    });
  }

  void _rebuildPolylines() {
    _polylines.clear();
    if (_walkedPoints.length >= 2) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('walked'),
        points:     _walkedPoints,
        color:      Colors.grey.shade400,
        width:      8,
        startCap:   Cap.roundCap,
        endCap:     Cap.buttCap,
        jointType:  JointType.round,
      ));
    }
    if (_remainingPoints.length >= 2) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('remaining'),
        points:     _remainingPoints,
        color:      const Color(0xFF4A90D9),
        width:      8,
        startCap:   Cap.roundCap,
        endCap:     Cap.roundCap,
        jointType:  JointType.round,
      ));
    }
  }

  // FIX: returns snapped LatLng on the route
  LatLng _updatePolylineSplit(LatLng userPos) {
    if (_polylinePoints.isEmpty) return userPos;

    final searchStart = (_nearestPolylineIdx - 5).clamp(0, _polylinePoints.length - 1);
    int    bestIdx  = _nearestPolylineIdx;
    double bestDist = double.infinity;

    for (int i = searchStart; i < _polylinePoints.length; i++) {
      final d = Geolocator.distanceBetween(
        userPos.latitude, userPos.longitude,
        _polylinePoints[i].latitude, _polylinePoints[i].longitude,
      );
      if (d < bestDist) { bestDist = d; bestIdx = i; }
      if (d > bestDist + 50 && i > bestIdx + 10) break;
    }

    _nearestPolylineIdx = bestIdx;

    // Project user position precisely onto the segment
    LatLng splitPoint = userPos;
    if (bestIdx < _polylinePoints.length - 1) {
      splitPoint = _projectPointOntoSegment(
        userPos,
        _polylinePoints[bestIdx],
        _polylinePoints[bestIdx + 1],
      );
    }

    _walkedPoints    = [..._polylinePoints.sublist(0, bestIdx + 1), splitPoint];
    _remainingPoints = [splitPoint, ..._polylinePoints.sublist(bestIdx + 1)];
    _rebuildPolylines();

    return splitPoint;
  }

  LatLng _projectPointOntoSegment(LatLng p, LatLng a, LatLng b) {
    final double ax = a.longitude, ay = a.latitude;
    final double bx = b.longitude, by = b.latitude;
    final double px = p.longitude,  py = p.latitude;
    final double dx = bx - ax,      dy = by - ay;
    if (dx == 0 && dy == 0) return a;
    final double t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    return LatLng(ay + t.clamp(0.0, 1.0) * dy, ax + t.clamp(0.0, 1.0) * dx);
  }

  // FIX: icon always at snapped position, not raw GPS
  void _updateMyMarker(LatLng pos, double heading) {
    _markers
      ..removeWhere((m) => m.markerId.value == 'me')
      ..add(Marker(
        markerId: const MarkerId('me'),
        position: pos,
        icon:     _arrowIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        rotation: heading,
        anchor:   const Offset(0.5, 0.5),
        flat:     true,
        zIndex:   10,
      ));
  }

  // ─────────────────────────────────────────────
  // Camera — same as Document 2, not changed
  // ─────────────────────────────────────────────

  Future<void> _animateCameraToUser(double lat, double lng) async {
    if (_mapController == null) return;

    final now = DateTime.now();
    if (now.difference(_lastCameraUpdate) < _cameraThrottle) return;
    _lastCameraUpdate = now;

    _isProgrammaticMove = true;
    try {
      await _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(
          target:  LatLng(lat, lng),
          zoom:    20,
          tilt:    0,
          bearing: _smoothedGpsHeading, // FIX: use smoothed GPS bearing
        )),
      );
    } finally {
      _isProgrammaticMove = false;
    }
  }

  void _recenter() {
    if (_snappedPosition == null) return;
    setState(() { _isFollowing = true; _isOverview = false; });
    _animateCameraToUser(_snappedPosition!.latitude, _snappedPosition!.longitude);
  }

  Future<void> _toggleOverview() async {
    if (_routeBounds == null) return;
    setState(() {
      _isOverview  = !_isOverview;
      _isFollowing = !_isOverview;
    });
    if (_isOverview) {
      _isProgrammaticMove = true;
      try {
        await _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(_routeBounds!, 80),
        );
      } finally {
        _isProgrammaticMove = false;
      }
    } else {
      _recenter();
    }
  }

  // ─────────────────────────────────────────────
  // GPS smoothing
  // ─────────────────────────────────────────────

  Position _smoothPosition(Position newPos) {
    _positionBuffer.add(newPos);
    if (_positionBuffer.length > _bufferSize) _positionBuffer.removeAt(0);
    if (_positionBuffer.length < 2) return newPos;

    final avgLat = _positionBuffer.map((p) => p.latitude).reduce((a, b) => a + b)
        / _positionBuffer.length;
    final avgLng = _positionBuffer.map((p) => p.longitude).reduce((a, b) => a + b)
        / _positionBuffer.length;

    return Position(
      latitude: avgLat, longitude: avgLng,
      heading: newPos.heading, speed: newPos.speed,
      accuracy: newPos.accuracy, altitude: newPos.altitude,
      timestamp: newPos.timestamp, speedAccuracy: newPos.speedAccuracy,
      altitudeAccuracy: newPos.altitudeAccuracy, headingAccuracy: newPos.headingAccuracy,
    );
  }

  // ─────────────────────────────────────────────
  // FIX: Remaining time/distance — step-accurate from API data
  // ─────────────────────────────────────────────

  void _updateRemaining(Position pos) {
    if (_steps.isEmpty) return;

    // Sum all future steps after current
    double futureDist = 0;
    int    futureDur  = 0;
    for (int i = _currentStepIndex + 1; i < _steps.length; i++) {
      futureDist += _steps[i].distanceMeters;
      futureDur  += _steps[i].durationSeconds;
    }

    // Current step: distance to step end point
    final step      = _steps[_currentStepIndex];
    final distToEnd = Geolocator.distanceBetween(
      pos.latitude, pos.longitude,
      step.endLocation.latitude, step.endLocation.longitude,
    ).clamp(0.0, step.distanceMeters);

    // Time proportional to distance remaining in current step
    final ratio      = step.distanceMeters > 0 ? distToEnd / step.distanceMeters : 0.0;
    final currentDur = (step.durationSeconds * ratio).toInt();

    _remainingMeters  = distToEnd + futureDist;
    _remainingSeconds = currentDur + futureDur;
  }

  // ─────────────────────────────────────────────
  // GPS tracking — 100ms interval
  // ─────────────────────────────────────────────

  void _startTracking() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy:         LocationAccuracy.bestForNavigation,
        distanceFilter:   0,
        intervalDuration: const Duration(milliseconds: 100),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText:  "Navigation is active",
          notificationTitle: "Turn-by-turn Navigation",
          enableWakeLock:    true,
        ),
      ),
    ).listen((rawPos) {
      if (!mounted) return;
      if (rawPos.accuracy > 25) return;

      final pos        = _smoothPosition(rawPos);
      final isMoving   = rawPos.speed > 0.3;
      final userLatLng = LatLng(pos.latitude, pos.longitude);

      // FIX: update GPS bearing with smoothing
      if (isMoving && _currentPosition != null) {
        final moved = Geolocator.distanceBetween(
          _currentPosition!.latitude, _currentPosition!.longitude,
          pos.latitude, pos.longitude,
        );
        if (moved > 0.5) {
          _gpsHeading = _bearingBetween(
            _currentPosition!.latitude, _currentPosition!.longitude,
            pos.latitude, pos.longitude,
          );
          _smoothedGpsHeading = _smoothBearing(_smoothedGpsHeading, _gpsHeading);
        }
      }

      // 1. Arrived
      final distToDest = Geolocator.distanceBetween(
        pos.latitude, pos.longitude, widget.endLat, widget.endLng,
      );
      if (distToDest <= _arrivedThreshold && !_hasArrived) {
        _hasArrived = true;
        _positionStream?.cancel();
        _showArrivedDialog();
        return;
      }

      // 2. Off-route
      if (isMoving && !_isRerouting && _polylinePoints.isNotEmpty) {
        final minDist = _minDistToPolylineFast(userLatLng);
        if (minDist > _offRouteThreshold) {
          _offRouteConfirmCount++;
          if (_offRouteConfirmCount >= _offRouteConfirmThreshold) {
            _isRerouting = true;
            _loadRoute(pos.latitude, pos.longitude);
            return;
          }
        } else {
          _offRouteConfirmCount = 0;
        }
      }

      // 3. Step switching
      if (_steps.isNotEmpty && _currentStepIndex < _steps.length - 1) {
        final currentStep   = _steps[_currentStepIndex];
        final distToStepEnd = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          currentStep.endLocation.latitude, currentStep.endLocation.longitude,
        );
        if (distToStepEnd < 15 && _isHeadingTowardNextStep(pos)) {
          _stepEndConfirmCount++;
          if (_stepEndConfirmCount >= _stepConfirmThreshold) {
            _stepEndConfirmCount = 0;
            if (mounted) setState(() {
              _currentStepIndex++;
              _distToCurrentTurnEnd = _steps[_currentStepIndex].distanceMeters;
            });
          }
        } else {
          _stepEndConfirmCount = 0;
        }
      }

      // 4. Distance to current turn end
      if (_steps.isNotEmpty) {
        final step = _steps[_currentStepIndex];
        _distToCurrentTurnEnd = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          step.endLocation.latitude, step.endLocation.longitude,
        ).clamp(0.0, step.distanceMeters);
      }

      // 5. Update state
      setState(() {
        _currentPosition = pos;

        // FIX: accurate remaining from step data
        _updateRemaining(pos);

        // FIX: snap icon to route
        final snapped    = _updatePolylineSplit(userLatLng);
        _snappedPosition = snapped;

        // Use smoothed GPS heading when moving, compass when stationary
        final heading = isMoving ? _smoothedGpsHeading : _currentHeading;
        _updateMyMarker(snapped, heading);
      });

      // 6. Camera follow — same as Document 2
      if (_isFollowing && !_isOverview) {
        _animateCameraToUser(
          _snappedPosition!.latitude,
          _snappedPosition!.longitude,
        );
      }
    });
  }

  // ─────────────────────────────────────────────
  // Heading toward next step
  // ─────────────────────────────────────────────

  bool _isHeadingTowardNextStep(Position pos) {
    if (_currentStepIndex + 1 >= _steps.length) return true;
    final next = _steps[_currentStepIndex + 1];
    final targetBearing = _bearingBetween(
      pos.latitude, pos.longitude,
      next.startLocation.latitude, next.startLocation.longitude,
    );
    final diff = (((_smoothedGpsHeading - targetBearing) % 360) + 360) % 360;
    return (diff > 180 ? 360 - diff : diff) < 60;
  }

  double _bearingBetween(double lat1, double lng1, double lat2, double lng2) {
    final dLng = (lng2 - lng1) * pi / 180;
    final phi1 = lat1 * pi / 180;
    final phi2 = lat2 * pi / 180;
    final y    = sin(dLng) * cos(phi2);
    final x    = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  // ─────────────────────────────────────────────
  // Fast min-dist to polyline
  // ─────────────────────────────────────────────

  double _minDistToPolylineFast(LatLng point) {
    if (_polylinePoints.isEmpty) return double.infinity;

    final searchStart = (_nearestPolylineIdx - 20).clamp(0, _polylinePoints.length - 1);
    final searchEnd   = (_nearestPolylineIdx + 40).clamp(0, _polylinePoints.length - 1);

    int    bestIdx  = _nearestPolylineIdx;
    double bestDist = double.infinity;

    for (int i = searchStart; i <= searchEnd; i++) {
      final d = Geolocator.distanceBetween(
        point.latitude, point.longitude,
        _polylinePoints[i].latitude, _polylinePoints[i].longitude,
      );
      if (d < bestDist) { bestDist = d; bestIdx = i; }
    }

    final segStart = (bestIdx - 5).clamp(0, _polylinePoints.length - 1);
    final segEnd   = (bestIdx + 5).clamp(0, _polylinePoints.length - 1);
    double minDist = double.infinity;
    for (int i = segStart; i < segEnd; i++) {
      final d = _distToSegment(
        point,
        _polylinePoints[i],
        _polylinePoints[(i + 1).clamp(0, _polylinePoints.length - 1)],
      );
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  double _distToSegment(LatLng p, LatLng a, LatLng b) {
    final double ax = a.longitude, ay = a.latitude;
    final double bx = b.longitude, by = b.latitude;
    final double px = p.longitude,  py = p.latitude;
    final double dx = bx - ax,      dy = by - ay;
    if (dx == 0 && dy == 0) return Geolocator.distanceBetween(py, px, ay, ax);
    final double t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    final double c = t.clamp(0.0, 1.0);
    return Geolocator.distanceBetween(py, px, ay + c * dy, ax + c * dx);
  }

  // ─────────────────────────────────────────────
  // Arrived dialog
  // ─────────────────────────────────────────────

  void _showArrivedDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Text('🎉', style: TextStyle(fontSize: 28)),
          SizedBox(width: 8),
          Text('You have arrived!', style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        content: Text(widget.destinationName != null
            ? 'You have reached ${widget.destinationName}.'
            : 'You have reached your destination.'),
        actions: [
          ElevatedButton(
            onPressed: () { Navigator.pop(context); Navigator.pop(context); },
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> pts = [];
    int i = 0, len = encoded.length, lat = 0, lng = 0;
    while (i < len) {
      int b, shift = 0, result = 0;
      do { b = encoded.codeUnitAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lat += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      shift = 0; result = 0;
      do { b = encoded.codeUnitAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lng += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      pts.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return pts;
  }

  IconData _maneuverIcon(String maneuver) {
    final m = maneuver.toLowerCase();
    if (m.contains('uturn') || m.contains('u_turn'))     return Icons.u_turn_left_rounded;
    if (m.contains('slight_right'))                       return Icons.turn_slight_right_rounded;
    if (m.contains('slight_left'))                        return Icons.turn_slight_left_rounded;
    if (m.contains('turn_right') || m.contains('right')) return Icons.turn_right_rounded;
    if (m.contains('turn_left')  || m.contains('left'))  return Icons.turn_left_rounded;
    if (m.contains('roundabout'))                         return Icons.roundabout_left_rounded;
    if (m.contains('merge'))                              return Icons.merge_rounded;
    if (m.contains('ramp'))                               return Icons.turn_slight_right_rounded;
    if (m.contains('destination'))                        return Icons.location_on_rounded;
    return Icons.straight_rounded;
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds sec';
    final m = seconds ~/ 60;
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}min';
  }

  String _formatDistance(double m) {
    if (m < 1000) return '${m.round()} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _isRerouting ? 'Recalculating...' : 'Calculating route...',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        )),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 56),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: Colors.black54)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go back'),
            ),
          ],
        )),
      );
    }

    final step = _steps.isNotEmpty ? _steps[_currentStepIndex] : null;
    NavStep? nextStep;
    if (_steps.isNotEmpty &&
        _currentStepIndex < _steps.length - 1 &&
        _distToCurrentTurnEnd < 100) {
      nextStep = _steps[_currentStepIndex + 1];
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(children: [

        // ── Map ──
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target:  LatLng(widget.startLat, widget.startLng),
            zoom:    20,
            tilt:    0,
            bearing: _smoothedGpsHeading,
          ),
          markers:                 _markers,
          polylines:               _polylines,
          myLocationEnabled:       false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled:     false,
          compassEnabled:          false,
          onMapCreated: (c) {
            _mapController = c;
            Future.delayed(const Duration(milliseconds: 200), () {
              _animateCameraToUser(widget.startLat, widget.startLng);
            });
          },
          onCameraMoveStarted: () {
            if (!_isProgrammaticMove && _isFollowing) {
              setState(() => _isFollowing = false);
            }
          },
          padding: EdgeInsets.only(
            top:    MediaQuery.of(context).padding.top + 110,
            bottom: 160,
          ),
        ),

        // ── Turn-by-turn banner ──
        if (step != null)
          Positioned(
            top: 0, left: 0, right: 0,
            child: Column(children: [
              Container(
                color: Colors.black87,
                padding: EdgeInsets.fromLTRB(
                    20, MediaQuery.of(context).padding.top + 12, 20,
                    nextStep != null ? 10 : 16),
                child: Row(children: [
                  Icon(_maneuverIcon(step.maneuver), color: Colors.white, size: 44),
                  const SizedBox(width: 16),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _formatDistance(_distToCurrentTurnEnd),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 28,
                            fontWeight: FontWeight.bold),
                      ),
                      Text(
                        step.instruction,
                        style: TextStyle(color: Colors.grey[300], fontSize: 13),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  )),
                ]),
              ),
              if (nextStep != null)
                Container(
                  color: Colors.black.withOpacity(0.75),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(children: [
                    const Text('Then  ',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    Icon(_maneuverIcon(nextStep.maneuver),
                        color: Colors.grey[400], size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      nextStep.instruction,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    )),
                  ]),
                ),
            ]),
          ),

        // ── Right buttons ──
        Positioned(
          right: 16, bottom: 180,
          child: Column(children: [
            if (!_isFollowing) ...[
              _circleBtn(
                icon:      Icons.my_location_rounded,
                color:     Colors.white,
                iconColor: const Color(0xFF1A73E8),
                onTap:     _recenter,
              ),
              const SizedBox(height: 12),
            ],
            _circleBtn(
              icon:      _isOverview ? Icons.navigation_rounded : Icons.map_rounded,
              color:     _isOverview ? const Color(0xFF1A73E8) : Colors.white,
              iconColor: _isOverview ? Colors.white : Colors.black87,
              onTap:     _toggleOverview,
            ),
          ]),
        ),

        // ── Bottom panel ──
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(
                24, 16, 24, 16 + MediaQuery.of(context).padding.bottom),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20, offset: const Offset(0, -4),
              )],
            ),
            child: Row(children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(_formatDuration(_remainingSeconds),
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                      const SizedBox(width: 8),
                      Text(_formatDistance(_remainingMeters),
                          style: TextStyle(fontSize: 15, color: Colors.grey[600])),
                    ],
                  ),
                  if (widget.destinationName != null)
                    Row(children: [
                      Icon(Icons.location_on_rounded, size: 14, color: Colors.red[400]),
                      const SizedBox(width: 4),
                      Expanded(child: Text(
                        widget.destinationName!,
                        style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                        overflow: TextOverflow.ellipsis,
                      )),
                    ]),
                ],
              )),
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  side: BorderSide(color: Colors.grey[300]!),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Cancel', style: TextStyle(color: Colors.black87)),
              ),
            ]),
          ),
        ),

        // ── Off-route banner ──
        if (_isRerouting)
          Positioned(
            top: 130, left: 20, right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange[700],
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(children: [
                Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Off route, recalculating...',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _circleBtn({
    required IconData icon,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: color, shape: BoxShape.circle,
          boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 8, offset: const Offset(0, 2),
          )],
        ),
        child: Icon(icon, color: iconColor, size: 24),
      ),
    );
  }
}