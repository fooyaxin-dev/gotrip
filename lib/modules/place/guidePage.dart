import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import '../../services/route_service.dart';
import 'navigateController.dart';

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

class _GuidePageState extends State<GuidePage> with TickerProviderStateMixin {

  late final NavigationController _nav;

  // ── Map ──
  GoogleMapController? _mapController;
  final Set<Marker>   _markers   = {};
  final Set<Polyline> _polylines = {};

  // ── Camera ──
  bool     _isFollowing        = true;
  bool     _isOverview         = false;
  bool     _isProgrammaticMove = false;
  bool     _isUserInteracting  = false;
  DateTime _lastCameraMove     = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProgMove       = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _ignoreCameraUntil  = DateTime.fromMillisecondsSinceEpoch(0);
  double?  _manualZoom;

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _nav = NavigationController(
      startLat:        widget.startLat,
      startLng:        widget.startLng,
      endLat:          widget.endLat,
      endLng:          widget.endLng,
      destinationName: widget.destinationName,
      travelMode:      widget.travelMode,
    );
    _nav.onArrived = _showArrivedDialog;
    _nav.addListener(_onNavUpdate);
    _nav.init(this);
  }

  @override
  void dispose() {
    _nav.removeListener(_onNavUpdate);
    _nav.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Controller listener — rebuild map overlays + camera
  // ─────────────────────────────────────────────

  void _onNavUpdate() {
    if (!mounted) return;
    setState(() {
      _rebuildPolylines();
      _placeArrow();
      _placeDestinationMarker();
    });
    if (_isFollowing && !_isOverview && !_isUserInteracting && !_nav.loading) {
      _moveCamera();
    }
  }

  // ─────────────────────────────────────────────
  // Map overlays
  // ─────────────────────────────────────────────

  void _placeDestinationMarker() {
    _markers
      ..removeWhere((m) => m.markerId.value == 'destination')
      ..add(Marker(
        markerId:   const MarkerId('destination'),
        position:   LatLng(widget.endLat, widget.endLng),
        icon:       BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
      ));
  }

  void _placeArrow() {
    final pos = _nav.displayLatLng ?? _nav.userLatLng;
    if (pos == null) return;
    _markers
      ..removeWhere((m) => m.markerId.value == 'me')
      ..add(Marker(
        markerId: const MarkerId('me'),
        position: pos,
        icon:     _nav.arrowIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        // FIX 7: rotate arrow marker to match current bearing
        rotation: _nav.bearing,
        anchor:   const Offset(0.5, 0.5),
        flat:     true,
        zIndex:   10,
      ));
  }

  void _rebuildPolylines() {
    _polylines.clear();
    if (_nav.polylinePoints.length >= 2) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('routeShadow'),
        points:    _nav.polylinePoints,
        color:     Colors.black.withOpacity(0.16),
        width:     13,
        startCap:  Cap.roundCap, endCap: Cap.roundCap,
        jointType: JointType.round, zIndex: 0,
      ));
    }
    if (_nav.walkedPoints.length >= 2) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('walked'),
        points:    _nav.walkedPoints,
        color:     const Color(0xFF9AA4B2),
        width:     9,
        startCap:  Cap.roundCap, endCap: Cap.buttCap,
        jointType: JointType.round, zIndex: 1,
      ));
    }
    if (_nav.remainingPoints.length >= 2) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('remaining'),
        points:    _nav.remainingPoints,
        color:     const Color(0xFF1565D8),
        width:     9,
        startCap:  Cap.roundCap, endCap: Cap.roundCap,
        jointType: JointType.round, zIndex: 2,
      ));
      _polylines.add(Polyline(
        polylineId: const PolylineId('remainingGlow'),
        points:    _nav.remainingPoints,
        color:     const Color(0xFF7CC7FF),
        width:     4,
        startCap:  Cap.roundCap, endCap: Cap.roundCap,
        jointType: JointType.round, zIndex: 3,
      ));
    }
  }

  // ─────────────────────────────────────────────
  // Camera
  // ─────────────────────────────────────────────

  double _zoomForSpeed(double mps) {
    if (widget.travelMode == TravelMode.walk) {
      if (mps >= 2.2) return 18.8;
      if (mps >= 1.2) return 19.2;
      return 19.6;
    }
    if (mps >= 25) return 16.0;
    if (mps >= 14) return 16.8;
    if (mps >= 8)  return 17.6;
    if (mps >= 3)  return 18.4;
    return 19.0;
  }

  double _tiltForState() {
    if (_isOverview || widget.travelMode == TravelMode.walk) return 0;
    final speed = _nav.lastPos?.speed ?? 0;
    if (speed < 1.2) return 0;
    if (_nav.distToTurnEnd < 70) return 42;
    if (speed >= 16) return 64;
    if (speed >= 8)  return 56;
    return 48;
  }

  double _effectiveZoom() =>
      _manualZoom ?? _zoomForSpeed(_nav.lastPos?.speed ?? 0);

  void _moveCamera() {
    final target = _nav.displayLatLng ?? _nav.userLatLng;
    if (_mapController == null || target == null) return;
    final now = DateTime.now();
    // FIX 5: relax throttle to 160ms (matches ~200ms GPS interval better)
    if (now.difference(_lastCameraMove).inMilliseconds < 160) return;
    _lastCameraMove = now;

    _isProgrammaticMove = true;
    _lastProgMove       = now;
    _ignoreCameraUntil  = now.add(const Duration(milliseconds: 450));

    _mapController!.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
      target:  target,
      zoom:    _effectiveZoom(),
      tilt:    _tiltForState(),
      bearing: _nav.cameraBearing,
    )));

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _isProgrammaticMove = false;
    });
  }

  void _recenter() {
    setState(() {
      _isFollowing = true;
      _isOverview  = false;
      _manualZoom  = null;
    });
    _moveCamera();
  }

  Future<void> _toggleOverview() async {
    if (_nav.routeBounds == null) return;
    setState(() {
      _isOverview  = !_isOverview;
      _isFollowing = !_isOverview;
    });
    if (_isOverview) {
      _isProgrammaticMove = true;
      await _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(_nav.routeBounds!, 80));
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
          Text('You have arrived!', style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        content: Text(widget.destinationName != null
            ? 'You have reached ${widget.destinationName}.'
            : 'You have reached your destination.'),
        actions: [ElevatedButton(
          onPressed: () { Navigator.pop(context); Navigator.pop(context); },
          style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: const Text('Done'),
        )],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Format helpers
  // ─────────────────────────────────────────────

  String _fmtDuration(int s) {
    if (s < 60) return '$s sec';
    final m = s ~/ 60;
    if (m < 60) return '$m min';
    final h = m ~/ 60; final r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}min';
  }

  String _fmtDist(double m) =>
      m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  String _fmtSpeed(double mps) => '${max(0, (mps * 3.6).round())} km/h';

  // FIX 8: use intl DateFormat for correct AM/PM formatting
  String _fmtArrival(int s) {
    final arrival = DateTime.now().add(Duration(seconds: s));
    return DateFormat('h:mm a').format(arrival);
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
    if (_nav.loading) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_nav.isRerouting ? 'Recalculating...' : 'Calculating route...',
                style: const TextStyle(fontSize: 16, color: Colors.grey)),
          ],
        )),
      );
    }

    if (_nav.error != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 56),
            const SizedBox(height: 16),
            Text(_nav.error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: Colors.black54)),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: () => Navigator.pop(context),
                child: const Text('Go back')),
          ],
        )),
      );
    }

    final mq      = MediaQuery.of(context);
    final step    = _nav.currentStep;
    final next    = _nav.nextStep;
    final bannerH = mq.padding.top + (next != null ? 148.0 : 112.0);
    final panelH  = widget.destinationName != null ? 132.0 : 116.0;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(children: [

        // ── Map ──
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target:  _nav.userLatLng ?? LatLng(widget.startLat, widget.startLng),
            zoom:    19, tilt: 0,
            bearing: _nav.bearing,
          ),
          markers:                 _markers,
          polylines:               _polylines,
          myLocationEnabled:       false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled:     false,
          zoomGesturesEnabled:     true,
          scrollGesturesEnabled:   true,
          rotateGesturesEnabled:   false,
          tiltGesturesEnabled:     false,
          compassEnabled:          false,
          trafficEnabled:          widget.travelMode != TravelMode.walk,
          buildingsEnabled:        widget.travelMode != TravelMode.walk,
          onMapCreated: (c) {
            _mapController = c;
            Future.delayed(const Duration(milliseconds: 300), _moveCamera);
          },
          onCameraMoveStarted: () => _isUserInteracting = true,
          onCameraMove: (pos) {
            final shouldIgnore = _isProgrammaticMove ||
                DateTime.now().difference(_lastProgMove) < const Duration(milliseconds: 700) ||
                DateTime.now().isBefore(_ignoreCameraUntil);
            if (shouldIgnore) return;

            final currentTarget = _nav.displayLatLng ?? _nav.userLatLng;
            final targetShift   = currentTarget == null
                ? double.infinity
                : Geolocator.distanceBetween(
                    pos.target.latitude, pos.target.longitude,
                    currentTarget.latitude, currentTarget.longitude);
            final autoZoom = _zoomForSpeed(_nav.lastPos?.speed ?? 0);
            final zoomDiff = (pos.zoom - autoZoom).abs();

            if (targetShift < 20) {
              if (zoomDiff > 0.05) {
                setState(() { _isFollowing = true; _manualZoom = pos.zoom; });
              }
              return;
            }
            if (_isFollowing) setState(() => _isFollowing = false);
          },
          onCameraIdle: () => _isUserInteracting = false,
          padding: EdgeInsets.only(
            top:    bannerH,
            bottom: panelH + mq.padding.bottom,
          ),
        ),

        // ── Gradient overlay ──
        IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.14),
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withOpacity(0.08),
                ],
                stops: const [0.0, 0.18, 0.72, 1.0],
              ),
            ),
          ),
        ),

        // ── Turn banner ──
        if (step != null)
          Positioned(
            top: 0, left: 12, right: 12,
            child: Column(children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1157C8),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 18, offset: const Offset(0, 8),
                  )],
                ),
                padding: EdgeInsets.fromLTRB(
                    20, mq.padding.top + 12, 20, next != null ? 10 : 16),
                child: Row(children: [
                  Container(
                    width: 58, height: 58,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.16),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(_maneuverIcon(step.maneuver), color: Colors.white, size: 34),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_fmtDist(_nav.distToTurnEnd),
                          style: const TextStyle(color: Colors.white,
                              fontSize: 30, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(step.instruction,
                          style: const TextStyle(color: Colors.white,
                              fontSize: 15, fontWeight: FontWeight.w600),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  )),
                ]),
              ),
              if (next != null)
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.96),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 12, offset: const Offset(0, 4),
                    )],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(children: [
                    const Text('Then  ',
                        style: TextStyle(color: Color(0xFF6B7280),
                            fontSize: 12, fontWeight: FontWeight.w700)),
                    Icon(_maneuverIcon(next.maneuver),
                        color: const Color(0xFF1157C8), size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(next.instruction,
                        style: const TextStyle(color: Color(0xFF1F2937),
                            fontSize: 12, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ]),
          ),

        // ── ETA + distance chips ──
        Positioned(
          top: bannerH + 8, left: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _floatingStat(Icons.schedule_rounded,
                  'ETA ${_fmtArrival(_nav.remainingSeconds)}'),
              const SizedBox(height: 8),
              _floatingStat(Icons.route_rounded,
                  _fmtDist(_nav.remainingMeters)),
            ],
          ),
        ),

        // ── Right buttons ──
        Positioned(
          right: 16,
          bottom: panelH + mq.padding.bottom + 16,
          child: Column(children: [
            if ((_nav.lastPos?.speed ?? 0) > 0.3) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 10, offset: const Offset(0, 4),
                  )],
                ),
                child: Text(_fmtSpeed(_nav.lastPos?.speed ?? 0),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2937))),
              ),
              const SizedBox(height: 12),
            ],
            if (!_isFollowing) ...[
              _circleBtn(Icons.my_location_rounded, Colors.white,
                  const Color(0xFF1157C8), _recenter),
              const SizedBox(height: 12),
            ],
            _circleBtn(
              _isOverview ? Icons.navigation_rounded : Icons.map_rounded,
              _isOverview ? const Color(0xFF1157C8) : Colors.white,
              _isOverview ? Colors.white : Colors.black87,
              _toggleOverview,
            ),
          ]),
        ),

        // ── Bottom panel ──
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(24, 14, 24, 14 + mq.padding.bottom),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.10),
                blurRadius: 20, offset: const Offset(0, -6),
              )],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42, height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD7DEE7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(_fmtDuration(_nav.remainingSeconds),
                              style: const TextStyle(fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF111827))),
                          const SizedBox(width: 8),
                          Text(_fmtDist(_nav.remainingMeters),
                              style: const TextStyle(fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF6B7280))),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Arrive by ${_fmtArrival(_nav.remainingSeconds)}',
                          style: const TextStyle(fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF4B5563))),
                      if (widget.destinationName != null)
                        Row(children: [
                          Icon(Icons.location_on_rounded,
                              size: 14, color: Colors.red[400]),
                          const SizedBox(width: 4),
                          Expanded(child: Text(widget.destinationName!,
                              style: const TextStyle(fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF6B7280)),
                              overflow: TextOverflow.ellipsis)),
                        ]),
                    ],
                  )),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 13),
                      side: BorderSide(color: Colors.grey[300]!),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(color: Color(0xFF1F2937),
                            fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value:           _nav.progress,
                    minHeight:       7,
                    backgroundColor: const Color(0xFFE8EEF5),
                    valueColor:      const AlwaysStoppedAnimation(Color(0xFF1157C8)),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Off-route banner ──
        if (_nav.isRerouting)
          Positioned(
            top: bannerH + 8, left: 20, right: 20,
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
                    style: TextStyle(color: Colors.white,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // Widget helpers
  // ─────────────────────────────────────────────

  Widget _floatingStat(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(0.10),
          blurRadius: 10, offset: const Offset(0, 4),
        )],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF1157C8)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: Color(0xFF1F2937))),
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, Color bg, Color fg, VoidCallback onTap) {
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