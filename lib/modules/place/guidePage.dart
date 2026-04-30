import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:compassx/compassx.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../services/route_service.dart';

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

  // ── Map ──
  GoogleMapController? _mapController;
  final Set<Marker>   _markers   = {};
  final Set<Polyline> _polylines = {};
  final Set<Circle>   _circles   = {}; 


  // ── Route ──
  List<LatLng> _polylinePoints  = [];
  List<LatLng> _walkedPoints    = [];
  List<LatLng> _remainingPoints = [];
  int          _nearestSegIdx   = 0;  // index of nearest *segment* (not point)
  LatLngBounds? _routeBounds;

  // ── Steps ──
  List<NavStep> _steps            = [];
  int           _currentStepIndex = 0;
  double        _distToTurnEnd    = 0;
  int           _stepConfirmCount = 0;

  // ── ETA ──
  double _remainingMeters  = 0;
  int    _remainingSeconds = 0;

  // ── Position ──
  LatLng?   _userLatLng;
  Position? _lastPos;
  StreamSubscription<Position>? _positionSub;

  // ── Heading ──
  double _bearing = 0;
  StreamSubscription<CompassXEvent>? _compassSub;

  // ── Camera ──
  bool     _isFollowing        = true;
  bool     _isProgrammaticMove = false;
  bool     _isOverview         = false;
  DateTime _lastCameraMove     = DateTime.fromMillisecondsSinceEpoch(0);

  // ── State ──
  bool    _loading     = true;
  String? _error;
  bool    _isRerouting = false;
  bool    _hasArrived  = false;
  int     _offRouteCount = 0;

  // ── Icon ──
  BitmapDescriptor? _arrowIcon;

  static const double _offRouteThresh  = 40.0;  // tighter than before
  static const double _arrivedThresh   = 25.0;
  static const int    _offRouteConfirm = 4;
  static const int    _stepConfirm     = 2;

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _createArrowIcon().then((_) => _initWithRealLocation());
    _startCompass();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _compassSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Init — real GPS then load route
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
      if (!mounted) return;
      setState(() {
        _userLatLng = LatLng(pos.latitude, pos.longitude);
        _lastPos    = pos;
      });
      _loadRoute(pos.latitude, pos.longitude);
    } catch (_) {
      setState(() => _userLatLng = LatLng(widget.startLat, widget.startLng));
      _loadRoute(widget.startLat, widget.startLng);
    }
  }

  // ─────────────────────────────────────────────
  // Arrow icon (always points up; map rotates)
  // ─────────────────────────────────────────────

  Future<void> _createArrowIcon() async {
    const size = 72.0;
    final rec  = ui.PictureRecorder();
    final c    = Canvas(rec);
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
    if (bytes != null && mounted) {
      setState(() =>
          _arrowIcon = BitmapDescriptor.fromBytes(bytes.buffer.asUint8List()));
    }
  }

  // ─────────────────────────────────────────────
  // Compass — stationary only
  // ─────────────────────────────────────────────

  void _startCompass() {
    _compassSub = CompassX.events.listen((e) {
      if (!mounted || e.heading == null) return;
      if ((_lastPos?.speed ?? 0) <= 0.5) {
        setState(() {
          _bearing = e.heading!;
      
        });
        _moveCamera();
      }
    });
  }

  // ─────────────────────────────────────────────
  // Route loading — delegates to RouteService
  // ─────────────────────────────────────────────

  Future<void> _loadRoute(double fromLat, double fromLng) async {
    if (!mounted) return;
    setState(() {
      _loading          = true;
      _error            = null;
      _isRerouting      = false;
      _polylines.clear();
      _walkedPoints.clear();
      _remainingPoints.clear();
      _nearestSegIdx    = 0;
      _stepConfirmCount = 0;
      _offRouteCount    = 0;
    });

    try {
      final result = await RouteService.instance.fetchNavigationRoute(
        fromLat: fromLat, fromLng: fromLng,
        toLat:   widget.endLat, toLng: widget.endLng,
        mode:    widget.travelMode,
      );

      if (!mounted) return;

      if (result.polylinePoints.length >= 2) {
        _bearing = _calcBearing(
            result.polylinePoints[0], result.polylinePoints[1]);
      }

      setState(() {
        _polylinePoints   = result.polylinePoints;
        _remainingPoints  = List.from(result.polylinePoints);
        _walkedPoints     = [];
        _routeBounds      = result.bounds;
        _steps            = result.steps;
        _currentStepIndex = 0;
        _distToTurnEnd    = result.steps.isNotEmpty
            ? result.steps[0].distanceMeters : 0;
        _remainingMeters  = result.distanceMeters;
        _remainingSeconds = result.durationSeconds;
        _loading          = false;

        _markers
          ..removeWhere((m) => m.markerId.value == 'destination')
          ..add(Marker(
            markerId:   const MarkerId('destination'),
            position:   LatLng(widget.endLat, widget.endLng),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
            infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
          ));

        _rebuildPolylines();
        if (_userLatLng != null) _placeArrow(_userLatLng!);
      });

      await Future.delayed(const Duration(milliseconds: 300));
      _moveCamera();
      _startTracking();

    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ─────────────────────────────────────────────
  // Polylines
  // ─────────────────────────────────────────────

  void _rebuildPolylines() {
    _polylines.clear();
    if (_walkedPoints.length >= 2) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('walked'),
        points:    _walkedPoints,
        color:     Colors.grey.shade400,
        width:     7,
        startCap:  Cap.roundCap, endCap: Cap.buttCap,
        jointType: JointType.round,
      ));
    }
    if (_remainingPoints.length >= 2) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('remaining'),
        points:    _remainingPoints,
        color:     const Color(0xFF1A73E8),
        width:     7,
        startCap:  Cap.roundCap, endCap: Cap.roundCap,
        jointType: JointType.round,
      ));
    }
  }

  // ─────────────────────────────────────────────
  // Snap — projects onto nearest SEGMENT (not point)
  // This is the key fix vs the previous nearest-point approach.
  // ─────────────────────────────────────────────

  LatLng _snapAndSplit(LatLng user) {
    if (_polylinePoints.length < 2) return user;

    final searchStart = (_nearestSegIdx - 10).clamp(0, _polylinePoints.length - 2);
    final searchEnd   = (_nearestSegIdx + 40).clamp(0, _polylinePoints.length - 2);

    int    bestSeg  = _nearestSegIdx;
    double bestDist = double.infinity;

    for (int i = searchStart; i <= searchEnd; i++) {
      final d = _distToSeg(user, _polylinePoints[i], _polylinePoints[i + 1]);
      if (d < bestDist) { bestDist = d; bestSeg = i; }
      if (i > bestSeg + 20 && d > bestDist * 2.5) break;
    }

    // ← 只允许前进，不能回退，防止 bearing 反转
    if (bestSeg > _nearestSegIdx) _nearestSegIdx = bestSeg;

    final snapped = _project(user, _polylinePoints[_nearestSegIdx],
        _polylinePoints[_nearestSegIdx + 1]);

    _walkedPoints    = [..._polylinePoints.sublist(0, _nearestSegIdx + 1), snapped];
    _remainingPoints = [snapped, ..._polylinePoints.sublist(_nearestSegIdx + 1)];
    _rebuildPolylines();
    return snapped;
  }

  // ─────────────────────────────────────────────
  // Arrow marker
  // ─────────────────────────────────────────────

  // ── 问题2：地图bearing跟随用户，marker rotation应该为0 ──
