import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../services/route_service.dart';
import 'guidePage.dart';
import '../../services/apps_Loading.dart';

// ─────────────────────────────────────────────────────────
// Per-mode summary state
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
  final String? startLocationName;

  const RoutePreviewPage({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
    this.startLocationName,
  });

  @override
  State<RoutePreviewPage> createState() => _RoutePreviewPageState();
}

class _RoutePreviewPageState extends State<RoutePreviewPage> {

  final _svc = RouteService.instance;

  GoogleMapController? _mapController;
  final Set<Polyline>  _polylines = {};
  final Set<Marker>    _markers   = {};

  TravelMode _selectedMode = TravelMode.drive;

  final Map<TravelMode, _ModeSummary> _summaries = {
    TravelMode.drive: _ModeSummary(mode: TravelMode.drive),
    TravelMode.motor: _ModeSummary(mode: TravelMode.motor),
    TravelMode.walk:  _ModeSummary(mode: TravelMode.walk),
  };

  final Map<TravelMode, RouteSummary?> _routeData = {
    TravelMode.drive: null,
    TravelMode.motor: null,
    TravelMode.walk:  null,
  };

  bool _trafficEnabled = false;

  // Track top bar height so map padding stays accurate
  double _topBarHeight = 0;
  final GlobalKey _topBarKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _setMarkers();
    _fetchMode(TravelMode.drive);
    _fetchMode(TravelMode.walk);

