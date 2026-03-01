import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// 路线结果（DetectPage 里用直线估算时仍需要此 model，故保留）
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

class GuidePage extends StatefulWidget {
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName; // 可选：显示目的地名称

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
  // ── 地图 ──
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  // ── 路线 ──
  bool _loading = true;
  String? _error;
  RouteResult? _routeResult;

  // ── GPS 跟踪 ──
  StreamSubscription<Position>? _positionStream;
  Position? _currentPosition;

  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _currentPosition = Position(
      latitude: widget.startLat,
      longitude: widget.startLng,
      timestamp: DateTime.now(),
      accuracy: 1,
      altitude: 0,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
      altitudeAccuracy: 0.0,
      headingAccuracy: 0.0,
    );
    _loadRoute();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Route loading
  // ─────────────────────────────────────────────

  Future<void> _loadRoute() async {
    try {
      final result = await _fetchRoute(
        widget.startLat,
        widget.startLng,
        widget.endLat,
        widget.endLng,
      );

      if (!mounted) return;

      setState(() {
        _routeResult = result;
        _loading = false;
      });

      _drawRoute(result);
      _startNavigationTracking();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<RouteResult> _fetchRoute(
      double startLat, double startLng, double endLat, double endLng) async {
    final url = 'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$startLat,$startLng'
        '&destination=$endLat,$endLng'
        '&mode=driving'
        '&key=$_apiKey';

    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Directions API 请求失败: ${resp.statusCode}');
    }

    final data = json.decode(resp.body);
    if (data['status'] != 'OK') {
      throw Exception('Directions API 错误: ${data['status']}');
    }

    final route = data['routes'][0];
    final polylinePoints = _decodePolyline(route['overview_polyline']['points'] as String);
    final bounds = _parseBounds(route['bounds']);
    final leg = (route['legs'] as List).first;
    final distanceMeters = (leg['distance']['value'] as num).toDouble();
    final durationSeconds = (leg['duration']['value'] as num).toInt();

    return RouteResult(
      polylinePoints: polylinePoints,
      bounds: bounds,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
    );
  }

  // ─────────────────────────────────────────────
  // Map drawing
  // ─────────────────────────────────────────────

  void _drawRoute(RouteResult result) {
    setState(() {
      // 路线
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: result.polylinePoints,
        color: Colors.blue,
        width: 6,
      ));

      // 当前位置 marker
      _markers.add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(widget.startLat, widget.startLng),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: '我的位置'),
      ));

      // 目的地 marker
      _markers.add(Marker(
        markerId: const MarkerId('destination'),
        position: LatLng(widget.endLat, widget.endLng),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: widget.destinationName ?? '目的地'),
      ));
    });

    // 等地图创建好后再移动相机
    Future.delayed(const Duration(milliseconds: 300), () {
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: result.polylinePoints.first,
            zoom: 18.0,
            tilt: 0,
            bearing: 0,
          ),
        ),
      );
    });
  }

  // ─────────────────────────────────────────────
  // GPS tracking
  // ─────────────────────────────────────────────

  void _startNavigationTracking() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((Position position) {
      if (_mapController == null || !mounted) return;

      setState(() {
        _currentPosition = position;

        // 更新位置 marker
        _markers.removeWhere((m) => m.markerId.value == 'me');
        _markers.add(Marker(
          markerId: const MarkerId('me'),
          position: LatLng(position.latitude, position.longitude),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          rotation: position.heading,
          anchor: const Offset(0.5, 0.5),
        ));
      });

      // 相机跟随
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 18.0,
            tilt: 0,
            bearing: 0,
          ),
        ),
      );
    });
  }

  // ─────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────

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
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

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
    final rem = mins % 60;
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
    // 加载中 / 出错 状态
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在计算路线...', style: TextStyle(fontSize: 16, color: Colors.grey)),
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
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }

    final route = _routeResult!;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── 地图 ──
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(widget.startLat, widget.startLng),
              zoom: 14,
            ),
            markers: _markers,
            polylines: _polylines,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            onMapCreated: (controller) {
              _mapController = controller;
              // 地图创建后立刻移到路线起点
              controller.animateCamera(
                CameraUpdate.newCameraPosition(
                  CameraPosition(
                    target: route.polylinePoints.first,
                    zoom: 18.0,
                    tilt: 0,
                  ),
                ),
              );
            },
            padding: const EdgeInsets.only(bottom: 200),
          ),

          // ── 返回按钮 ──
          Positioned(
            top: 50,
            left: 20,
            child: SafeArea(
              child: Material(
                elevation: 4,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                color: Colors.white,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, size: 20, color: Colors.black87),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),

          // ── 底部导航信息面板 ──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                24, 20, 24,
                20 + MediaQuery.of(context).padding.bottom,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 20,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 把手
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // 时间 + 距离
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _formatDuration(route.durationSeconds),
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '(${_formatDistance(route.distanceMeters)})',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),

                  // 目的地名称
                  if (widget.destinationName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 16),
                      child: Row(
                        children: [
                          Icon(Icons.location_on_rounded, size: 16, color: Colors.red[400]),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              widget.destinationName!,
                              style: TextStyle(fontSize: 15, color: Colors.grey[600]),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    const SizedBox(height: 16),

                  // 操作按钮
                  Row(
                    children: [
                      // 取消
                      Expanded(
                        flex: 1,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: BorderSide(color: Colors.grey[300]!),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('取消', style: TextStyle(color: Colors.black87)),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // 重新规划路线
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _error = null;
                              _polylines.clear();
                            });
                            _loadRoute();
                          },
                          icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                          label: const Text('重新规划',
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).primaryColor,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}