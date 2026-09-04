import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../../services/route_service.dart';
import '../../services/dialog_helper.dart';
import 'guidePage.dart';
import '../../services/apps_Loading.dart';

// ─────────────────────────────────────────────────────────
// Per-mode summary state
// ─────────────────────────────────────────────────────────
class _ModeSummary {
  final TravelMode mode;
  int durationSeconds = 0;
  double distanceMeters = 0;
  bool loading = false;
  String? error;
  bool isFallback = false;
  String? fallbackNotice;

  _ModeSummary({required this.mode});
}

// ─────────────────────────────────────────────────────────
// RoutePreviewPage
// ─────────────────────────────────────────────────────────
class RoutePreviewPage extends StatefulWidget {
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? destinationName;
  final String? startLocationName;
  final TravelMode? initialMode;

  const RoutePreviewPage({
    super.key,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.destinationName,
    this.startLocationName,
    this.initialMode,
  });

  /// Pure production helper to resolve fresh preview GPS origin with fallback.
  static Future<({double lat, double lng, String source, int gpsAgeMs})>
      resolvePreviewOrigin({
    required double fallbackLat,
    required double fallbackLng,
    Future<Position> Function()? locationProvider,
    DateTime? clockNow,
  }) async {
    double chosenLat = fallbackLat;
    double chosenLng = fallbackLng;
    String source = 'fallback_passed_coordinate';
    int gpsAgeMs = -1;

    try {
      final pos = locationProvider != null
          ? await locationProvider()
          : await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
            ).timeout(const Duration(seconds: 4));

      final now = clockNow ?? DateTime.now();
      final calculatedAgeMs = now.difference(pos.timestamp).inMilliseconds;
      gpsAgeMs = calculatedAgeMs;

      // Acceptance conditions for fresh_gps:
      // - latitude and longitude are finite
      // - coordinate is not (0,0)
      // - timestamp is not in the future beyond small clock tolerance (1s)
      // - GPS age is between 0 and 10 seconds (considering clock tolerance)
      // - accuracy is finite
      // - accuracy is non-negative
      // - accuracy is no greater than 60 metres
      const int clockToleranceMs = 1000;
      final bool isFuture = calculatedAgeMs < -clockToleranceMs;
      final bool isAgeValid = !isFuture && calculatedAgeMs <= 10000;
      final bool isAccuracyValid =
          pos.accuracy.isFinite && pos.accuracy >= 0.0 && pos.accuracy <= 60.0;
      final bool isCoordinateValid = pos.latitude.isFinite &&
          pos.longitude.isFinite &&
          (pos.latitude != 0.0 || pos.longitude != 0.0);

      if (isCoordinateValid && isAgeValid && isAccuracyValid) {
        chosenLat = pos.latitude;
        chosenLng = pos.longitude;
        source = 'fresh_gps';
      } else {
        chosenLat = fallbackLat;
        chosenLng = fallbackLng;
        source = 'fallback_passed_coordinate';
      }
    } catch (_) {
      chosenLat = fallbackLat;
      chosenLng = fallbackLng;
      source = 'fallback_passed_coordinate';
      gpsAgeMs = -1;
    }

    print('[NAV_ORIGIN][PREVIEW]\n'
        'source=$source\n'
        'gpsAgeMs=$gpsAgeMs\n'
        'lat=$chosenLat\n'
        'lng=$chosenLng');

    return (lat: chosenLat, lng: chosenLng, source: source, gpsAgeMs: gpsAgeMs);
  }

  @override
  State<RoutePreviewPage> createState() => _RoutePreviewPageState();
}

class _RoutePreviewPageState extends State<RoutePreviewPage> {
  final _svc = RouteService.instance;

