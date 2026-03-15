//导航精度

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../../services/route_service.dart';
import 'guidePage.dart'; 

// ─────────────────────────────────────────────────────────
// 每个 travel mode 的路线摘要
// ─────────────────────────────────────────────────────────
class _ModeSummary {
  final TravelMode mode;
  int durationSeconds;
  double distanceMeters;
  bool loading;
  String? error;

  _ModeSummary({
    required this.mode,
    this.durationSeconds = 0,
    this.distanceMeters  = 0,
    this.loading         = true,
    this.error,
  });
}

// ─────────────────────────────────────────────────────────
// RoutePreviewPage
// ─────────────────────────────────────────────────────────
class RoutePreviewPage extends StatefulWidget {
  final double  startLat;
  final double  startLng;
  final double  endLat;
  final double  endLng;
  final String? destinationName;

  const RoutePreviewPage({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
  });

  @override
  State<RoutePreviewPage> createState() => _RoutePreviewPageState();
}

class _RoutePreviewPageState extends State<RoutePreviewPage> {
  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc'; 

  GoogleMapController? _mapController;
  final Set<Polyline>  _polylines = {};
  final Set<Marker>    _markers   = {};

  TravelMode _selectedMode = TravelMode.drive;

  // 三个 mode 的摘要
  final Map<TravelMode, _ModeSummary> _summaries = {
    TravelMode.drive: _ModeSummary(mode: TravelMode.drive),
    TravelMode.motor: _ModeSummary(mode: TravelMode.motor),
    TravelMode.walk:  _ModeSummary(mode: TravelMode.walk),
  };

  // 当前选中 mode 对应的 polyline 点
  List<LatLng> _currentPolyline = [];
  LatLngBounds? _currentBounds;

  @override
  void initState() {
    super.initState();
    _fetchAll();
    _setEndMarker();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  // ── 设置终点 marker ──
  void _setEndMarker() {
    _markers.add(Marker(
      markerId: const MarkerId('end'),
      position: LatLng(widget.endLat, widget.endLng),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
    ));
    _markers.add(Marker(
      markerId: const MarkerId('start'),
      position: LatLng(widget.startLat, widget.startLng),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      infoWindow: const InfoWindow(title: 'Your location'),
    ));
  }

  // ── 并行拉取三个 mode 的路线 ──
  void _fetchAll() {
    _fetchMode(TravelMode.walk);   // walking
    _fetchMode(TravelMode.drive);  // driving
    // motor 直接复用 drive 的结果，不打 API
  }

  String _apiModeString(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk:  return 'walking';
      case TravelMode.drive: return 'driving';
      case TravelMode.motor: return 'driving'; // motor → driving
    }
  }

