import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../services/route_service.dart';
import '../../services/navigate_service.dart';
import '../../services/apps_Loading.dart';

class GuidePage extends StatefulWidget { 
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName;
  final TravelMode travelMode;
  final RouteResult? initialRoute;
    

  const GuidePage({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
    this.travelMode = TravelMode.drive,
    this.initialRoute,  
  });

  @override
  State<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends State<GuidePage> with TickerProviderStateMixin {

  late NavigationController _nav;

  GoogleMapController? _mapController;
  
 
  // Camera follow state
  bool _isFollowing = true;
  bool _isOverview  = false;
  bool _isProgrammaticMove = false;
  DateTime _lastCameraMove = DateTime.fromMillisecondsSinceEpoch(0);

  // Throttle camera updates — only move if >80ms since last move
  static const int _cameraCooldownMs = 80;

  Timer? _programmaticMoveResetTimer;
  static const int _programmaticMoveResetMs = 350;

  Marker? _destinationMarker;

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
      initialRoute:    widget.initialRoute,
    );

    _destinationMarker = Marker(
      markerId:  const MarkerId('destination'),
      position:  LatLng(widget.endLat, widget.endLng),
      icon:      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
    );

    _nav.onArrived = _showArrivedDialog;

    _nav.init(this);

    _nav.addListener(_onNavUpdate);

