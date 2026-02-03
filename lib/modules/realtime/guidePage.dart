// AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// 返回给 DetectPage 用的结果
class RouteResult {
  final List<LatLng> polylinePoints;
  final LatLngBounds bounds;

  RouteResult({
    required this.polylinePoints,
    required this.bounds,
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
      final points = await _fetchRoutePolyline(
        widget.startLat,
        widget.startLng,
        widget.endLat,
        widget.endLng,
      );

      if (points.isEmpty) {
        throw Exception('路线为空');
      }

      final bounds = _computeBounds(points);

      // ✅ 把结果 pop 回 DetectPage
      if (mounted) {
        Navigator.pop(
          context,
          RouteResult(
            polylinePoints: points,
            bounds: bounds,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 调用 Google Directions API 拿 polyline
  Future<List<LatLng>> _fetchRoutePolyline(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) async {
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

    final routes = data['routes'] as List;
    if (routes.isEmpty) return [];

    final overviewPolyline = routes[0]['overview_polyline']['points'] as String;

    return _decodePolyline(overviewPolyline);
  }

  /// 解 Google polyline
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

  /// 计算整条路线的 bounds，用来 zoom 到整条路线
  LatLngBounds _computeBounds(List<LatLng> points) {
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 这个页面只是个“中转计算页”，用户几乎看不到
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