  GoogleMapController? _mapController;
  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};

  TravelMode _selectedMode = TravelMode.drive;
  bool _isStartingNav = false;

  final Map<TravelMode, _ModeSummary> _summaries = {
    TravelMode.drive: _ModeSummary(mode: TravelMode.drive),
    TravelMode.motor: _ModeSummary(mode: TravelMode.motor),
    TravelMode.walk: _ModeSummary(mode: TravelMode.walk),
  };

  final Map<TravelMode, RouteResult?> _routeData = {
    TravelMode.drive: null,
    TravelMode.motor: null,
    TravelMode.walk: null,
  };

  // ⚠️ motor 目前是借用 drive 的数据做 ETA 近似展示（下面 _fetchMode 里),
  // 不是针对 TWO_WHEELER 真正请求过的路线。这个标记决定了：用户点 Start
  // 时，这个模式能不能直接复用预览页的数据、跳过第二次 API 调用。
  // drive / walk 是"真的请求过"，可以跳过；motor 不行，必须让
  // NavigationController 自己用正确的 TWO_WHEELER 模式重新请求一次，
  // 不然摩托车实际导航时会错误地套用汽车路线。
  final Map<TravelMode, bool> _isRealFetch = {
    TravelMode.drive: false,
    TravelMode.motor: false,
    TravelMode.walk: false,
  };

  bool _trafficEnabled = false;

  // Track top bar height so map padding stays accurate
  double _topBarHeight = 0;
  final GlobalKey _topBarKey = GlobalKey();

  // Effective preview origin resolved before requesting initial route
  double? _effectiveStartLat;
  double? _effectiveStartLng;

  @override
  void initState() {
    super.initState();
    if (widget.initialMode != null) {
      _selectedMode = widget.initialMode!;
    }
    _validateCoordinates();
    _summaries[_selectedMode]!.loading = true;
    _resolveOriginAndFetch();

    // Measure the top bar after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateTopBarHeight());
  }

  Future<void> _resolveOriginAndFetch() async {
    final origin = await RoutePreviewPage.resolvePreviewOrigin(
      fallbackLat: widget.startLat,
      fallbackLng: widget.startLng,
    );

    if (!mounted) return;

    setState(() {
      _effectiveStartLat = origin.lat;
      _effectiveStartLng = origin.lng;
      _setMarkers();
    });

    final sLat = origin.lat;
    final sLng = origin.lng;
    if (!sLat.isFinite ||
        !sLng.isFinite ||
        !widget.endLat.isFinite ||
        !widget.endLng.isFinite ||
        (sLat == 0.0 && sLng == 0.0) ||
        (widget.endLat == 0.0 && widget.endLng == 0.0)) {
      if (mounted) {
        setState(() {
          _summaries[_selectedMode]!
            ..loading = false
            ..error = 'Invalid route coordinates.';
        });
      }
      return;
    }

    await _fetchMode(_selectedMode);
  }

  void _validateCoordinates() {
    final sLat = _effectiveStartLat ?? widget.startLat;
    final sLng = _effectiveStartLng ?? widget.startLng;
    if (!sLat.isFinite ||
        !sLng.isFinite ||
        !widget.endLat.isFinite ||
        !widget.endLng.isFinite ||
        (sLat == 0.0 && sLng == 0.0) ||
        (widget.endLat == 0.0 && widget.endLng == 0.0)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid route coordinates.')),
          );
        }
      });
    }
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
    final sLat = _effectiveStartLat ?? widget.startLat;
    final sLng = _effectiveStartLng ?? widget.startLng;

    _markers
      ..clear()
      ..addAll([
        Marker(
          markerId: const MarkerId('end'),
          position: LatLng(widget.endLat, widget.endLng),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow:
              InfoWindow(title: widget.destinationName ?? 'Destination'),
        ),
        Marker(
          markerId: const MarkerId('start'),
          position: LatLng(sLat, sLng),
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'Your location'),
        ),
      ]);
  }

  // ── Fetch ──
  Future<void> _fetchMode(TravelMode mode) async {
    // If already cached, reuse without duplicate request
    if (_routeData[mode] != null) {
      if (mode == _selectedMode) _renderPolyline(mode);
      return;
    }
    final startLat = _effectiveStartLat ?? widget.startLat;
    final startLng = _effectiveStartLng ?? widget.startLng;

    if (!startLat.isFinite ||
        !startLng.isFinite ||
        !widget.endLat.isFinite ||
        !widget.endLng.isFinite ||
        (startLat == 0.0 && startLng == 0.0) ||
        (widget.endLat == 0.0 && widget.endLng == 0.0)) {
      if (mounted) {
        setState(() {
          _summaries[mode]!
            ..loading = false
            ..error = 'Invalid coordinates';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _summaries[mode]!
          ..loading = true
          ..error = null;
      });
    }

    try {
      final result = await RouteService.instance.fetchNavigationRoute(
        fromLat: startLat,
        fromLng: startLng,
        toLat: widget.endLat,
        toLng: widget.endLng,
        mode: mode,
      );

      if (!mounted) return;

      setState(() {
        _summaries[mode]!
          ..durationSeconds = result.durationSeconds
          ..distanceMeters = result.distanceMeters
          ..loading = false
          ..isFallback = result.isFallback
          ..fallbackNotice = result.fallbackNotice;
        _routeData[mode] = result;
        _isRealFetch[mode] = true;
      });

      if (mode == _selectedMode) _renderPolyline(mode);
    } catch (e) {
      print('❌ _fetchMode error for $mode: $e');
      if (!mounted) return;
      setState(() {
        _summaries[mode]!
          ..loading = false
          ..error = e.toString();
      });
    }
  }

  // ── Render polyline for selected mode ──
  //
  // FIX: 原来这里连着调用了两次 animateCamera —— 第一次算了
  // topInset/bottomInset 取最大值当 padding，第二次紧接着又用固定
  // 的 60 调了一次。第二次调用会直接覆盖第一次的相机动画，导致
  // 第一段计算完全是无效代码，实际生效的 padding 永远是 60。
  // 结果就是路线较长、或者顶部条/底部面板实际高度超过 60 时，
  // polyline 的一部分会被压在面板底下看不到。
  // 现在只保留一次调用，真正用上算出来的 padding。
  void _renderPolyline(TravelMode mode) {
    final data = _routeData[mode];
    if (data == null) return;

    setState(() {
      _polylines
        ..clear()
        ..add(Polyline(
          polylineId: const PolylineId('route'),
          points: data.polylinePoints,
          color: const Color(0xFF1A73E8),
          width: 5,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        ));
    });

    // Padding needs to clear both the top bar and the bottom sheet,
    // whichever is taller, with a sane minimum fallback.
    final double topInset = (_topBarHeight > 0 ? _topBarHeight : 100.0) + 16.0;
    const double bottomInset = 240.0; // bottom sheet height + buffer
    final double padding =
        <double>[topInset, bottomInset, 60.0].reduce((a, b) => a > b ? a : b);

    _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(data.bounds, padding),
    );
  }

  void _selectMode(TravelMode mode) {
    if (_selectedMode == mode) return;
    setState(() => _selectedMode = mode);
    if (_routeData[mode] == null && !_summaries[mode]!.loading) {
      _fetchMode(mode);
    } else {
      _renderPolyline(mode);
    }
  }

  Future<bool> _checkPreciseLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) AppDialogs.showLocationServiceDisabled(context);
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) {
      if (mounted) AppDialogs.showLocationUnavailable(context);
      return false;
    }

    try {
      final accuracy = await Geolocator.getLocationAccuracy();
      if (accuracy == LocationAccuracyStatus.reduced) {
        if (!mounted) return false;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Precise Location Required'),
            content: const Text(
              'Turn-by-turn navigation, rerouting, and arrival check-in require precise location accuracy. Please enable precise location in App Settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Not Now'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Geolocator.openAppSettings();
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        return false;
      }
    } catch (_) {
      // If getLocationAccuracy is unsupported on specific platform, continue safely
    }

    return true;
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final selected = _summaries[_selectedMode]!;
    final mq = MediaQuery.of(context);

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
          markers: _markers,
          polylines: _polylines,
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          compassEnabled: true,
          trafficEnabled: _trafficEnabled,
          onMapCreated: (c) => _mapController = c,
          // ✅ Key fix: pad top AND bottom so route fits in the visible gap
          padding: EdgeInsets.only(
            top: topPad,
            bottom: bottomPad,
          ),
        ),

        // ── Top bar ──
        Positioned(
          key: _topBarKey,
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            color: Colors.white,
            padding: EdgeInsets.fromLTRB(8, mq.padding.top + 15, 16, 20),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                          color: Color(0xFF1A73E8), shape: BoxShape.circle),
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
                    Expanded(
                        child: Text(
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
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 20,
                  offset: Offset(0, -4),
                )
              ],
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
                    _modeTab(TravelMode.walk, Icons.directions_walk_rounded),
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
                          width: 20,
                          height: 20,
                          child: TravelLoadingIndicator(
                              size: 20, color: Color(0xFF1A73E8)),
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
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
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

                if (selected.isFallback && selected.fallbackNotice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFFB74D)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded,
                              size: 16, color: Color(0xFFE65100)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              selected.fallbackNotice!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFE65100),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 14),

                // Start button
                Padding(
                  padding:
                      EdgeInsets.fromLTRB(16, 0, 16, 16 + mq.padding.bottom),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: selected.loading ||
                              selected.error != null ||
                              _isStartingNav
                          ? null
                          : () async {
                              final canProceed = await _checkPreciseLocation();
                              if (!canProceed || !mounted) return;

                              setState(() => _isStartingNav = true);
                              try {
                                final arrived = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => GuidePage(
                                      startLat:
                                          _effectiveStartLat ?? widget.startLat,
                                      startLng:
                                          _effectiveStartLng ?? widget.startLng,
                                      endLat: widget.endLat,
                                      endLng: widget.endLng,
                                      destinationName: widget.destinationName,
                                      travelMode: _selectedMode,
                                      initialRoute:
                                          _isRealFetch[_selectedMode] == true
                                              ? _routeData[_selectedMode]
                                              : null,
                                    ),
                                  ),
                                );

                                if (!mounted) return;

                                if (arrived == true) {
                                  Navigator.pop(context, true);
                                }
                              } finally {
                                if (mounted) {
                                  setState(() => _isStartingNav = false);
                                }
                              }
                            },
                      icon: const Icon(Icons.navigation_rounded, size: 18),
                      label: const Text('Start',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
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
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _modeTab(TravelMode mode, IconData icon) {
    final summary = _summaries[mode]!;
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
                  color:
                      isSelected ? const Color(0xFF1A73E8) : Colors.grey[600]),
              const SizedBox(height: 4),
              if (summary.loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: TravelLoadingIndicator(),
                )
              else if (summary.error != null)
                Text('N/A',
                    style: TextStyle(
                        fontSize: 11,
                        color:
                            isSelected ? const Color(0xFF1A73E8) : Colors.grey))
              else if (summary.durationSeconds > 0)
                Text(_svc.formatDuration(summary.durationSeconds),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected
                            ? const Color(0xFF1A73E8)
                            : Colors.grey[700]))
              else
                Text('--',
                    style: TextStyle(
                        fontSize: 12,
                        color: isSelected
                            ? const Color(0xFF1A73E8)
                            : Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}