    _nav.positionNotifier.addListener(_onPositionTick);
  }

  @override
  void dispose() {
    _nav.removeListener(_onNavUpdate);
    _nav.positionNotifier.removeListener(_onPositionTick);
    _programmaticMoveResetTimer?.cancel();
    _nav.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  void _onNavUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  void _onPositionTick() {
    if (_isFollowing && !_isOverview) {
      final pos = _nav.positionNotifier.value;
      // SMOOTHNESS FIX: continuous per-frame following now goes through
      // _followCamera (instant moveCamera), not _moveCamera
      // (animateCamera). See _followCamera for why.
      if (pos != null) _followCamera(pos);
    }
  }

  // Throttle for the continuous follow path — moveCamera is cheap (no
  // native animation to run), so this can be tight, roughly matched to
  // display refresh rather than the old 80ms.
  static const int _followCooldownMs = 32;
  DateTime _lastFollowMove = DateTime.fromMillisecondsSinceEpoch(0);

  void _followCamera(LatLng target) {
    if (_mapController == null) return;

    final now = DateTime.now();
    if (now.difference(_lastFollowMove).inMilliseconds < _followCooldownMs) return;
    _lastFollowMove = now;

    final zoom = _zoomForSpeed(_nav.lastPos?.speed ?? 0);
    final bearing = _nav.cameraBearing;

    _isProgrammaticMove = true;
    _programmaticMoveResetTimer?.cancel();

    // SMOOTHNESS FIX: this used to call animateCamera() here, every
    // ~80ms. Each call starts the native SDK's OWN animation curve
    // (ease-in/ease-out) toward a target that had already moved again by
    // the time that animation finished — so you get a pile of short,
    // overlapping native animations constantly interrupting each other.
    // That's what looked like "跳".
    //
    // NavigationController's positionNotifier is now smoothly
    // interpolated every frame using real elapsed time (see _onTick /
    // the smooth-follow animation fields there), so the camera doesn't
    // need its own animation on top — it just needs to track that
    // already-smooth target instantly, frame by frame. moveCamera does
    // exactly that (no built-in animation, no queue to fight with).
    _mapController!.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target:  target,
          zoom:    zoom,
          tilt:    widget.travelMode == TravelMode.walk ? 0 : 45,
          bearing: bearing,
        ),
      ),
    );

    _programmaticMoveResetTimer = Timer(
      const Duration(milliseconds: _programmaticMoveResetMs),
      () => _isProgrammaticMove = false,
    );
  }

  // Kept for one-off, EXPLICIT camera transitions only (recenter tap,
  // initial camera placement) — those benefit from a real animated
  // glide since they're single, isolated calls, not a 60x/sec stream.
  void _moveCamera(LatLng target) {
    if (_mapController == null) return;

    final now = DateTime.now();
    if (now.difference(_lastCameraMove).inMilliseconds < _cameraCooldownMs) return;
    _lastCameraMove = now;

    final zoom = _zoomForSpeed(_nav.lastPos?.speed ?? 0);
    final bearing = _nav.cameraBearing;

    _isProgrammaticMove = true;
    _programmaticMoveResetTimer?.cancel();

    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target:  target,
          zoom:    zoom,
          tilt:    widget.travelMode == TravelMode.walk ? 0 : 45,
          bearing: bearing,
        ),
      ),
    );

    _programmaticMoveResetTimer = Timer(
      const Duration(milliseconds: _programmaticMoveResetMs),
      () => _isProgrammaticMove = false,
    );
  }

  double _zoomForSpeed(double mps) {
    // Piecewise-linear interpolation between speed/zoom anchor points,
    // so zoom eases continuously instead of jumping between fixed
    // levels the instant speed crosses a threshold.
    final anchors = <MapEntry<double, double>>[
      const MapEntry(0,  19.5),
      const MapEntry(1,  19.5),
      const MapEntry(8,  18.0),
      const MapEntry(14, 17.0),
      const MapEntry(25, 16.0),
    ];

    if (mps <= anchors.first.key) return anchors.first.value;
    if (mps >= anchors.last.key)  return anchors.last.value;

    for (int i = 0; i < anchors.length - 1; i++) {
      final a0 = anchors[i], a1 = anchors[i + 1];
      if (mps >= a0.key && mps <= a1.key) {
        final t = (mps - a0.key) / (a1.key - a0.key);
        return a0.value + (a1.value - a0.value) * t;
      }
    }
    return anchors.last.value;
  }

  void _recenter() {
    _programmaticMoveResetTimer?.cancel();
    _isProgrammaticMove = true;

    setState(() { _isFollowing = true; _isOverview = false; });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pos = _nav.positionNotifier.value;
      if (pos != null) _moveCamera(pos);
    });

    _programmaticMoveResetTimer = Timer(
      const Duration(milliseconds: _programmaticMoveResetMs),
      () => _isProgrammaticMove = false,
    );
  }

  Future<void> _toggleOverview() async {
    if (_nav.routeBounds == null) return;

    _programmaticMoveResetTimer?.cancel();
    _isProgrammaticMove = true;

    final goingToOverview = !_isOverview;

    if (goingToOverview) {
      setState(() {
        _isOverview  = true;
        _isFollowing = false;
      });
      await _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(_nav.routeBounds!, 80),
      );
      _isProgrammaticMove = false;
    } else {
      _recenter();
    }
  }

  Set<Marker> _buildMarkers(LatLng? pos) {
    final markers = <Marker>{};

    if (_destinationMarker != null) markers.add(_destinationMarker!);

    if (pos != null) {
      markers.add(Marker(
        markerId: const MarkerId('me'),
        position: pos,
        icon: _nav.arrowIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        rotation: _nav.cameraBearing,
        anchor:   const Offset(0.5, 0.5),
        flat:     true,
        zIndex:   10,
      ));
    }

    return markers;
  }

  Set<Polyline> _buildPolylines() {
    final polylines = <Polyline>{};

    if (_nav.walkedPoints.length >= 2) {
      polylines.add(Polyline(
        polylineId: const PolylineId('walked'),
        points:     _nav.walkedPoints,
        color:      Colors.grey.shade400,
        width:      7,
        startCap:   Cap.roundCap,
        endCap:     Cap.buttCap,
        jointType:  JointType.round,
      ));
    }

    if (_nav.remainingPoints.length >= 2) {
      polylines.add(Polyline(
        polylineId: const PolylineId('remaining'),
        points:     _nav.remainingPoints,
        color:      const Color(0xFF1A73E8),
        width:      7,
        startCap:   Cap.roundCap,
        endCap:     Cap.roundCap,
        jointType:  JointType.round,
      ));
    }

    return polylines;
  }

  Set<Circle> _buildCircles(LatLng? pos) {
    if (pos == null) return {};
    return {
      Circle(
        circleId:    const CircleId('accuracy'),
        center:      pos,
        radius:      8.0,
        fillColor:   const Color(0x221A73E8),
        strokeColor: const Color(0x441A73E8),
        strokeWidth: 1,
      ),
    };
  }

  void _showArrivedDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
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
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context, true);
            },
            style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  IconData _maneuverIcon(String m) {
    if (m.contains('uturn'))                               return Icons.u_turn_left_rounded;
    if (m.contains('slight_right'))                        return Icons.turn_slight_right_rounded;
    if (m.contains('slight_left'))                         return Icons.turn_slight_left_rounded;
    if (m.contains('turn_right') || m.contains('right'))  return Icons.turn_right_rounded;
    if (m.contains('turn_left')  || m.contains('left'))   return Icons.turn_left_rounded;
    if (m.contains('roundabout'))                          return Icons.roundabout_left_rounded;
    if (m.contains('merge'))                               return Icons.merge_rounded;
    if (m.contains('destination'))                         return Icons.location_on_rounded;
    return Icons.straight_rounded;
  }

  @override
  Widget build(BuildContext context) {


    if (_nav.loading) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const TravelLoadingIndicator(),
              const SizedBox(height: 16),
              Text(
                _nav.isRerouting ? 'Recalculating...' : 'Calculating route...',
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    if (_nav.error != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 56),
              const SizedBox(height: 16),
              Text(_nav.error!,
                  textAlign: TextAlign.center,
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

final mq       = MediaQuery.of(context);
final step     = _nav.currentStep;
final nextStep = _nav.nextStep;
final svc      = RouteService.instance;
final polylines = _buildPolylines();

final bannerH = mq.padding.top + (nextStep != null ? 130.0 : 98.0);
const panelH  = 90.0;

const double _cameraFramingRatio = 0.65;
final double availableHeight = mq.size.height - bannerH - panelH - mq.padding.bottom;
final double mapTopPadding = _isOverview
    ? bannerH
    : bannerH + availableHeight * _cameraFramingRatio;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [

          ValueListenableBuilder<LatLng?>(
            valueListenable: _nav.positionNotifier,
            builder: (context, pos, _) {
              return GoogleMap(
                initialCameraPosition: CameraPosition(
                  target:  pos ?? LatLng(widget.startLat, widget.startLng),
                  zoom:    19,
                  tilt:    widget.travelMode == TravelMode.walk ? 0 : 45,
                  bearing: _nav.cameraBearing,
                ),
                markers:                _buildMarkers(pos),
                polylines:              polylines,
                circles:                _buildCircles(pos),
                myLocationEnabled:      false,
                myLocationButtonEnabled: false,
                zoomControlsEnabled:    false,
                compassEnabled:         false,
                buildingsEnabled:       false,
                onMapCreated: (c) {
                  _mapController = c;
                  Future.delayed(const Duration(milliseconds: 400), () {
                    final p = _nav.positionNotifier.value;
                    if (p != null) _moveCamera(p);
                  });
                },
                onCameraMoveStarted: () {
                  if (!_isProgrammaticMove) {
                    setState(() => _isFollowing = false);
                  }
                },
                padding: EdgeInsets.only(
                  top:    mapTopPadding,
                  bottom: panelH + mq.padding.bottom,
                ),
              );
            },
          ),

          if (step != null)
            Positioned(
              top: 0, left: 0, right: 0,
              child: Column(
                children: [
                  Container(
                    color: Colors.black87,
                    padding: EdgeInsets.fromLTRB(
                        20, mq.padding.top + 12, 20,
                        nextStep != null ? 10 : 16),
                    child: Row(children: [
                      Icon(_maneuverIcon(step.maneuver),
                          color: Colors.white, size: 44),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              svc.formatDistance(_nav.distToTurnEnd),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold),
                            ),
                            Text(
                              step.instruction,
                              style: TextStyle(
                                  color: Colors.grey[300], fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ]),
                  ),
                  if (nextStep != null)
                    Container(
                      color: Colors.black.withOpacity(0.75),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                      child: Row(children: [
                        const Text('Then  ',
                            style: TextStyle(
                                color: Colors.grey, fontSize: 12)),
                        Icon(_maneuverIcon(nextStep.maneuver),
                            color: Colors.grey[400], size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            nextStep.instruction,
                            style: TextStyle(
                                color: Colors.grey[400], fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
            ),

          if (!_nav.loading && step != null)
            Positioned(
              top: bannerH,
              left: 0, right: 0,
              child: LinearProgressIndicator(
                value: _nav.progress,
                minHeight: 3,
                backgroundColor: Colors.grey[200],
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF9C27B0)),
              ),
            ),

          Positioned(
            right: 16,
            bottom: panelH + mq.padding.bottom + 16,
            child: 
              Column(children: [
                if (!_isFollowing) ...[
                  _circleBtn(
                    Icons.my_location_rounded,
                    Colors.white,
                    const Color(0xFF1A73E8),
                    _recenter,
                  ),
                  const SizedBox(height: 12),
                ],
                
                _circleBtn(
                  _isOverview
                      ? Icons.navigation_rounded
                      : Icons.map_rounded,
                  _isOverview ? const Color(0xFF9C27B0) : Colors.white,
                  _isOverview ? Colors.white : Colors.black87,
                  _toggleOverview,
                ),
                
                const SizedBox(height: 12),
                
                _circleBtn(
                  _nav.ttsEnabled
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  _nav.ttsEnabled ? Colors.white : Colors.grey[200]!,
                  _nav.ttsEnabled ? Colors.black87 : Colors.grey[400]!,
                  () => setState(() => _nav.toggleTts()),
                ),
              ]),
          ),

          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                  24, 14, 24, 14 + mq.padding.bottom),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.10),
                    blurRadius: 16,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: Row(children: [
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
                            svc.formatDuration(_nav.remainingSeconds),
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            svc.formatDistance(_nav.remainingMeters),
                            style: TextStyle(
                                fontSize: 14, color: Colors.grey[600]),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '· ${svc.formatArrivalTime(_nav.remainingSeconds)}',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey[500]),
                          ),
                        ],
                      ),

                      if (_nav.lastPos != null) ...[
                        const SizedBox(height: 4),
                        Row(children: [
                          Icon(Icons.speed_rounded, size: 13, color: Colors.grey[400]),
                          const SizedBox(width: 4),
                          Text(
                            '${((_nav.lastPos!.speed * 3.6).clamp(0, 200)).toStringAsFixed(0)} km/h',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                        ]),
                      ],
                      if (widget.destinationName != null)
                        Row(children: [
                          Icon(Icons.location_on_rounded,
                              size: 13, color: Colors.red[400]),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              widget.destinationName!,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey[500]),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ]),
                    ],
                  ),
                ),
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

          if (_nav.isRerouting)
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
                  Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text('Off route, recalculating...',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _circleBtn(
      IconData icon, Color bg, Color fg, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: fg, size: 24),
      ),
    );
  }
}