    // Measure the top bar after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateTopBarHeight());
  }

  void _updateTopBarHeight() {
    final box = _topBarKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      setState(() => _topBarHeight = box.size.height);
    }
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  // ── Markers ──

  void _setMarkers() {
    _markers.addAll([
      Marker(
        markerId:  const MarkerId('end'),
        position:  LatLng(widget.endLat, widget.endLng),
        icon:      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
      ),
      Marker(
        markerId:  const MarkerId('start'),
        position:  LatLng(widget.startLat, widget.startLng),
        icon:      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'Your location'),
      ),
    ]);
  }

  // ── Fetch ──
  Future<void> _fetchMode(TravelMode mode) async {
    try {
      final summary = await _svc.fetchRouteSummary(
        fromLat: widget.startLat, fromLng: widget.startLng,
        toLat:   widget.endLat,   toLng:   widget.endLng,
        mode:    mode,
      );

      if (!mounted) return;

      setState(() {
        _summaries[mode]!
          ..durationSeconds = summary.durationSeconds
          ..distanceMeters  = summary.distanceMeters
          ..loading         = false;
        _routeData[mode] = summary;

        // Motor reuses drive result
        if (mode == TravelMode.drive) {
          _summaries[TravelMode.motor]!
            ..durationSeconds = summary.durationSeconds
            ..distanceMeters  = summary.distanceMeters
            ..loading         = false;
            _routeData[TravelMode.motor] = summary;
        }
      });

      if (mode == _selectedMode) _renderPolyline(mode);

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _summaries[mode]!
          ..loading = false
          ..error   = e.toString();
        if (mode == TravelMode.drive) {
          _summaries[TravelMode.motor]!
            ..loading = false
            ..error   = e.toString();
        }
      });
    }
  }

  // ── Render polyline for selected mode ──
  void _renderPolyline(TravelMode mode) {
    final data = _routeData[mode];
    if (data == null) return;

    setState(() {
      _polylines
        ..clear()
        ..add(Polyline(
          polylineId: const PolylineId('route'),
          points:    data.polylinePoints,
          color:     const Color(0xFF1A73E8),
          width:     5,
          startCap:  Cap.roundCap, endCap: Cap.roundCap,
          jointType: JointType.round,
        ));
    });

    // Add a small extra inset so the route isn't hidden behind panels
    final topInset    = (_topBarHeight > 0 ? _topBarHeight : 100) + 16;
    const bottomInset = 240.0; // bottom sheet height + buffer

    _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(
        data.bounds,
        [topInset, 60, bottomInset, 60].reduce((a, b) => a > b ? a : b) / 1, // use max as fallback
      ),
    );

    // Prefer per-side padding for accurate framing
    _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(data.bounds, 60),
    );
  }

  void _selectMode(TravelMode mode) {
    if (_selectedMode == mode) return;
    setState(() => _selectedMode = mode);
    _renderPolyline(mode);
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final selected = _summaries[_selectedMode]!;
    final mq       = MediaQuery.of(context);

    // Estimated top bar height = status bar + 15 top padding + ~80 content + 20 bottom padding
    const double kTopBarContent = 115.0;
    final double topPad = mq.padding.top + kTopBarContent;

    // Estimated bottom sheet height
    const double kBottomSheetHeight = 240.0;
    final double bottomPad = kBottomSheetHeight + mq.padding.bottom;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [

        // ── Map — padding accounts for both overlapping panels ──
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
          trafficEnabled:          _trafficEnabled,
          onMapCreated: (c) => _mapController = c,
          // ✅ Key fix: pad top AND bottom so route fits in the visible gap
          padding: EdgeInsets.only(
            top:    topPad,
            bottom: bottomPad,
          ),
        ),

        // ── Top bar ──
        Positioned(
          key: _topBarKey,
          top: 0, left: 0, right: 0,
          child: Container(
            color: Colors.white,
            padding: EdgeInsets.fromLTRB(
                8, mq.padding.top + 15, 16, 20),
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
                      width: 10, height: 10,
                      decoration: const BoxDecoration(
                          color: Color(0xFF1A73E8),
                          shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.startLocationName ?? 'Your location',
                      style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF1A73E8),
                          fontWeight: FontWeight.w500),
                    ),
                  ]),
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: SizedBox(
                      height: 18,
                      child: VerticalDivider(
                          color: Colors.grey, width: 10, thickness: 1.5),
                    ),
                  ),
                  Row(children: [
                    const Icon(Icons.location_on_rounded,
                        color: Colors.red, size: 14),
                    const SizedBox(width: 4),
                    Expanded(child: Text(
                      widget.destinationName ?? 'Destination',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    )),
                  ]),
                ],
              )),
              const SizedBox(width: 8),
              if (!selected.loading && selected.error == null)
                Text(
                  'Arrive ${_svc.formatArrivalTime(selected.durationSeconds)}',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w500),
                ),
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
                blurRadius: 20, offset: Offset(0, -4),
              )],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [

                // Mode tabs
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

                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Divider(height: 1),
                ),

                // Duration + distance + traffic toggle
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (selected.loading)
                        const SizedBox(
                          width: 20, height: 20,
                          child: TravelLoadingIndicator(),
                        )
                      else if (selected.error != null)
                        const Text('Route unavailable',
                            style: TextStyle(color: Colors.red, fontSize: 15))
                      else ...[
                        Text(_svc.formatDuration(selected.durationSeconds),
                            style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87)),
                        const SizedBox(width: 10),
                        Text(_svc.formatDistance(selected.distanceMeters),
                            style: TextStyle(
                                fontSize: 15, color: Colors.grey[600])),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => setState(
                              () => _trafficEnabled = !_trafficEnabled),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: _trafficEnabled
                                  ? const Color(0xFF1A73E8).withOpacity(0.1)
                                  : Colors.grey[100],
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _trafficEnabled
                                    ? const Color(0xFF1A73E8)
                                    : Colors.grey[300]!,
                              ),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.traffic_rounded,
                                  size: 14,
                                  color: _trafficEnabled
                                      ? const Color(0xFF1A73E8)
                                      : Colors.grey[600]),
                              const SizedBox(width: 4),
                              Text('Traffic',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: _trafficEnabled
                                          ? const Color(0xFF1A73E8)
                                          : Colors.grey[600])),
                            ]),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // Start button
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      16, 0, 16, 16 + mq.padding.bottom),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: selected.loading || selected.error != null
                          ? null
                          : () => Navigator.pushReplacement(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => GuidePage(
                                    startLat:        widget.startLat,
                                    startLng:        widget.startLng,
                                    endLat:          widget.endLat,
                                    endLng:          widget.endLng,
                                    destinationName: widget.destinationName,
                                    travelMode:      _selectedMode,
                                  ),
                                ),
                              ),
                      icon:  const Icon(Icons.navigation_rounded, size: 18),
                      label: const Text('Start',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1A73E8),
                        foregroundColor: Colors.white,
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30)),
                        elevation: 0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }

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
                  color: isSelected
                      ? const Color(0xFF1A73E8) : Colors.grey[600]),
              const SizedBox(height: 4),
              if (summary.loading)
                const SizedBox(
                  width: 14, height: 14,
                  child: TravelLoadingIndicator(),
                )
              else if (summary.error != null)
                Text('N/A',
                    style: TextStyle(
                        fontSize: 11,
                        color: isSelected
                            ? const Color(0xFF1A73E8) : Colors.grey))
              else
                Text(_svc.formatDuration(summary.durationSeconds),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected
                            ? FontWeight.bold : FontWeight.normal,
                        color: isSelected
                            ? const Color(0xFF1A73E8) : Colors.grey[700])),
            ],
          ),
        ),
      ),
    );
  }
}