  Future<void> _fetchMode(TravelMode mode) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${widget.startLat},${widget.startLng}'
        '&destination=${widget.endLat},${widget.endLng}'
        '&mode=${_apiModeString(mode)}'
        '&departure_time=now'     // ← 加这个
        '&alternatives=false'     // ← 加这个
        '&key=$_apiKey',
      );
      final resp = await http.get(url);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final data = json.decode(resp.body);
      if (data['status'] != 'OK') throw Exception(data['status']);

      final route = data['routes'][0];
      final leg   = (route['legs'] as List).first;
      final dist  = (leg['distance']['value'] as num).toDouble();
      final dur   = (leg['duration']['value']  as num).toInt();

      // decode polyline
      final points = _decodePolyline(route['overview_polyline']['points'] as String);

      // bounds
      final b  = route['bounds'];
      final ne = b['northeast'];
      final sw = b['southwest'];
      final bounds = LatLngBounds(
        southwest: LatLng(sw['lat'], sw['lng']),
        northeast: LatLng(ne['lat'], ne['lng']),
      );

      if (!mounted) return;
      setState(() {
        _summaries[mode]!
          ..durationSeconds = dur
          ..distanceMeters  = dist
          ..loading         = false;
      });

      // 存 polyline（只保存，不一定绘制）
      _modePolylines[mode]  = points;
      _modeBounds[mode]     = bounds;

      if (mode == TravelMode.drive) {
        _modePolylines[TravelMode.motor] = points;
        _modeBounds[TravelMode.motor]    = bounds;
        setState(() {
          _summaries[TravelMode.motor]!
            ..durationSeconds = dur
            ..distanceMeters  = dist
            ..loading         = false;
        });
      }

      // 如果是当前选中 mode，立即渲染
      if (mode == _selectedMode) {
        _renderPolyline(mode);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _summaries[mode]!
          ..loading = false
          ..error   = e.toString();
      });
    }
  }

  // 存各 mode 的路线数据
  final Map<TravelMode, List<LatLng>>   _modePolylines = {};
  final Map<TravelMode, LatLngBounds?>  _modeBounds    = {};

  void _renderPolyline(TravelMode mode) {
    final points = _modePolylines[mode];
    final bounds = _modeBounds[mode];
    if (points == null) return;

    setState(() {
      _currentPolyline = points;
      _currentBounds   = bounds;
      _polylines
        ..clear()
        ..add(Polyline(
          polylineId: const PolylineId('route'),
          points:    points,
          color:     const Color(0xFF4A90D9),
          width:     5,
          startCap:  Cap.roundCap,
          endCap:    Cap.roundCap,
          jointType: JointType.round,
        ));
    });

    if (bounds != null) {
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
    }
  }

  void _selectMode(TravelMode mode) {
    if (_selectedMode == mode) return;
    setState(() => _selectedMode = mode);
    _renderPolyline(mode);
  }

  // ─────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> pts = [];
    int i = 0, len = encoded.length, lat = 0, lng = 0;
    while (i < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      shift = 0; result = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      pts.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return pts;
  }

  String _fmtDur(int sec) {
    if (sec <= 0) return '--';
    final m = sec ~/ 60;
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}m';
  }

  String _fmtDist(double m) {
    if (m <= 0) return '--';
    if (m < 1000) return '${m.round()} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final selected = _summaries[_selectedMode]!;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [

        // ── Map ──
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: LatLng(
              (widget.startLat + widget.endLat) / 2,
              (widget.startLng + widget.endLng) / 2,
            ),
            zoom: 13,
          ),
          markers:                 _markers,
          polylines:               _polylines,
          myLocationEnabled:       false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled:     false,
          compassEnabled:          true,
          onMapCreated: (c) {
            _mapController = c;
            // 等 polyline 拉完再 fit
          },
          padding: const EdgeInsets.only(bottom: 220),
        ),

        // ── Top bar ──
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            color: Colors.white,
            padding: EdgeInsets.fromLTRB(
                8, MediaQuery.of(context).padding.top + 15, 16, 20),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 12), 
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 10, height: 20,
                      decoration: const BoxDecoration(
                        color: Color(0xFF1A73E8), shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Your location',
                        style: TextStyle(fontSize: 16, color: Color(0xFF1A73E8),
                            fontWeight: FontWeight.w500)),
                  ]),
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: SizedBox(
                      height: 18,
                      child: VerticalDivider(color: Colors.grey, width: 10, thickness: 1.5),
                    ),
                  ),
                  Row(children: [
                    const Icon(Icons.location_on_rounded, color: Colors.red, size: 14),
                    const SizedBox(width: 4),
                    Expanded(child: Text(
                      widget.destinationName ?? 'Destination',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    )),
                  ]),
                ],
              )),
              const SizedBox(width: 8),
              const Icon(Icons.swap_vert_rounded, color: Colors.grey),
            ]),
          ),
        ),

        // ── Bottom sheet ──
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [BoxShadow(
                color: Color(0x1A000000),
                blurRadius: 20,
                offset: Offset(0, -4),
              )],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [

                // ── Mode tabs ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(children: [
                    _modeTab(TravelMode.drive, Icons.directions_car_rounded),
                    const SizedBox(width: 8),
                    _modeTab(TravelMode.motor, Icons.two_wheeler_rounded),
                    const SizedBox(width: 8),
                    _modeTab(TravelMode.walk,  Icons.directions_walk_rounded),
                  ]),
                ),

                // ── Divider ──
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Divider(height: 1),
                ),

                // ── Duration + Distance + arrival ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (selected.loading)
                        const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (selected.error != null)
                        const Text('Route unavailable',
                            style: TextStyle(color: Colors.red, fontSize: 15))
                      else ...[
                        Text(_fmtDur(selected.durationSeconds),
                            style: const TextStyle(
                                fontSize: 28, fontWeight: FontWeight.bold,
                                color: Colors.black87)),
                        const SizedBox(width: 10),
                        Text(_fmtDist(selected.distanceMeters),
                            style: TextStyle(
                                fontSize: 15, color: Colors.grey[600])),
                        const Spacer(),
                        Text(
                          'Arrive ${_arrivalTime(selected.durationSeconds)} · Fastest route',
                          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // ── Start button ──
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      16, 0, 16, 16 + MediaQuery.of(context).padding.bottom),
                  child: Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: selected.loading || selected.error != null
                            ? null
                            : () {
                                Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => GuidePage(
                                      startLat:        widget.startLat,
                                      startLng:        widget.startLng,
                                      endLat:          widget.endLat,
                                      endLng:          widget.endLng,
                                      destinationName: widget.destinationName,
                                      travelMode:      _selectedMode, // ← 传入选中 mode
                                    ),
                                  ),
                                );
                              },
                        icon:  const Icon(Icons.navigation_rounded, size: 18),
                        label: const Text('Start',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A73E8),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  // ── Mode tab widget ──
  Widget _modeTab(TravelMode mode, IconData icon) {
    final summary    = _summaries[mode]!;
    final isSelected = _selectedMode == mode;

    return Expanded(
      child: GestureDetector(
        onTap: () => _selectMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF1A73E8).withOpacity(0.1)
                : Colors.grey[100],
            borderRadius: BorderRadius.circular(12),
            border: isSelected
                ? Border.all(color: const Color(0xFF1A73E8), width: 1.5)
                : Border.all(color: Colors.transparent),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 22,
                  color: isSelected ? const Color(0xFF1A73E8) : Colors.grey[600]),
              const SizedBox(height: 4),
              if (summary.loading)
                SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: isSelected ? const Color(0xFF1A73E8) : Colors.grey,
                  ),
                )
              else if (summary.error != null)
                Text('N/A',
                    style: TextStyle(
                        fontSize: 11,
                        color: isSelected ? const Color(0xFF1A73E8) : Colors.grey))
              else
                Text(_fmtDur(summary.durationSeconds),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? const Color(0xFF1A73E8) : Colors.grey[700])),
            ],
          ),
        ),
      ),
    );
  }

  String _arrivalTime(int durationSeconds) {
    final now     = DateTime.now();
    final arrival = now.add(Duration(seconds: durationSeconds));
    final h       = arrival.hour;
    final m       = arrival.minute.toString().padLeft(2, '0');
    final period  = h >= 12 ? 'PM' : 'AM';
    final h12     = h % 12 == 0 ? 12 : h % 12;
    return '$h12:$m$period';
  }
}