import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

class RouteResult {
  final List<LatLng> polylinePoints;
  final LatLngBounds bounds;
  final double distanceMeters;
  final int durationSeconds;

  RouteResult({
    required this.polylinePoints,
    required this.bounds,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

// 单步导航指令
class NavStep {
  final String instruction; // 纯文字指令，e.g. "Turn right onto Jalan Besar"
  final String maneuver;    // e.g. "turn-right", "turn-left", "straight"
  final double distanceMeters;
  final LatLng startLocation;

  NavStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
    required this.startLocation,
  });
}

class GuidePage extends StatefulWidget {
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName;

  const GuidePage({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
  });

  @override
  State<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends State<GuidePage> {
  GoogleMapController? _mapController;
  final Set<Marker> _markers    = {};
  final Set<Polyline> _polylines = {};

  bool   _loading = true;
  String? _error;
  RouteResult? _routeResult;

  // 剩余
  double _remainingMeters  = 0;
  int    _remainingSeconds = 0;

  // Steps (turn-by-turn)
  List<NavStep> _steps        = [];
  int           _currentStep  = 0;
  double        _distToNextStep = 0;

  // GPS
  StreamSubscription<Position>? _positionStream;
  Position? _currentPosition;

  // Re-center
  bool _isFollowing = true; // true = 相机跟着用户走

  // Overview
  bool _isOverview = false;

  // Reroute
  bool _isRerouting = false;
  static const double _offRouteThresholdMeters = 50.0;
  static const double _arrivedThresholdMeters  = 30.0;
  bool _hasArrived = false;

  // 自定义箭头 marker
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
  // 用 Canvas 画自定义箭头 marker
  // ─────────────────────────────────────────────

  Future<void> _createArrowIcon() async {
    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder);
    const size     = 60.0;

    // 外圆（白色）
    final outerPaint = Paint()..color = Colors.white;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, outerPaint);

    // 内圆（蓝色）
    final innerPaint = Paint()..color = const Color(0xFF1A73E8);
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 4, innerPaint);

    // 箭头（白色三角形，指向上方）
    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(size / 2, 8);           // 顶点
    path.lineTo(size / 2 + 14, size - 10); // 右下
    path.lineTo(size / 2, size - 18);   // 中间凹
    path.lineTo(size / 2 - 14, size - 10); // 左下
    path.close();
    canvas.drawPath(path, arrowPaint);

    final picture = recorder.endRecording();
    final image   = await picture.toImage(size.toInt(), size.toInt());
    final bytes   = await image.toByteData(format: ui.ImageByteFormat.png);

