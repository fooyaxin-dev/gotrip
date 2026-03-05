import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../../services/route_service.dart'; // ← 统一用 route_service 的 RouteResult

// 单步导航指令
class NavStep {
  final String instruction;
  final String maneuver;
  final double distanceMeters;
  final LatLng startLocation;
  final LatLng endLocation;

  NavStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
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
  final TravelMode travelMode; // ← 支持 walk / drive

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

  // 路线数据
  List<LatLng> _polylinePoints = [];
  LatLngBounds? _routeBounds;
  double _totalDistanceMeters  = 0;
  int    _totalDurationSeconds = 0;

  // 剩余
  double _remainingMeters  = 0;
  int    _remainingSeconds = 0;

  // Steps
  List<NavStep> _steps           = [];
  int           _currentStepIndex = 0;
  double        _distToNextTurn   = 0;

  // GPS
  StreamSubscription<Position>? _positionStream;
  Position? _currentPosition;

  // Camera
  bool _isFollowing = true;
  bool _isOverview  = false;

  // Reroute
  bool _isRerouting = false;
  static const double _offRouteThreshold = 50.0;
  static const double _arrivedThreshold  = 30.0;
  bool _hasArrived = false;

  // Arrow marker
  BitmapDescriptor? _arrowIcon;

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
  }

  @override
  void dispose() {
    _positionStream?.cancel();
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

    // 白色外圆
    canvas.drawCircle(
      const Offset(size / 2, size / 2), size / 2,
      Paint()..color = Colors.white,
    );
    // 蓝色内圆
    canvas.drawCircle(
      const Offset(size / 2, size / 2), size / 2 - 4,
      Paint()..color = const Color(0xFF1A73E8),
    );
    // 白色箭头
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
  // Route loading
  // ─────────────────────────────────────────────

  // Google Directions API mode string
  String get _apiMode {
    switch (widget.travelMode) {
      case TravelMode.walk:   return 'walking';
      case TravelMode.drive:  return 'driving';
      case TravelMode.motor:  return 'driving'; // motor → driving
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
        '&key=$_apiKey',
      );

      final resp = await http.get(url);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');

      final data = json.decode(resp.body);
      print('🗺️ Steps: ${json.encode(data['routes'][0]['legs'][0]['steps'])}');
      if (data['status'] != 'OK') throw Exception('${data['status']}');

      final route = data['routes'][0];
      final leg   = (route['legs'] as List).first;

      // Polyline
      final points = _decodePolyline(route['overview_polyline']['points'] as String);

      // Bounds
      final b  = route['bounds'];
      final ne = b['northeast'];
      final sw = b['southwest'];
      final bounds = LatLngBounds(
        southwest: LatLng(sw['lat'], sw['lng']),
        northeast: LatLng(ne['lat'], ne['lng']),
      );

      // Steps
      final steps = (leg['steps'] as List).map((s) {
      final rawHtml  = (s['html_instructions'] as String?) ?? '';
      final maneuver = (s['maneuver'] as String?) ?? _guessManeuver(rawHtml); // ← 改这行
      return NavStep(
        instruction:    _stripHtml(rawHtml),
        maneuver:       maneuver,
        distanceMeters: (s['distance']['value'] as num).toDouble(),
        startLocation:  LatLng(s['start_location']['lat'], s['start_location']['lng']),
        endLocation:    LatLng(s['end_location']['lat'],   s['end_location']['lng']),
      );
    }).toList();

    

      final totalDist = (leg['distance']['value'] as num).toDouble();
      final totalDur  = (leg['duration']['value']  as num).toInt();

      if (!mounted) return;

      setState(() {
        _polylinePoints      = points;
        _routeBounds         = bounds;
        _totalDistanceMeters = totalDist;
        _totalDurationSeconds= totalDur;
        _remainingMeters     = totalDist;
        _remainingSeconds    = totalDur;
        _steps               = steps;
        _currentStepIndex    = 0;
        _distToNextTurn      = steps.isNotEmpty ? steps[0].distanceMeters : 0;
        _loading             = false;
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

  void _moveCameraToUser(double lat, double lng, double heading) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target:  LatLng(lat, lng),
        zoom:    20.5,
        tilt:    0,
        bearing: heading,
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
  // GPS tracking
  // ─────────────────────────────────────────────

  void _startTracking() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((pos) {
      if (!mounted) return;

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

      // 2. 偏离检测
      if (!_isRerouting && _polylinePoints.isNotEmpty) {
        final minDist = _minDistToPolyline(LatLng(pos.latitude, pos.longitude));
        if (minDist > _offRouteThreshold) {
          _isRerouting = true;
          _loadRoute(pos.latitude, pos.longitude);
          return;
        }
      }

      // 3. Step 切换 — 看用户有没有过了当前 step 的 endLocation
      if (_steps.isNotEmpty && _currentStepIndex < _steps.length - 1) {
        final currentStep = _steps[_currentStepIndex];
        final distToStepEnd = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          currentStep.endLocation.latitude,
          currentStep.endLocation.longitude,
        );
        if (distToStepEnd < 20) {
          // 切换到下一步
          setState(() => _currentStepIndex = _currentStepIndex + 1);
        }
      }

      // 4. 计算到下一个转弯的距离
      if (_steps.isNotEmpty) {
        final nextIdx = min(_currentStepIndex + 1, _steps.length - 1);
        _distToNextTurn = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          _steps[nextIdx].startLocation.latitude,
          _steps[nextIdx].startLocation.longitude,
        );
      }

      // 5. 更新剩余时间/距离
      setState(() {
        _currentPosition = pos;
        _remainingMeters = distToDest;
        if (_totalDistanceMeters > 0) {
          _remainingSeconds = (_totalDurationSeconds *
              (distToDest / _totalDistanceMeters)).round();
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
    double min = double.infinity;
    for (final p in _polylinePoints) {
      final d = Geolocator.distanceBetween(
          point.latitude, point.longitude, p.latitude, p.longitude);
      if (d < min) min = d;
    }
    return min;
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
    if (maneuver.contains('right'))       return Icons.turn_right_rounded;
    if (maneuver.contains('left'))        return Icons.turn_left_rounded;
    if (maneuver.contains('uturn'))       return Icons.u_turn_left_rounded;
    if (maneuver.contains('roundabout'))  return Icons.roundabout_left_rounded;
    if (maneuver.contains('merge'))       return Icons.merge_rounded;
    if (maneuver.contains('ramp'))        return Icons.turn_slight_right_rounded;
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
            ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Go back')),
          ],
        )),
      );
    }

    final step = _steps.isNotEmpty ? _steps[_currentStepIndex] : null;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(children: [

        // ── 地图 ──
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: LatLng(widget.startLat, widget.startLng),
            zoom: 20.5, tilt: 0,
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
              zoom: 20.5, tilt: 0,
            )));
          },
          onCameraMoveStarted: () {
            if (_isFollowing) setState(() => _isFollowing = false);
          },
          padding: const EdgeInsets.only(bottom: 160),
        ),

        // ── 顶部 turn-by-turn banner ──
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

        // ── 右侧按钮 ──
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

        // ── 底部面板 ──
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
                              fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87)),
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

        // ── 偏离 banner ──
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