// 因为 CameraPosition.bearing = _bearing，地图已经转了
// marker的rotation应该相对于地图，不是绝对north
// 如果地图朝north转了30度，marker不需要额外旋转

// 在_markers里加一个Circle表示精度范围
void _placeArrow(LatLng pos) {
  _markers
    ..removeWhere((m) => m.markerId.value == 'me')
    ..add(Marker(
      markerId: const MarkerId('me'),
      position: pos,
      icon: _arrowIcon ?? BitmapDescriptor.defaultMarkerWithHue(
          BitmapDescriptor.hueAzure),
      rotation: _bearing,
      anchor: const Offset(0.5, 0.5),
      flat: true,
      zIndex: 10,
    ));

  // 精度圈
  _circles  // 你需要加一个 final Set<Circle> _circles = {};
    ..removeWhere((c) => c.circleId.value == 'accuracy')
    ..add(Circle(
      circleId: const CircleId('accuracy'),
      center: pos,
      radius: 8.0,
      fillColor: const Color(0x221A73E8),
      strokeColor: const Color(0x441A73E8),
      strokeWidth: 1,
    ));
}

  // ─────────────────────────────────────────────
  // Camera
  // ─────────────────────────────────────────────

  double _zoomForSpeed(double mps) {
    if (mps >= 25) return 16.0;
    if (mps >= 14) return 17.0;
    if (mps >= 8)  return 18.0;
    if (mps >= 1)  return 19.0;
    return 19.5;
  }

  void _moveCamera() {
    if (_mapController == null || _userLatLng == null) return;
    final now = DateTime.now();
    if (now.difference(_lastCameraMove).inMilliseconds < 80) return;
    _lastCameraMove = now;

    _isProgrammaticMove = true;
    _mapController!.animateCamera(    // ← 改成 animateCamera（平滑移动）
      CameraUpdate.newCameraPosition(CameraPosition(
        target:  _userLatLng!,
        zoom:    _zoomForSpeed(_lastPos?.speed ?? 0),
        tilt:    0,
        bearing: _bearing,
      )),
    ).then((_) {
      _isProgrammaticMove = false;  
    });
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
      if (!mounted) return;
      if (raw.accuracy > 30) return;

      final isMoving  = raw.speed > 0.5;
      final rawLatLng = LatLng(raw.latitude, raw.longitude);
      final snapped = _snapAndSplit(rawLatLng);

      if (isMoving && _remainingPoints.length >= 4) {
        final newBearing = _calcBearing(
          _remainingPoints[0], 
          _remainingPoints[3], 
        );
        _bearing = _lerpBearing(_bearing, newBearing, 0.12);
      }

      // ── Arrived ──
      if (_dist(rawLatLng, LatLng(widget.endLat, widget.endLng)) <= _arrivedThresh
          && !_hasArrived) {
        _hasArrived = true;
        _positionSub?.cancel();
        _showArrivedDialog();
        return;
      }

      // ── Off-route ──
      if (isMoving && !_isRerouting && _polylinePoints.isNotEmpty) {
        if (_minDistToRoute(rawLatLng) > _offRouteThresh) {
          _offRouteCount++;
          if (_offRouteCount >= _offRouteConfirm) {
            _isRerouting = true;
            _loadRoute(raw.latitude, raw.longitude);
            return;
          }
        } else {
          _offRouteCount = 0;
        }
      }

      if (_steps.isNotEmpty && _currentStepIndex < _steps.length - 1) {
        final step    = _steps[_currentStepIndex];
        final distEnd = _dist(snapped, step.endLocation);

        if (distEnd < 15) {
          _stepConfirmCount++;
          if (_stepConfirmCount >= _stepConfirm) {
            _stepConfirmCount = 0;
            setState(() {
              _currentStepIndex++;
              _distToTurnEnd = _steps[_currentStepIndex].distanceMeters;
            });
          }
        } else {
          _stepConfirmCount = 0;
        }
      }

      // ── Remaining ETA ──
      if (_steps.isNotEmpty) {
        final step = _steps[_currentStepIndex];
        _distToTurnEnd = _dist(rawLatLng, step.endLocation)
            .clamp(0.0, step.distanceMeters);
        double futureM = 0; int futureS = 0;
        for (int i = _currentStepIndex + 1; i < _steps.length; i++) {
          futureM += _steps[i].distanceMeters;
          futureS += _steps[i].durationSeconds;
        }
        final ratio = step.distanceMeters > 0
            ? _distToTurnEnd / step.distanceMeters : 0.0;
        _remainingMeters  = _distToTurnEnd + futureM;
        _remainingSeconds = (step.durationSeconds * ratio).toInt() + futureS;
      }

      // ── Update state ──
      setState(() {
        _lastPos    = raw;
        _userLatLng = snapped;
        
        _markers
          ..removeWhere((m) => m.markerId.value == 'me')
          ..add(Marker(
            markerId: const MarkerId('me'),
            position: snapped,
            icon: _arrowIcon ?? BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure),
            rotation: _bearing,
            anchor: const Offset(0.5, 0.5),
            flat: true,
            zIndex: 10,
          ));

        _circles
          ..removeWhere((c) => c.circleId.value == 'accuracy')
          ..add(Circle(
            circleId: const CircleId('accuracy'),
            center: snapped,
            radius: 8.0,
            fillColor: const Color(0x221A73E8),
            strokeColor: const Color(0x441A73E8),
            strokeWidth: 1,
          ));
      });

      if (_isFollowing && !_isOverview) _moveCamera();
    });
  }
  
  
  // ─────────────────────────────────────────────
  // Step distance — uses per-step polyline for accuracy
  // ─────────────────────────────────────────────

  /// Minimum distance from [user] to any segment of [step]'s polyline.
  /// Falls back to straight-line distance to endLocation if no polyline.
  double _distToStepEnd(LatLng user, NavStep step) {
    final pts = step.polylinePoints;
    if (pts.length < 2) return _dist(user, step.endLocation);

    double minDist = double.infinity;
    // Only check last quarter of step — the user is approaching the turn
    final searchStart = (pts.length * 3 ~/ 4).clamp(0, pts.length - 2);
    for (int i = searchStart; i < pts.length - 1; i++) {
      final d = _distToSeg(user, pts[i], pts[i + 1]);
      if (d < minDist) minDist = d;
    }
    // Also check straight-line to end marker
    final dEnd = _dist(user, step.endLocation);
    return minDist < dEnd ? minDist : dEnd;
  }

  // ─────────────────────────────────────────────
  // Overview / recenter
  // ─────────────────────────────────────────────

  void _recenter() {
    setState(() { _isFollowing = true; _isOverview = false; });
    _moveCamera();
  }

  Future<void> _toggleOverview() async {
    if (_routeBounds == null) return;
    setState(() { _isOverview = !_isOverview; _isFollowing = !_isOverview; });
    if (_isOverview) {
      _isProgrammaticMove = true;
      await _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(_routeBounds!, 80));
      _isProgrammaticMove = false;
    } else {
      _recenter();
    }
  }

  // ─────────────────────────────────────────────
  // Arrived dialog
  // ─────────────────────────────────────────────

  void _showArrivedDialog() {
    showDialog(
      context: context, barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Text('🎉', style: TextStyle(fontSize: 28)),
          SizedBox(width: 8),
          Text('You have arrived!',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        content: Text(widget.destinationName != null
            ? 'You have reached ${widget.destinationName}.'
            : 'You have reached your destination.'),
        actions: [ElevatedButton(
          onPressed: () { Navigator.pop(context); Navigator.pop(context, true);  },
          style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12))),
          child: const Text('Done'),
        )],
      ),
    );
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
    if (_polylinePoints.length < 2) return double.infinity;
    final s = (_nearestSegIdx - 10).clamp(0, _polylinePoints.length - 2);
    final e = (_nearestSegIdx + 30).clamp(0, _polylinePoints.length - 2);
    double min = double.infinity;
    for (int i = s; i <= e; i++) {
      final d = _distToSeg(p, _polylinePoints[i], _polylinePoints[i + 1]);
      if (d < min) min = d;
    }
    return min;
  }

  /// Perpendicular distance from p to the segment a→b.
  double _distToSeg(LatLng p, LatLng a, LatLng b) {
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude,  py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    if (dx == 0 && dy == 0) return _dist(p, a);
    final t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    final tc = t.clamp(0.0, 1.0);
    return Geolocator.distanceBetween(py, px, ay + tc * dy, ax + tc * dx);
  }

  /// Project p onto segment a→b, returning the closest point on the segment.
  LatLng _project(LatLng p, LatLng a, LatLng b) {
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude,  py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    if (dx == 0 && dy == 0) return a;
    final t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    final c = t.clamp(0.0, 1.0);
    return LatLng(ay + c * dy, ax + c * dx);
  }

  IconData _maneuverIcon(String m) {
    if (m.contains('uturn'))                              return Icons.u_turn_left_rounded;
    if (m.contains('slight_right'))                       return Icons.turn_slight_right_rounded;
    if (m.contains('slight_left'))                        return Icons.turn_slight_left_rounded;
    if (m.contains('turn_right') || m.contains('right')) return Icons.turn_right_rounded;
    if (m.contains('turn_left')  || m.contains('left'))  return Icons.turn_left_rounded;
    if (m.contains('roundabout'))                         return Icons.roundabout_left_rounded;
    if (m.contains('merge'))                              return Icons.merge_rounded;
    if (m.contains('destination'))                        return Icons.location_on_rounded;
    return Icons.straight_rounded;
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
            Text(_isRerouting ? 'Recalculating...' : 'Calculating route...',
                style: const TextStyle(fontSize: 16, color: Colors.grey)),
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
                child: const Text('Go back')),
          ],
        )),
      );
    }

    final mq      = MediaQuery.of(context);
    final step    = _steps.isNotEmpty ? _steps[_currentStepIndex] : null;
    NavStep? nextStep;
    if (step != null && _currentStepIndex < _steps.length - 1 &&
        _distToTurnEnd < 100) {
      nextStep = _steps[_currentStepIndex + 1];
    }

    final bannerH = mq.padding.top + (nextStep != null ? 130.0 : 98.0);
    const panelH  = 90.0;
    final svc     = RouteService.instance;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(children: [

        // ── Map ──
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target:  _userLatLng ?? LatLng(widget.startLat, widget.startLng),
            zoom:    19,
            tilt:    0,
            bearing: _bearing,
          ),
          markers:                 _markers,
          polylines:               _polylines,
          circles:   _circles,
          myLocationEnabled:       false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled:     false,
          compassEnabled:          false,
          buildingsEnabled:        false,
          onMapCreated: (c) {
            _mapController = c;
            Future.delayed(const Duration(milliseconds: 300), _moveCamera);
          },
          onCameraMoveStarted: () {
            if (!_isProgrammaticMove) {
              final now = DateTime.now();
              // 启动后 1 秒内的镜头移动不算用户手动滑动
              if (now.difference(_lastCameraMove).inMilliseconds > 1000) {
                setState(() => _isFollowing = false);
              }
            }
          },
          padding: EdgeInsets.only(
            top:    bannerH,
            bottom: panelH + mq.padding.bottom,
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
                    20, mq.padding.top + 12, 20, nextStep != null ? 10 : 16),
                child: Row(children: [
                  Icon(_maneuverIcon(step.maneuver),
                      color: Colors.white, size: 44),
                  const SizedBox(width: 16),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(svc.formatDistance(_distToTurnEnd),
                          style: const TextStyle(color: Colors.white,
                              fontSize: 28, fontWeight: FontWeight.bold)),
                      Text(step.instruction,
                          style: TextStyle(
                              color: Colors.grey[300], fontSize: 13),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  )),
                ]),
              ),
              if (nextStep != null)
                Container(
                  color: Colors.black.withOpacity(0.75),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 8),
                  child: Row(children: [
                    const Text('Then  ',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    Icon(_maneuverIcon(nextStep.maneuver),
                        color: Colors.grey[400], size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(nextStep.instruction,
                        style: TextStyle(
                            color: Colors.grey[400], fontSize: 12),
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ]),
          ),

        // ── Right buttons ──
        Positioned(
          right: 16,
          bottom: panelH + mq.padding.bottom + 16,
          child: Column(children: [
            if (!_isFollowing) ...[
              _circleBtn(Icons.my_location_rounded, Colors.white,
                  const Color(0xFF1A73E8), _recenter),
              const SizedBox(height: 12),
            ],
            _circleBtn(
              _isOverview ? Icons.navigation_rounded : Icons.map_rounded,
              _isOverview ? const Color(0xFF1A73E8) : Colors.white,
              _isOverview ? Colors.white : Colors.black87,
              _toggleOverview,
            ),
          ]),
        ),

        // ── Bottom panel ──
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(
                24, 14, 24, 14 + mq.padding.bottom),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.10),
                blurRadius: 16, offset: const Offset(0, -3),
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
                      Text(svc.formatDuration(_remainingSeconds),
                          style: const TextStyle(fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                      const SizedBox(width: 8),
                      Text(svc.formatDistance(_remainingMeters),
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey[600])),
                      const SizedBox(width: 8),
                      Text('· ${svc.formatArrivalTime(_remainingSeconds)}',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey[500])),
                    ],
                  ),
                  if (widget.destinationName != null)
                    Row(children: [
                      Icon(Icons.location_on_rounded,
                          size: 13, color: Colors.red[400]),
                      const SizedBox(width: 4),
                      Expanded(child: Text(widget.destinationName!,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[500]),
                          overflow: TextOverflow.ellipsis)),
                    ]),
                ],
              )),
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  side: BorderSide(color: Colors.grey[300]!),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.black87)),
              ),
            ]),
          ),
        ),

        // ── Off-route banner ──
        if (_isRerouting)
          Positioned(
            top: bannerH + 8, left: 20, right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange[700],
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(children: [
                Icon(Icons.refresh_rounded,
                    color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Off route, recalculating...',
                    style: TextStyle(color: Colors.white,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _circleBtn(
      IconData icon, Color bg, Color fg, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: bg, shape: BoxShape.circle,
          boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 8, offset: const Offset(0, 2),
          )],
        ),
        child: Icon(icon, color: fg, size: 24),
      ),
    );
  }
}