    if (bytes != null) {
      _arrowIcon = BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
    }
  }

  // ─────────────────────────────────────────────
  // Route loading
  // ─────────────────────────────────────────────

  Future<void> _loadRoute(double fromLat, double fromLng) async {
    setState(() {
      _loading    = true;
      _error      = null;
      _polylines.clear();
      _isRerouting = false;
    });

    try {
      final result = await _fetchRoute(fromLat, fromLng, widget.endLat, widget.endLng);
      if (!mounted) return;

      setState(() {
        _routeResult      = result.route;
        _steps            = result.steps;
        _currentStep      = 0;
        _remainingMeters  = result.route.distanceMeters;
        _remainingSeconds = result.route.durationSeconds;
        _loading          = false;
      });

      _drawRoute(result.route, fromLat, fromLng);
      _startNavigationTracking();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<({RouteResult route, List<NavStep> steps})> _fetchRoute(
      double startLat, double startLng, double endLat, double endLng) async {
    final url = 'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$startLat,$startLng'
        '&destination=$endLat,$endLng'
        '&mode=driving'
        '&key=$_apiKey';

    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) throw Exception('Directions API failed: ${resp.statusCode}');

    final data = json.decode(resp.body);
    if (data['status'] != 'OK') throw Exception('Directions error: ${data['status']}');

    final route          = data['routes'][0];
    final polylinePoints = _decodePolyline(route['overview_polyline']['points'] as String);
    final bounds         = _parseBounds(route['bounds']);
    final leg            = (route['legs'] as List).first;

    // 解析 steps
    final steps = (leg['steps'] as List).map((s) {
      final maneuver    = (s['maneuver'] as String?) ?? 'straight';
      final rawHtml     = s['html_instructions'] as String? ?? '';
      final instruction = _stripHtml(rawHtml);
      final dist        = (s['distance']['value'] as num).toDouble();
      final startLoc    = s['start_location'];
      return NavStep(
        instruction:    instruction,
        maneuver:       maneuver,
        distanceMeters: dist,
        startLocation:  LatLng(startLoc['lat'], startLoc['lng']),
      );
    }).toList();

    final routeResult = RouteResult(
      polylinePoints: polylinePoints,
      bounds:         bounds,
      distanceMeters: (leg['distance']['value'] as num).toDouble(),
      durationSeconds:(leg['duration']['value'] as num).toInt(),
    );

    return (route: routeResult, steps: steps);
  }

  // 去掉 HTML tag
  String _stripHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ─────────────────────────────────────────────
  // Map drawing
  // ─────────────────────────────────────────────

  void _drawRoute(RouteResult result, double fromLat, double fromLng) {
    setState(() {
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points:     result.polylinePoints,
        color:      const Color(0xFF5B3FD6), // 紫色，像 Waze
        width:      8,
        startCap:   Cap.roundCap,
        endCap:     Cap.roundCap,
        jointType:  JointType.round,
      ));

      _updateMyMarker(fromLat, fromLng, 0);

      _markers
        ..removeWhere((m) => m.markerId.value == 'destination')
        ..add(Marker(
          markerId:    const MarkerId('destination'),
          position:    LatLng(widget.endLat, widget.endLng),
          icon:        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow:  InfoWindow(title: widget.destinationName ?? 'Destination'),
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
        flat:     true, // marker 跟着地图转
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
    setState(() {
      _isFollowing = true;
      _isOverview  = false;
    });
    _moveCameraToUser(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _currentPosition!.heading,
    );
  }

  void _toggleOverview() {
    if (_routeResult == null) return;
    setState(() {
      _isOverview  = !_isOverview;
      _isFollowing = !_isOverview;
    });

    if (_isOverview) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(_routeResult!.bounds, 80),
      );
    } else {
      _recenter();
    }
  }

  // ─────────────────────────────────────────────
  // GPS tracking
  // ─────────────────────────────────────────────

  void _startNavigationTracking() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((Position position) {
      if (!mounted) return;

      final userLatLng = LatLng(position.latitude, position.longitude);

      // ── 1. 到达检测 ──────────────────────────
      final distToDest = Geolocator.distanceBetween(
        position.latitude, position.longitude,
        widget.endLat, widget.endLng,
      );
      if (distToDest <= _arrivedThresholdMeters && !_hasArrived) {
        _hasArrived = true;
        _positionStream?.cancel();
        _showArrivedDialog();
        return;
      }

      // ── 2. 偏离检测 ──────────────────────────
      if (!_isRerouting && _routeResult != null) {
        final minDist = _minDistanceToRoute(userLatLng, _routeResult!.polylinePoints);
        if (minDist > _offRouteThresholdMeters) {
          _isRerouting = true;
          _loadRoute(position.latitude, position.longitude);
          return;
        }
      }

      // ── 3. 更新当前 step ──────────────────────
      if (_steps.isNotEmpty) {
        int nextStep = _currentStep;
        for (int i = _currentStep; i < _steps.length - 1; i++) {
          final distToStep = Geolocator.distanceBetween(
            position.latitude, position.longitude,
            _steps[i + 1].startLocation.latitude,
            _steps[i + 1].startLocation.longitude,
          );
          if (distToStep < 30) { // 30m 内切换到下一步
            nextStep = i + 1;
            break;
          }
        }

        // 计算到下一步的距离
        final nextStepIndex = min(_currentStep + 1, _steps.length - 1);
        _distToNextStep = Geolocator.distanceBetween(
          position.latitude, position.longitude,
          _steps[nextStepIndex].startLocation.latitude,
          _steps[nextStepIndex].startLocation.longitude,
        );

        setState(() => _currentStep = nextStep);
      }

      // ── 4. 剩余距离/时间 ─────────────────────
      setState(() {
        _currentPosition  = position;
        _remainingMeters  = distToDest;
        if (_routeResult != null && _routeResult!.distanceMeters > 0) {
          _remainingSeconds = (_routeResult!.durationSeconds *
              (distToDest / _routeResult!.distanceMeters)).round();
        }
        _updateMyMarker(position.latitude, position.longitude, position.heading);
      });

      // ── 5. 相机跟随 ──────────────────────────
      if (_isFollowing) {
        _moveCameraToUser(position.latitude, position.longitude, position.heading);
      }
    });
  }

  // ─────────────────────────────────────────────
  // Turn icon
  // ─────────────────────────────────────────────

  IconData _maneuverIcon(String maneuver) {
    if (maneuver.contains('right'))      return Icons.turn_right_rounded;
    if (maneuver.contains('left'))       return Icons.turn_left_rounded;
    if (maneuver.contains('uturn'))      return Icons.u_turn_left_rounded;
    if (maneuver.contains('roundabout')) return Icons.roundabout_left_rounded;
    if (maneuver.contains('merge'))      return Icons.merge_rounded;
    return Icons.straight_rounded;
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
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
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

  double _minDistanceToRoute(LatLng point, List<LatLng> polyline) {
    double minDist = double.infinity;
    for (final p in polyline) {
      final d = Geolocator.distanceBetween(
          point.latitude, point.longitude, p.latitude, p.longitude);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      shift = 0; result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  LatLngBounds _parseBounds(Map<String, dynamic> bounds) {
    final ne = bounds['northeast'];
    final sw = bounds['southwest'];
    return LatLngBounds(
      southwest: LatLng(sw['lat'], sw['lng']),
      northeast: LatLng(ne['lat'], ne['lng']),
    );
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds sec';
    final mins = seconds ~/ 60;
    if (mins < 60) return '$mins min';
    final hours = mins ~/ 60;
    final rem   = mins % 60;
    return rem == 0 ? '${hours}h' : '${hours}h ${rem}min';
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _isRerouting ? 'Recalculating route...' : 'Calculating route...',
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
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
          ),
        ),
      );
    }

    final currentStepData = _steps.isNotEmpty ? _steps[_currentStep] : null;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [

          // ── 地图 ──────────────────────────────
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(widget.startLat, widget.startLng),
              zoom: 18.0, tilt: 60,
            ),
            markers:                 _markers,
            polylines:               _polylines,
            myLocationEnabled:       false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled:     false,
            compassEnabled:          true,
            onMapCreated: (controller) {
              _mapController = controller;
              if (_routeResult != null) {
                controller.animateCamera(
                  CameraUpdate.newCameraPosition(CameraPosition(
                    target: _routeResult!.polylinePoints.first,
                    zoom: 20.5,
                    tilt: 0,
                  )),
                );
              }
            },
            // 用户手动移动地图时停止跟随
            onCameraMoveStarted: () {
              if (_isFollowing) setState(() => _isFollowing = false);
            },
            padding: const EdgeInsets.only(bottom: 160),
          ),

          // ── 顶部 turn-by-turn banner ──────────
          if (currentStepData != null)
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                color: Colors.black,
                padding: EdgeInsets.fromLTRB(
                  20, 48 + MediaQuery.of(context).padding.top, 20, 16),
                child: Row(
                  children: [
                    // 转向图标
                    Icon(
                      _maneuverIcon(currentStepData.maneuver),
                      color: Colors.white,
                      size: 42,
                    ),
                    const SizedBox(width: 16),
                    // 距离 + 指令
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _formatDistance(_distToNextStep),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            currentStepData.instruction,
                            style: TextStyle(
                              color: Colors.grey[300],
                              fontSize: 14,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── 右侧按钮组 ────────────────────────
          Positioned(
            right: 16,
            bottom: 180,
            child: Column(
              children: [
                // Re-center 按钮（只在不跟随时显示）
                if (!_isFollowing)
                  _buildCircleButton(
                    icon: Icons.my_location_rounded,
                    color: Colors.white,
                    iconColor: const Color(0xFF1A73E8),
                    onTap: _recenter,
                    tooltip: 'Re-center',
                  ),
                const SizedBox(height: 12),
                // Overview 按钮
                _buildCircleButton(
                  icon: _isOverview ? Icons.navigation_rounded : Icons.map_rounded,
                  color: _isOverview ? const Color(0xFF1A73E8) : Colors.white,
                  iconColor: _isOverview ? Colors.white : Colors.black87,
                  onTap: _toggleOverview,
                  tooltip: _isOverview ? 'Follow' : 'Overview',
                ),
              ],
            ),
          ),

          // ── 底部信息面板 ──────────────────────
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                24, 16, 24,
                16 + MediaQuery.of(context).padding.bottom,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 20,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // 左边：时间 + 距离 + 目的地
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              _formatDuration(_remainingSeconds),
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatDistance(_remainingMeters),
                              style: TextStyle(
                                fontSize: 15,
                                color: Colors.grey[600],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        if (widget.destinationName != null)
                          Row(
                            children: [
                              Icon(Icons.location_on_rounded,
                                  size: 14, color: Colors.red[400]),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  widget.destinationName!,
                                  style: TextStyle(
                                      fontSize: 13, color: Colors.grey[500]),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),

                  // 右边：取消按钮
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
                ],
              ),
            ),
          ),

          // ── 偏离 banner ───────────────────────
          if (_isRerouting)
            Positioned(
              top: 160, left: 20, right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orange[700],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.refresh_rounded,
                        color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text('Off route, recalculating...',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Circle button helper
  // ─────────────────────────────────────────────

  Widget _buildCircleButton({
    required IconData icon,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, color: iconColor, size: 24),
        ),
      ),
    );
  }
}