import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// 返回给 DetectPage 用的结果
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

  const GuidePage({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
  });

  @override
  State<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends State<GuidePage> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRoute();
  }

  Future<void> _loadRoute() async {
    try {
      final result = await _fetchRoute(
        widget.startLat,
        widget.startLng,
        widget.endLat,
        widget.endLng,
      );

      // 返回给 DetectPage
      if (mounted) {
        Navigator.pop(context, result);
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 调用 Google Directions API，返回 RouteResult
  Future<RouteResult> _fetchRoute(
      double startLat, double startLng, double endLat, double endLng) async {
    const apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';

    final url =
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$startLat,$startLng'
        '&destination=$endLat,$endLng'
        '&mode=driving'
        '&key=$apiKey';

    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Directions API 请求失败: ${resp.statusCode}');
    }

    final data = json.decode(resp.body);

    if (data['status'] != 'OK') {
      throw Exception('Directions API 错误: ${data['status']}');
    }

    final route = data['routes'][0];

    // 解码 polyline
    final overviewPolyline = route['overview_polyline']['points'] as String;
    final polylinePoints = _decodePolyline(overviewPolyline);

    // bounds
    final bounds = _parseBounds(route['bounds']);

    // distance & duration
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

  /// Google polyline 解码
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

  /// 解析 Google bounds
  LatLngBounds _parseBounds(Map<String, dynamic> bounds) {
    final ne = bounds['northeast'];
    final sw = bounds['southwest'];
    return LatLngBounds(
      southwest: LatLng(sw['lat'], sw['lng']),
      northeast: LatLng(ne['lat'], ne['lng']),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: _loading
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在计算路线...'),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error, color: Colors.red, size: 48),
                  const SizedBox(height: 12),
                  Text(_error ?? '加载失败'),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'),
                  ),
                ],
              ),
      ),
    );
  }
}
