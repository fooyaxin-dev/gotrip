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

  // FIX: 用固定 Timer 重置 _isProgrammaticMove，不再依赖
  // animateCamera() 的 Future 完成时机（Future 可能因为动画被
  // 下一次调用打断而提前 resolve，导致标志位过早复位，把系统
  // 触发的相机移动误判成用户手动拖动）。
  Timer? _programmaticMoveResetTimer;
  static const int _programmaticMoveResetMs = 350;

  // FIX: 目的地 marker 不会变，初始化时建一次就够了，不用每次
  // 重建地图都重新 new 一个 Marker 对象。
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

    // Wire arrived callback
    _nav.onArrived = _showArrivedDialog;

    // Initialise (loads route + starts GPS + compass)
    _nav.init(this);

    // FIX: 低频状态变化（换 step、ETA、reroute、TTS 开关等）走这个，
    // 只在真正需要重建 banner/ETA 面板/进度条等 UI 时才触发。
    _nav.addListener(_onNavUpdate);

    // FIX: 高频位置插值单独监听，只负责驱动相机跟随，不触发 setState()。
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

  // ─────────────────────────────────────────────
  // Nav update handlers
  // ─────────────────────────────────────────────

  // 低频：真正的导航状态变化才会走到这里（换 step / ETA / reroute / TTS）。
  void _onNavUpdate() {
    if (!mounted) return;
    setState(() {}); // 重建 banner / ETA 面板 / 进度条这些低频 UI
  }

  // 高频：每次箭头位置插值都会走到这里，只负责相机跟随，
  // 不调用 setState()，不会波及整页。
  void _onPositionTick() {
    if (_isFollowing && !_isOverview) {
      final pos = _nav.positionNotifier.value;
      if (pos != null) _moveCamera(pos);
    }
  }

  // ─────────────────────────────────────────────
  // Camera
  // ─────────────────────────────────────────────

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

    // FIX: 固定延迟重置，覆盖动画实际时长，不依赖 Future 完成时机。
    _programmaticMoveResetTimer = Timer(
      const Duration(milliseconds: _programmaticMoveResetMs),
      () => _isProgrammaticMove = false,
    );
  }

  double _zoomForSpeed(double mps) {
    if (mps >= 25) return 16.0;
    if (mps >= 14) return 17.0;
    if (mps >= 8)  return 18.0;
    if (mps >= 1)  return 19.0;
    return 19.5;
  }

  void _recenter() {
    setState(() { _isFollowing = true; _isOverview = false; });
    final pos = _nav.positionNotifier.value;
    if (pos != null) _moveCamera(pos);
  }

  Future<void> _toggleOverview() async {
    if (_nav.routeBounds == null) return;
    setState(() {
      _isOverview  = !_isOverview;
      _isFollowing = !_isOverview;
    });
    if (_isOverview) {
      _programmaticMoveResetTimer?.cancel();
      _isProgrammaticMove = true;
      await _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(_nav.routeBounds!, 80),
      );
      _isProgrammaticMove = false;
    } else {
      _recenter();
    }
  }

  // ─────────────────────────────────────────────
  // Build markers + polylines from controller
  // ─────────────────────────────────────────────

  // FIX: 接收当前位置作为参数，只在地图子树内被调用，
  // 不再依赖整页 setState() 才能拿到最新位置。
  Set<Marker> _buildMarkers(LatLng? pos) {
    final markers = <Marker>{};

    if (_destinationMarker != null) markers.add(_destinationMarker!);

    if (pos != null) {
      markers.add(Marker(
        markerId: const MarkerId('me'),
        position: pos,
        icon: _nav.arrowIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        rotation: _nav.cameraBearing,   // 原来写死 0，改成跟相机同源
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

  // ─────────────────────────────────────────────
  // Arrived dialog
  // ─────────────────────────────────────────────

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
              Navigator.pop(context); // close dialog
              Navigator.pop(context, true); // back to caller
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

  // ─────────────────────────────────────────────
  // Maneuver icon
  // ─────────────────────────────────────────────

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

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {

    // ── Loading ──
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

    // ── Error ──
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

    final mq      = MediaQuery.of(context);
    final step    = _nav.currentStep;
    final nextStep = _nav.nextStep;
    final svc     = RouteService.instance;

    final bannerH = mq.padding.top + (nextStep != null ? 130.0 : 98.0);
    const panelH  = 90.0;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [

          // ── Google Map ──
          // FIX: 只有这一块包在 ValueListenableBuilder 里监听高频的
          // positionNotifier。箭头每次插值只重建这个小组件，banner、
          // ETA 面板、进度条、按钮这些都在外层 Stack，不会被牵连重建。
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
                polylines:              _buildPolylines(),
                circles:                _buildCircles(pos),
                myLocationEnabled:      false,
                myLocationButtonEnabled: false,
                zoomControlsEnabled:    false,
                compassEnabled:         false,
                buildingsEnabled:       false,
                onMapCreated: (c) {
                  _mapController = c;
                  // Initial camera move after map is ready
                  Future.delayed(const Duration(milliseconds: 400), () {
                    final p = _nav.positionNotifier.value;
                    if (p != null) _moveCamera(p);
                  });
                },
                onCameraMoveStarted: () {
                  // 只要不是我们自己代码触发的移动（_isProgrammaticMove），
                  // 就认定是用户手指主动拖动/缩放/旋转，立刻退出跟随模式。
                  if (!_isProgrammaticMove) {
                    setState(() => _isFollowing = false);
                  }
                },
                padding: EdgeInsets.only(
                  top:    bannerH,
                  bottom: panelH + mq.padding.bottom,
                ),
              );
            },
          ),

          // ── Turn-by-turn banner ──
          if (step != null)
            Positioned(
              top: 0, left: 0, right: 0,
              child: Column(
                children: [
                  // Current step
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
                  // Next step preview
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

          // ── Progress bar (thin strip below banner) ──
          if (!_nav.loading && step != null)
            Positioned(
              top: bannerH,
              left: 0, right: 0,
              child: LinearProgressIndicator(
                value: _nav.progress,
                minHeight: 3,
                backgroundColor: Colors.grey[200],
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF1A73E8)),
              ),
            ),

          // ── Right side buttons ──
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
                
                // Overview toggle
                _circleBtn(
                  _isOverview
                      ? Icons.navigation_rounded
                      : Icons.map_rounded,
                  _isOverview ? const Color(0xFF1A73E8) : Colors.white,
                  _isOverview ? Colors.white : Colors.black87,
                  _toggleOverview,
                ),
                
                const SizedBox(height: 12),
                
                // ── TTS toggle ──
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

          // ── Bottom ETA panel ──
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

                      // ── 速度显示 ──
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

          // ── Rerouting banner ──
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

  // ─────────────────────────────────────────────
  // Helper widgets
  // ─────────────────────────────────────────────

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