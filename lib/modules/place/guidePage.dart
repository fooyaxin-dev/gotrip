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

// ── 修改 1：NavStep 加上 durationSeconds ──
class NavStep {
  final String instruction;
  final String maneuver;
  final double distanceMeters;
  final int    durationSeconds; // ← 新增
  final LatLng startLocation;
  final LatLng endLocation;

  NavStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
    required this.durationSeconds, // ← 新增
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

  List<LatLng>  _polylinePoints       = [];
  LatLngBounds? _routeBounds;
  double        _totalDistanceMeters  = 0;
  int           _totalDurationSeconds = 0;

  double _remainingMeters  = 0;
  int    _remainingSeconds = 0;

  List<NavStep> _steps            = [];
  int           _currentStepIndex = 0;
  double        _distToNextTurn   = 0;

  int _stepEndConfirmCount = 0;
  static const int _stepConfirmThreshold = 3;

  StreamSubscription<Position>? _positionStream;
  Position? _currentPosition;

  final List<Position> _positionBuffer = [];
  static const int     _bufferSize     = 3;

  bool _isFollowing = true;
  bool _isOverview  = false;

  bool   _isRerouting = false;
  static const double _offRouteThreshold = 50.0;
  static const double _arrivedThreshold  = 30.0;
  bool   _hasArrived  = false;

  int _offRouteConfirmCount = 0;
  static const int _offRouteConfirmThreshold = 5;

  BitmapDescriptor? _arrowIcon;

  // 指南针
  StreamSubscription<CompassXEvent>? _compassStream;
  double _currentHeading = 0; // 来自磁力计，静止也准确

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
    _createArrowIcon().then((_) => _loadRoute(widget.startLat, widget.startLng));
    _startCompass(); // ← 新增
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _compassStream?.cancel(); // ← 新增
    _mapController?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Arrow icon
  // ─────────────────────────────────────────────

  Future<void> _createArrowIcon() async {
    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder);
    const size     = 64.0;

    canvas.drawCircle(
      const Offset(size / 2, size / 2), size / 2,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      const Offset(size / 2, size / 2), size / 2 - 4,
      Paint()..color = const Color(0xFF1A73E8),
    );
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
  // Compass
  // ─────────────────────────────────────────────

  void _startCompass() {
    _compassStream = CompassX.events.listen((CompassXEvent event) {
      if (!mounted) return;
      final heading = event.heading;
      if (heading == null) return;

      _currentHeading = heading;

      // 更新箭头 marker 朝向
      if (_currentPosition != null) {
        setState(() {
          _updateMyMarker(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
            _currentHeading,
          );
        });
      }

      // 如果正在跟随模式，地图 bearing 跟着转
      if (_isFollowing && _currentPosition != null) {
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(
            target:  LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            zoom:    17.0,
            tilt:    0,
            bearing: _currentHeading, // ← 用磁力计的 heading，静止也准
          )),
        );
      }
    });
  }

  String get _apiMode {
    switch (widget.travelMode) {
      case TravelMode.walk:  return 'walking';
      case TravelMode.drive: return 'driving';
      case TravelMode.motor: return 'driving';
    }
  }

  Future<void> _loadRoute(double fromLat, double fromLng) async {
    setState(() {
      _loading     = true;
      _error       = null;
      _isRerouting = false;
      _polylines.clear();
    });

    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$fromLat,$fromLng'
        '&destination=${widget.endLat},${widget.endLng}'
        '&mode=$_apiMode'
        '&departure_time=now'     // ← 加这个
        '&alternatives=false'     // ← 加这个
        '&key=$_apiKey',
      );

      final resp = await http.get(url);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');

      final data = json.decode(resp.body);
      if (data['status'] != 'OK') throw Exception('${data['status']}');

      final route = data['routes'][0];
      final leg   = (route['legs'] as List).first;

      final points = _decodePolyline(route['overview_polyline']['points'] as String);

      final b  = route['bounds'];
      final ne = b['northeast'];
      final sw = b['southwest'];
      final bounds = LatLngBounds(
        southwest: LatLng(sw['lat'], sw['lng']),
        northeast: LatLng(ne['lat'], ne['lng']),
      );

      // ── 修改 2：解析 steps 时加上 durationSeconds ──
      final steps = (leg['steps'] as List).map((s) {
        final rawHtml  = (s['html_instructions'] as String?) ?? '';
        final maneuver = (s['maneuver']          as String?) ?? _guessManeuver(rawHtml);
        return NavStep(
          instruction:     _stripHtml(rawHtml),
          maneuver:        maneuver,
          distanceMeters:  (s['distance']['value'] as num).toDouble(),
          durationSeconds: (s['duration']['value'] as num).toInt(), // ← 新增
          startLocation:   LatLng(s['start_location']['lat'], s['start_location']['lng']),
          endLocation:     LatLng(s['end_location']['lat'],   s['end_location']['lng']),
        );
      }).toList();

      final totalDist = (leg['distance']['value'] as num).toDouble();
      final totalDur  = (leg['duration']['value']  as num).toInt();

      if (!mounted) return;

      setState(() {
        _polylinePoints       = points;
        _routeBounds          = bounds;
        _totalDistanceMeters  = totalDist;
        _totalDurationSeconds = totalDur;
        _remainingMeters      = totalDist;
        _remainingSeconds     = totalDur;
        _steps                = steps;
        _currentStepIndex     = 0;
        _distToNextTurn       = steps.isNotEmpty ? steps[0].distanceMeters : 0;
        _loading              = false;
      });

      _drawRoute(points, fromLat, fromLng);
      _startTracking();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ─────────────────────────────────────────────
  // Map drawing
  // ─────────────────────────────────────────────

  void _drawRoute(List<LatLng> points, double fromLat, double fromLng) {
    setState(() {
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points:    points,
        color:     const Color(0xFF4A90D9),
        width:     8,
        startCap:  Cap.roundCap,
        endCap:    Cap.roundCap,
        jointType: JointType.round,
      ));

      _updateMyMarker(fromLat, fromLng, _currentPosition?.heading ?? 0);

      _markers
        ..removeWhere((m) => m.markerId.value == 'destination')
        ..add(Marker(
          markerId:   const MarkerId('destination'),
          position:   LatLng(widget.endLat, widget.endLng),
          icon:       BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
        ));
    });

    Future.delayed(const Duration(milliseconds: 300), () {
      _moveCameraToUser(fromLat, fromLng, _currentPosition?.heading ?? 0);
    });
  }

  void _updateMyMarker(double lat, double lng, double heading) {
    _markers
      ..removeWhere((m) => m.markerId.value == 'me')
      ..add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(lat, lng),
        icon:     _arrowIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        rotation: heading,
        anchor:   const Offset(0.5, 0.5),
        flat:     true,
      ));
  }

  // ─────────────────────────────────────────────
  // Camera
  // ─────────────────────────────────────────────

  void _moveCameraToUser(double lat, double lng, [double? heading]) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target:  LatLng(lat, lng),
        zoom:    17.0,
        tilt:    0,
        bearing: _currentHeading, // ← 永远用磁力计 heading，静止也准确
      )),
    );
  }

  void _recenter() {
    if (_currentPosition == null) return;
    setState(() { _isFollowing = true; _isOverview = false; });
    _moveCameraToUser(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _currentPosition!.heading,
    );
  }

  void _toggleOverview() {
    if (_routeBounds == null) return;
    setState(() {
      _isOverview  = !_isOverview;
      _isFollowing = !_isOverview;
    });
    if (_isOverview) {
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_routeBounds!, 80));
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
    final avgHeading = _positionBuffer.map((p) => p.heading).reduce((a, b) => a + b)
        / _positionBuffer.length;

    return Position(
      latitude:         avgLat,
      longitude:        avgLng,
      heading:          avgHeading,
      speed:            newPos.speed,
      accuracy:         newPos.accuracy,
      altitude:         newPos.altitude,
      timestamp:        newPos.timestamp,
      speedAccuracy:    newPos.speedAccuracy,
      altitudeAccuracy: newPos.altitudeAccuracy,
      headingAccuracy:  newPos.headingAccuracy,
    );
  }

  // ─────────────────────────────────────────────
  // GPS tracking
  // ─────────────────────────────────────────────

  void _startTracking() {
    _positionStream?.cancel();

    // GPS 暖机：进来先等 3 秒，让 GPS 稳定后才开始处理
    bool warmedUp = false;
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) warmedUp = true;
    });

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 8,
      ),
    ).listen((rawPos) {
      if (!mounted) return;

      // 暖机期间丢弃所有读数，避免一进来就乱跳
      if (!warmedUp) return;

      // 精度过滤：GPS 信号差（误差 > 20m）直接跳过这次读数
      if (rawPos.accuracy > 20) return;

      // 速度判断：< 0.5 m/s 认为用户静止
      final isMoving = rawPos.speed > 0.5;

      final pos = _smoothPosition(rawPos);

      // 1. 到达检测
      final distToDest = Geolocator.distanceBetween(
        pos.latitude, pos.longitude, widget.endLat, widget.endLng,
      );
      if (distToDest <= _arrivedThreshold && !_hasArrived) {
        _hasArrived = true;
        _positionStream?.cancel();
        _showArrivedDialog();
        return;
      }

      // 2. 偏离检测（只在移动时判断，防止静止时 GPS 漂移误触发 reroute）
      if (isMoving && !_isRerouting && _polylinePoints.isNotEmpty) {
        final minDist = _minDistToPolyline(LatLng(pos.latitude, pos.longitude));
        if (minDist > _offRouteThreshold) {
          _offRouteConfirmCount++;
          if (_offRouteConfirmCount >= _offRouteConfirmThreshold) {
            _offRouteConfirmCount = 0;
            _isRerouting = true;
            _loadRoute(pos.latitude, pos.longitude);
            return;
          }
        } else {
          _offRouteConfirmCount = 0;
        }
      }

      // 3. Step 切换（只在移动时判断，防止静止时抖动误切 step）
      if (isMoving && _steps.isNotEmpty && _currentStepIndex < _steps.length - 1) {
        final currentStep = _steps[_currentStepIndex];
        final distToStepEnd = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          currentStep.endLocation.latitude,
          currentStep.endLocation.longitude,
        );
        if (distToStepEnd < 20) {
          _stepEndConfirmCount++;
          if (_stepEndConfirmCount >= _stepConfirmThreshold) {
            _stepEndConfirmCount = 0;
            setState(() => _currentStepIndex = _currentStepIndex + 1);
          }
        } else {
          _stepEndConfirmCount = 0;
        }
      }

      // 4. 到下一个转弯的距离（只在移动时更新，静止时保持上一次的值）
      if (isMoving && _steps.isNotEmpty) {
        final nextIdx = (_currentStepIndex + 1).clamp(0, _steps.length - 1);
        _distToNextTurn = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          _steps[nextIdx].startLocation.latitude,
          _steps[nextIdx].startLocation.longitude,
        );
      }

      // 5. 更新剩余时间/距离（只在移动时更新，静止时冻结显示）
      setState(() {
        _currentPosition = pos;
        if (isMoving) {
          _remainingMeters  = _calcRemainingMeters(pos);
          _remainingSeconds = _calcRemainingSeconds(pos);
        }
        _updateMyMarker(pos.latitude, pos.longitude, pos.heading);
      });

      // 6. 相机跟随
      if (_isFollowing) {
        _moveCameraToUser(pos.latitude, pos.longitude, pos.heading);
      }
    });
  }

  // ─────────────────────────────────────────────
  // Remaining calculations (基于 API steps，不靠 hardcode 速度)
  // ─────────────────────────────────────────────

  // ── 修改 3：_calcRemainingSeconds 用 steps 的 durationSeconds 累加 ──
  int _calcRemainingSeconds(Position pos) {
    if (_steps.isEmpty) return 0;

    int futureSeconds = 0;
    for (int i = _currentStepIndex + 1; i < _steps.length; i++) {
      futureSeconds += _steps[i].durationSeconds;
    }

    final currentStep   = _steps[_currentStepIndex];
    final distToStepEnd = Geolocator.distanceBetween(
      pos.latitude, pos.longitude,
      currentStep.endLocation.latitude,
      currentStep.endLocation.longitude,
    );
    final stepRatio = currentStep.distanceMeters > 0
        ? (distToStepEnd / currentStep.distanceMeters).clamp(0.0, 1.0)
        : 0.0;

    final currentStepRemaining = (currentStep.durationSeconds * stepRatio).toInt();
    return currentStepRemaining + futureSeconds;
  }

  double _calcRemainingMeters(Position pos) {
    if (_steps.isEmpty) return 0;

    double futureMeters = 0;
    for (int i = _currentStepIndex + 1; i < _steps.length; i++) {
      futureMeters += _steps[i].distanceMeters;
    }

    final currentStep   = _steps[_currentStepIndex];
    final distToStepEnd = Geolocator.distanceBetween(
      pos.latitude, pos.longitude,
      currentStep.endLocation.latitude,
      currentStep.endLocation.longitude,
    );

    return distToStepEnd.clamp(0.0, currentStep.distanceMeters) + futureMeters;
  }

  // ─────────────────────────────────────────────
  // Arrived
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

  double _minDistToPolyline(LatLng point) {
    if (_polylinePoints.isEmpty) return double.infinity;

    int    nearestIdx  = 0;
    double nearestDist = double.infinity;
    for (int i = 0; i < _polylinePoints.length; i++) {
      final d = Geolocator.distanceBetween(
        point.latitude, point.longitude,
        _polylinePoints[i].latitude, _polylinePoints[i].longitude,
      );
      if (d < nearestDist) { nearestDist = d; nearestIdx = i; }
    }

    final start  = (nearestIdx - 15).clamp(0, _polylinePoints.length - 1);
    final end    = (nearestIdx + 15).clamp(0, _polylinePoints.length - 1);
    double minDist = double.infinity;

    for (int i = start; i < end; i++) {
      final segDist = _distToSegment(
        point,
        _polylinePoints[i],
        _polylinePoints[(i + 1).clamp(0, _polylinePoints.length - 1)],
      );
      if (segDist < minDist) minDist = segDist;
    }

    return minDist;
  }

  double _distToSegment(LatLng p, LatLng a, LatLng b) {
    final double ax = a.longitude, ay = a.latitude;
    final double bx = b.longitude, by = b.latitude;
    final double px = p.longitude,  py = p.latitude;
    final double dx = bx - ax,      dy = by - ay;

    if (dx == 0 && dy == 0) {
      return Geolocator.distanceBetween(py, px, ay, ax);
    }

    final double t        = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    final double clamped  = t.clamp(0.0, 1.0);
    return Geolocator.distanceBetween(py, px, ay + clamped * dy, ax + clamped * dx);
  }

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

  String _stripHtml(String html) =>
      html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  String _guessManeuver(String html) {
    final lower = html.toLowerCase();
    if (lower.contains('turn right'))   return 'turn-right';
    if (lower.contains('turn left'))    return 'turn-left';
    if (lower.contains('u-turn'))       return 'uturn';
    if (lower.contains('roundabout'))   return 'roundabout';
    if (lower.contains('merge'))        return 'merge';
    if (lower.contains('slight right')) return 'turn-slight-right';
    if (lower.contains('slight left'))  return 'turn-slight-left';
    if (lower.contains('keep right'))   return 'keep-right';
    if (lower.contains('keep left'))    return 'keep-left';
    return 'straight';
  }

  IconData _maneuverIcon(String maneuver) {
    if (maneuver.contains('right'))      return Icons.turn_right_rounded;
    if (maneuver.contains('left'))       return Icons.turn_left_rounded;
    if (maneuver.contains('uturn'))      return Icons.u_turn_left_rounded;
    if (maneuver.contains('roundabout')) return Icons.roundabout_left_rounded;
    if (maneuver.contains('merge'))      return Icons.merge_rounded;
    if (maneuver.contains('ramp'))       return Icons.turn_slight_right_rounded;
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

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(children: [

        // ── Map ──
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: LatLng(widget.startLat, widget.startLng),
            zoom: 17.0, tilt: 0, // ← 从 20.5 降到 17，让用户看到前方路线
          ),
          markers:                 _markers,
          polylines:               _polylines,
          myLocationEnabled:       false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled:     false,
          compassEnabled:          true,
          onMapCreated: (c) {
            _mapController = c;
            c.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(
              target: LatLng(widget.startLat, widget.startLng),
              zoom: 17.0, tilt: 0,
            )));
          },
          onCameraMoveStarted: () {
            if (_isFollowing) setState(() => _isFollowing = false);
          },
          // top padding = 方向 bar 高度（约 100）+ status bar，让地图内容不被遮挡
          padding: EdgeInsets.only(
            top:    MediaQuery.of(context).padding.top + 100,
            bottom: 160,
          ),
        ),

        // ── Turn-by-turn banner ──
        if (step != null)
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              color: Colors.black87,
              padding: EdgeInsets.fromLTRB(
                  20, MediaQuery.of(context).padding.top + 12, 20, 16),
              child: Row(children: [
                Icon(_maneuverIcon(step.maneuver), color: Colors.white, size: 44),
                const SizedBox(width: 16),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDistance(_distToNextTurn),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
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
          ),

        // ── Right buttons ──
        Positioned(
          right: 16, bottom: 180,
          child: Column(children: [
            if (!_isFollowing) ...[
              _circleBtn(
                icon: Icons.my_location_rounded,
                color: Colors.white,
                iconColor: const Color(0xFF1A73E8),
                onTap: _recenter,
              ),
              const SizedBox(height: 12),
            ],
            _circleBtn(
              icon: _isOverview ? Icons.navigation_rounded : Icons.map_rounded,
              color: _isOverview ? const Color(0xFF1A73E8) : Colors.white,
              iconColor: _isOverview ? Colors.white : Colors.black87,
              onTap: _toggleOverview,
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
    required IconData  icon,
    required Color     color,
    required Color     iconColor,
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