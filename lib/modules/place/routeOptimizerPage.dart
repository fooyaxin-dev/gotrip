//routeOptimizerPage.dart
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gotrip/services/apps_Loading.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../itinerary/itineraryDetail.dart';
import '../../services/route_service.dart';
import '../../models/placeModel.dart';
import '../../services/placesAPI_service.dart';
import 'placeDetailPage.dart';   // 跟 RealTimeDetectPage 用的是同一个相对路径，如果不在同一文件夹，按实际路径调整

class RouteOptimizerPage extends StatefulWidget {
  final ItineraryModel itinerary;
  final double startLat;
  final double startLng;
  final String? startLocationName;
  final TravelMode travelMode;
  // true when opened from ItineraryDetailPage's Edit button on an
  // already-saved itinerary — changes how the Confirm button behaves
  // (pop back with the updated itinerary instead of pushReplacement-ing
  // a brand new ItineraryDetailPage on top of the one that's already there).
  final bool isEditingExisting;
  final List<PlaceModel> leftoverCandidates;  
  final List<String> leftoverPlaceIds;

  const RouteOptimizerPage({
    super.key,
    required this.itinerary,
    required this.startLat,
    required this.startLng,
    this.startLocationName,
    this.travelMode = TravelMode.walk,
    this.isEditingExisting = false,
    this.leftoverCandidates = const [],
    this.leftoverPlaceIds = const [],
  });

  @override
  State<RouteOptimizerPage> createState() => _RouteOptimizerPageState();
}

class _RouteOptimizerPageState extends State<RouteOptimizerPage> {
  late ItineraryModel _itinerary;
  late List<PlaceModel> _leftovers;
  List<String> _pendingLeftoverIds = [];   // 🆕 还没 hydrate 的 id
  bool _isHydratingPool = false;           // 🆕
  bool _poolHydrated = false;      

  // 0 = Overview, index i+1 = Day i
  int _selectedIndex = 0;
  int get _poolTabIndex => _itinerary.days.length + 1;
  bool _isSaving = false;
  Timer? _paddingDebounce;

  final Map<int, _DayLegs> _legsCache = {};

  // Map
  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  // Sheet
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final ValueNotifier<double> _sheetExtentNotifier = ValueNotifier(0.5);

  // Undo delete
  ItineraryPlace? _lastDeletedPlace;
  int? _lastDeletedDayIndex;
  int? _lastDeletedPlaceIndex;

  // Days currently fetching a real route matrix for Re-optimize
  final Set<int> _reOptimizingDays = {};

  String _computeLegsSignature(int dayIndex) {
    final places = _itinerary.days[dayIndex].places;
    final ids = places.map((p) => p.placeId).join(',');
    return '${widget.travelMode.name}|$ids';
  }

  static const List<Color> _dayColors = [
    Color(0xFF7C4DFF), // purple
    Color(0xFFFF6D00), // orange
    Color(0xFF00BFA5), // teal
    Color(0xFFE91E63), // pink
    Color(0xFF2979FF), // blue
    Color(0xFFFFC107), // amber
    Color(0xFF4CAF50), // green
    Color(0xFF795548), // brown
  ];

  // ─────────────────────────────────────────────
  // Getters
  // ─────────────────────────────────────────────

  double get _speedMps {
    switch (widget.travelMode) {
      case TravelMode.walk:  return 1.4;
      case TravelMode.motor: return 6.0;
      case TravelMode.drive: return 12.0;
    }
  }

  IconData get _travelIcon {
    switch (widget.travelMode) {
      case TravelMode.walk:  return Icons.directions_walk_rounded;
      case TravelMode.motor: return Icons.motorcycle_rounded;
      case TravelMode.drive: return Icons.directions_car_rounded;
    }
  }

  String get _travelLabel {
    switch (widget.travelMode) {
      case TravelMode.walk:  return 'walk';
      case TravelMode.motor: return 'ride';
      case TravelMode.drive: return 'drive';
    }
  }

  double get _minSheetSize {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomInset  = MediaQuery.of(context).padding.bottom;
    // 手柄 + 行程标题栏 + 日期tab + 分割线 + 底部按钮栏 的大致固定高度
    const fixedChromeHeight = 24.0 + 58.0 + 54.0 + 1.0 + 66.0;
    return ((fixedChromeHeight + bottomInset) / screenHeight).clamp(0.18, 0.40);
  }

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
    void initState() {
      super.initState();
      _itinerary = widget.itinerary;
      _leftovers = List.from(widget.leftoverCandidates);

      // 🆕 Generate 流程直接带完整 PlaceModel，不需要 hydrate；
      // Edit 已存档行程时只有 id，标记成"待 hydrate"，等用户真的点开
      // More Places tab 才去补全，而不是一进页面就打一堆 API
      if (widget.leftoverCandidates.isEmpty && widget.leftoverPlaceIds.isNotEmpty) {
        _pendingLeftoverIds = List.from(widget.leftoverPlaceIds);
        _poolHydrated = false;
      } else {
        _poolHydrated = true;
      }

      _updateMapOverlays();

      if (!widget.isEditingExisting && _itinerary.id.isEmpty) {
        _autoOptimizeAllDays();
      }
    }

  Future<void> _autoOptimizeAllDays() async {
    for (int d = 0; d < _itinerary.days.length; d++) {
      if (!mounted) return;
      if (_itinerary.days[d].places.length >= 2) {
        await _reOptimizeDay(d);
      }
    }
  }

  @override
  void dispose() {
    _mapController?.dispose();
    _sheetController.dispose();
    _sheetExtentNotifier.dispose();
    _paddingDebounce?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Leg calculation (per day, lazily cached)
  //
  // `_legsFor` returns synchronously — instantly, using a straight-line
  // estimate — while `_fetchRealLegsForDay` fires in the background to
  // fetch the real road-following route from the Routes API (same
  // RouteService used by RoutePreviewPage) and upgrades the cache once
  // it lands. A generation counter per day discards stale results if
  // the places for that day changed again before the fetch finished.
  // ─────────────────────────────────────────────

  final Map<int, int> _legsFetchGen = {};

  _DayLegs _legsFor(int dayIndex) {
    if (dayIndex < 0 || dayIndex >= _itinerary.days.length) {
      return _DayLegs.empty;
    }
    final existing = _legsCache[dayIndex];
    if (existing != null) return existing;

    // 🆕 先看看这天有没有存过、且签名匹配的路线数据——命中就直接用,不调 API
    final day = _itinerary.days[dayIndex];
    final currentSignature = _computeLegsSignature(dayIndex);
    if (day.legsSignature != null &&
        day.legsSignature == currentSignature &&
        day.legsData != null) {
      final hydrated = _DayLegs.fromStoredData(day.legsData!);
      _legsCache[dayIndex] = hydrated;
      return hydrated;
    }

    // 没命中——原来的流程：先垫直线距离，再异步调真实 API
    final fallback = _computeStraightLegsForDay(dayIndex);
    _legsCache[dayIndex] = fallback;
    _fetchRealLegsForDay(dayIndex);
    return fallback;
  }

  _DayLegs _computeStraightLegsForDay(int dayIndex) {
    final places = _itinerary.days[dayIndex].places;
    final legs    = <double>[];
    final legMins = <int>[];
    double totalM = 0;

    double prevLat;
    double prevLng;
    if (dayIndex == 0) {
      prevLat = widget.startLat;
      prevLng = widget.startLng;
    } else if (places.isNotEmpty) {
      prevLat = places.first.lat ?? widget.startLat;
      prevLng = places.first.lng ?? widget.startLng;
    } else {
      prevLat = widget.startLat;
      prevLng = widget.startLng;
    }

    for (int i = 0; i < places.length; i++) {
      final place = places[i];
      final lat = place.lat ?? prevLat;
      final lng = place.lng ?? prevLng;
      // Day > 0 has no known real-world starting point, so its first
      // leg contributes 0 distance instead of a misleading jump.
      final d = (dayIndex > 0 && i == 0)
          ? 0.0
          : Geolocator.distanceBetween(prevLat, prevLng, lat, lng);
      legs.add(d);
      legMins.add((d / _speedMps / 60).round());
      totalM += d;
      prevLat = lat;
      prevLng = lng;
    }

    return _DayLegs(
      distances: legs,
      minutes:   legMins,
      segments:  const [],
      totalKm:   totalM / 1000,
      totalMin:  legMins.fold(0, (a, b) => a + b),
      isReal:    false,
    );
  }

  Future<void> _fetchRealLegsForDay(int dayIndex) async {
    final myGen = (_legsFetchGen[dayIndex] ?? 0) + 1;
    _legsFetchGen[dayIndex] = myGen;

    final places = _itinerary.days[dayIndex].places;
    if (places.isEmpty) return;

    // Build the (from → to) pairs for every leg of this day first, so
    // all the Routes API calls can fire in parallel instead of one by one.
    final pairs = <_LegPair>[];
    double prevLat = dayIndex == 0
        ? widget.startLat
        : (places.first.lat ?? widget.startLat);
    double prevLng = dayIndex == 0
        ? widget.startLng
        : (places.first.lng ?? widget.startLng);

    for (int i = 0; i < places.length; i++) {
      final lat = places[i].lat ?? prevLat;
      final lng = places[i].lng ?? prevLng;
      // Day > 0 has no known real-world starting point for its first leg.
      final skip = dayIndex > 0 && i == 0;
      pairs.add(_LegPair(
          fromLat: prevLat, fromLng: prevLng,
          toLat: lat, toLng: lng, skip: skip));
      prevLat = lat;
      prevLng = lng;
    }

    final results = await Future.wait(pairs.map((p) async {
      if (p.skip) return const _LegResult(distance: 0, minutes: 0, points: []);
      try {
        final summary = await RouteService.instance.fetchRouteSummary(
          fromLat: p.fromLat, fromLng: p.fromLng,
          toLat:   p.toLat,   toLng:   p.toLng,
          mode:    widget.travelMode,
        );
        return _LegResult(
          distance: summary.distanceMeters,
          minutes:  (summary.durationSeconds / 60).round(),
          points:   summary.polylinePoints,
        );
      } catch (_) {
        // Per-leg fallback — one failed leg shouldn't blank out the rest.
        final straight = Geolocator.distanceBetween(
            p.fromLat, p.fromLng, p.toLat, p.toLng);
        return _LegResult(
          distance: straight,
          minutes:  (straight / _speedMps / 60).round(),
          points:   [LatLng(p.fromLat, p.fromLng), LatLng(p.toLat, p.toLng)],
        );
      }
    }));

    if (!mounted || _legsFetchGen[dayIndex] != myGen) return; // superseded

    final distances = results.map((r) => r.distance).toList();
    final minutes   = results.map((r) => r.minutes).toList();
    final segments  = results.map((r) => r.points).toList();
    final totalM    = distances.fold<double>(0, (a, b) => a + b);

    setState(() {
    final newLegs = _DayLegs(
      distances: distances,
      minutes:   minutes,
      segments:  segments,
      totalKm:   totalM / 1000,
      totalMin:  minutes.fold(0, (a, b) => a + b),
      isReal:    true,
    );
    _legsCache[dayIndex] = newLegs;

    // 🆕 顺便持久化进 _itinerary，下次保存时就带着走
    final days = List<ItineraryDay>.from(_itinerary.days);
    days[dayIndex] = days[dayIndex].copyWith(
      legsSignature: _computeLegsSignature(dayIndex),
      legsData: newLegs.toStoredData(),
    );
    _itinerary = _itinerary.copyWith(days: days);
  });

    _updateMapOverlays();
  }

  void _invalidateLegs(int dayIndex) {
    _legsCache.remove(dayIndex);

    // 🆕 同步清空持久化的签名/数据，避免用户改了地点但没保存前，
    // _legsFor 又误读到已经过时的 legsData
    final days = List<ItineraryDay>.from(_itinerary.days);
    days[dayIndex] = days[dayIndex].copyWith(clearLegs: true);
    _itinerary = _itinerary.copyWith(days: days);
  }
  
  // ─────────────────────────────────────────────
  // Map overlays
  // ─────────────────────────────────────────────

  // _updateMapOverlays：
  Future<void> _updateMapOverlays() async {
    if (_selectedIndex == 0 || _selectedIndex == _poolTabIndex) {
      await _updateOverviewOverlays();
    } else {
      await _updateDayOverlays(_selectedIndex - 1);
    }
  }

  Future<void> _updateOverviewOverlays() async {
    final newMarkers   = <Marker>{};
    final newPolylines = <Polyline>{};
    final allPoints    = <LatLng>[LatLng(widget.startLat, widget.startLng)];

    newMarkers.add(Marker(
      markerId: const MarkerId('__start__'),
      position: LatLng(widget.startLat, widget.startLng),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      infoWindow:
          InfoWindow(title: widget.startLocationName ?? 'Your Location'),
    ));

    for (int d = 0; d < _itinerary.days.length; d++) {
      final color = _dayColors[d % _dayColors.length];
      final places = _itinerary.days[d].places;
      final dayPoints = <LatLng>[]; // marker points — used for camera fit only
      if (d == 0) dayPoints.add(LatLng(widget.startLat, widget.startLng));

      for (int i = 0; i < places.length; i++) {
        final p = places[i];
        if (p.lat == null || p.lng == null) continue;
        final icon = await _buildNumberedPin(i + 1, color);
        newMarkers.add(Marker(
          markerId: MarkerId('d${d}_s$i'),
          position: LatLng(p.lat!, p.lng!),
          icon: icon,
          infoWindow: InfoWindow(title: '${p.name} · Day ${d + 1}'),
        ));
        dayPoints.add(LatLng(p.lat!, p.lng!));
        allPoints.add(LatLng(p.lat!, p.lng!));
      }

      final legs = _legsFor(d);
      final routePoints = <LatLng>[];
      if (legs.isReal) {
        for (final seg in legs.segments) {
          routePoints.addAll(seg);
        }
      } else {
        routePoints.addAll(dayPoints); // straight-line fallback while loading
      }

      if (routePoints.length >= 2) {
        newPolylines.add(Polyline(
          polylineId: PolylineId('day_$d'),
          points: routePoints,
          color: color,
          width: 3,
          patterns: legs.isReal
              ? const []
              : [PatternItem.dash(14), PatternItem.gap(7)],
        ));
      }
    }

    if (!mounted) return;
    setState(() {
      _markers   = newMarkers;
      _polylines = newPolylines;
    });
    _fitCamera(allPoints);
  }

  Future<void> _updateDayOverlays(int dayIndex) async {
    final newMarkers   = <Marker>{};
    final newPolylines = <Polyline>{};
    final places = _itinerary.days[dayIndex].places;
    final color  = _dayColors[dayIndex % _dayColors.length];
    final points = <LatLng>[];

    if (dayIndex == 0) {
      newMarkers.add(Marker(
        markerId: const MarkerId('__start__'),
        position: LatLng(widget.startLat, widget.startLng),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow:
            InfoWindow(title: widget.startLocationName ?? 'Your Location'),
      ));
      points.add(LatLng(widget.startLat, widget.startLng));
    }

    for (int i = 0; i < places.length; i++) {
      final p = places[i];
      if (p.lat == null || p.lng == null) continue;
      final icon = await _buildNumberedPin(
          i + 1, _stopColor(i, places.length, color));
      newMarkers.add(Marker(
        markerId: MarkerId('stop_$i'),
        position: LatLng(p.lat!, p.lng!),
        icon: icon,
        infoWindow: InfoWindow(title: p.name),
      ));
      points.add(LatLng(p.lat!, p.lng!));
    }

    final legs = _legsFor(dayIndex);
    final routePoints = <LatLng>[];
    if (legs.isReal) {
      for (final seg in legs.segments) {
        routePoints.addAll(seg);
      }
    } else {
      routePoints.addAll(points); // straight-line fallback while loading
    }

    if (routePoints.length >= 2) {
      newPolylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: routePoints,
        color: color,
        width: 3,
        patterns: legs.isReal
            ? const []
            : [PatternItem.dash(16), PatternItem.gap(8)],
      ));
    }

    if (!mounted) return;
    setState(() {
      _markers   = newMarkers;
      _polylines = newPolylines;
    });
    _fitCamera(points);
  }

  void _fitCamera(List<LatLng> points) {
    if (_mapController == null || points.isEmpty) return;
    if (points.length == 1) {
      _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(points.first, 15));
      return;
    }
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in points) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      ), 60,
    ));
  }

  Future<BitmapDescriptor> _buildNumberedPin(int number, Color color) async {
    const size = 48.0;
    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder);
    canvas.drawCircle(
      const Offset(size / 2 + 1, size / 2 + 2),
      size / 2 - 4,
      Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 4,
        Paint()..color = color);
    canvas.drawCircle(
      const Offset(size / 2, size / 2), size / 2 - 4,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '$number',
        style: const TextStyle(
            color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));
    final img  = await recorder.endRecording()
        .toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
  }

  // ─────────────────────────────────────────────
  // Tab switching
  // ─────────────────────────────────────────────

  void _switchTab(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
    _updateMapOverlays();

    // 🆕 第一次点进 More Places tab 才去补全候补池详情
    if (index == _poolTabIndex && !_poolHydrated && !_isHydratingPool) {
      _hydrateLeftoverPool();
    }
  }

  // 🆕 把 _pendingLeftoverIds 逐个补全成 PlaceModel。
  // 单个 id 失败（place 下架/无效）不影响其他的，直接跳过。
  Future<void> _hydrateLeftoverPool() async {
    if (_pendingLeftoverIds.isEmpty) {
      _poolHydrated = true;
      return;
    }
    setState(() => _isHydratingPool = true);

    final results = await Future.wait(_pendingLeftoverIds.map((id) async {
      try {
        return await PlacesApiService.getPlaceModelDetails(id);
      } catch (_) {
        return null;
      }
    }));

    if (!mounted) return;
    setState(() {
      _leftovers = [..._leftovers, ...results.whereType<PlaceModel>()];
      _isHydratingPool = false;
      _poolHydrated = true;
    });
  }

  // ─────────────────────────────────────────────
  // Reorder / Remove / Undo / Re-optimize (within a day)
  // ─────────────────────────────────────────────

  void _reorderWithinDay(int dayIndex, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    final item   = places.removeAt(oldIndex);
    places.insert(newIndex, item);
    days[dayIndex] = days[dayIndex].copyWith(places: places);
    setState(() => _itinerary = _itinerary.copyWith(days: days));
    _invalidateLegs(dayIndex);
    _updateMapOverlays();
  }

  void _removePlace(int dayIndex, int placeIndex) {
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    final removed = places[placeIndex];
    places.removeAt(placeIndex);
    days[dayIndex] = days[dayIndex].copyWith(places: places);

    setState(() {
      _lastDeletedPlace      = removed;
      _lastDeletedDayIndex   = dayIndex;
      _lastDeletedPlaceIndex = placeIndex;
      _itinerary = _itinerary.copyWith(days: days);

      // 🆕 删除后放回候补池,跟 swap 的逻辑保持一致
      if (removed.lat != null && removed.lng != null &&
          !_leftovers.any((p) => p.id == removed.placeId)) {
        _leftovers.add(PlaceModel(
          id: removed.placeId,
          name: removed.name,
          address: removed.address,
          lat: removed.lat,
          lng: removed.lng,
          photoUrl: removed.photoUrl,
          source: 'google',
          primaryType: removed.primaryType,
          allTypes: removed.primaryType != null ? [removed.primaryType!] : const [],
        ));
      }
    });
    _invalidateLegs(dayIndex);
    _updateMapOverlays();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(
              child: Text('${removed.name} removed',
                  style: const TextStyle(fontSize: 13)),
            ),
            GestureDetector(
              onTap: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
              child: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.close_rounded, size: 16, color: Colors.white70),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 5),   // 🔧 3 → 5
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: const Color(0xFF1A1A2E),
        action: SnackBarAction(
          label: 'Undo',
          textColor: const Color(0xFF9B8FFF),
          onPressed: _undoDelete,
        ),
      ),
    );
  }

  void _undoDelete() {
    if (_lastDeletedPlace == null ||
        _lastDeletedDayIndex == null ||
        _lastDeletedPlaceIndex == null) return;

    final dayIndex   = _lastDeletedDayIndex!;
    final placeIndex = _lastDeletedPlaceIndex!;
    final place      = _lastDeletedPlace!;

    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    places.insert(placeIndex.clamp(0, places.length), place);
    days[dayIndex] = days[dayIndex].copyWith(places: places);

    setState(() {
      _itinerary = _itinerary.copyWith(days: days);
      _leftovers.removeWhere((p) => p.id == place.placeId);
      _lastDeletedPlace      = null;
      _lastDeletedDayIndex   = null;
      _lastDeletedPlaceIndex = null;
    });
    _invalidateLegs(dayIndex);
    _updateMapOverlays();
  }

  Future<void> _reOptimizeDay(int dayIndex) async {
    final places = _itinerary.days[dayIndex].places;
    if (places.length < 2) return; // nothing meaningful to reorder

    setState(() => _reOptimizingDays.add(dayIndex));

    try {
      final geoPlaces    = places.where((p) => p.lat != null && p.lng != null).toList();
      final nonGeoPlaces = places.where((p) => p.lat == null || p.lng == null).toList();
      if (geoPlaces.length < 2) return;

      // Day 0 has a known real starting point (widget.startLat/Lng) — include
      // it as point 0 so the matrix/ordering accounts for it. Day > 0 has no
      // known real start, so ordering just starts from the first place.
      final hasStart = dayIndex == 0;
      final points = <LatLng>[
        if (hasStart) LatLng(widget.startLat, widget.startLng),
        ...geoPlaces.map((p) => LatLng(p.lat!, p.lng!)),
      ];

      // Try to get a real road-distance matrix for every pair of points in
      // one call. If the API call fails for any reason (offline, quota,
      // etc.), fall back to straight-line distance so re-optimize still works.
      List<List<double>>? matrix;
      try {
        final elements = await RouteService.instance.fetchRouteMatrix(
          origins: points,
          destinations: points,
          mode: widget.travelMode,
        );
        matrix = List.generate(
            points.length, (_) => List.filled(points.length, double.infinity));
        for (final e in elements) {
          if (e.isValid &&
              e.originIndex < points.length &&
              e.destinationIndex < points.length) {
            matrix[e.originIndex][e.destinationIndex] = e.distanceMeters;
          }
        }
      } catch (_) {
        matrix = null;
      }

      double distBetween(int i, int j) {
        final fromMatrix = matrix?[i][j];
        if (fromMatrix != null && fromMatrix.isFinite) return fromMatrix;
        return Geolocator.distanceBetween(
          points[i].latitude, points[i].longitude,
          points[j].latitude, points[j].longitude,
        );
      }

      // Nearest-neighbor walk over the real (or straight-line fallback)
      // distances, starting from point 0 — the known start for day 0, or
      // simply the first place for day > 0.
      final remaining = List<int>.generate(points.length, (i) => i)..removeAt(0);
      final order = <int>[];

      // 🔧 FIX: 当这天没有真实起点时（dayIndex > 0），index 0 本身就是
      // 这天的第一个真实地点，不是占位符——必须先加进 order，否则它会
      // 被当成"起跑点"用来计算距离，却永远进不了最终结果，直接消失。
      if (!hasStart) {
        order.add(0);
      }

      int current = 0;
      while (remaining.isNotEmpty) {
        int? nearest;
        double minDist = double.infinity;
        for (final idx in remaining) {
          final d = distBetween(current, idx);
          if (d < minDist) { minDist = d; nearest = idx; }
        }
        nearest ??= remaining.first;
        order.add(nearest);
        remaining.remove(nearest);
        current = nearest;
      }

      final placeOffset = hasStart ? 1 : 0;
      final reordered = order
          .where((idx) => idx >= placeOffset)
          .map((idx) => geoPlaces[idx - placeOffset])
          .toList();

      // Times are attached to each place, not to its position — after
      // reordering, re-assign them sequentially so the schedule still
      // reads chronologically. Anchor to whichever time was earliest in
      // the original list, so a day that started at, say, 10:00 stays
      // starting around 10:00 rather than snapping back to a hardcoded time.
      final startMinutes = places.isEmpty
          ? 9 * 60
          : places
              .map((p) => _parseTimeToMinutes(p.suggestedTime))
              .reduce((a, b) => a < b ? a : b);

      var cursorMinutes = startMinutes;
      final retimed = reordered.map((p) {
        final hh = (cursorMinutes ~/ 60) % 24;
        final mm = cursorMinutes % 60;
        final updated = p.copyWith(
          suggestedTime:
              '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}',
        );
        cursorMinutes += p.durationMinutes;
        return updated;
      }).toList();

      if (!mounted) return;

      final days = List<ItineraryDay>.from(_itinerary.days);
      days[dayIndex] =
          days[dayIndex].copyWith(places: [...retimed, ...nonGeoPlaces]);
      setState(() => _itinerary = _itinerary.copyWith(days: days));
      _invalidateLegs(dayIndex);
      _updateMapOverlays();
    } finally {
      if (mounted) setState(() => _reOptimizingDays.remove(dayIndex));
    }
  }

  int _parseTimeToMinutes(String t) {
    try {
      final parts = t.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    } catch (_) {
      return 9 * 60;
    }
  }

  // ─────────────────────────────────────────────
  // Free drag & drop — same day or across days,
  // dropped at the exact position of the target chip
  // ─────────────────────────────────────────────

  void _movePlaceToPosition(
    _DragPayload payload, int targetDayIndex, int targetIndex) {
  if (payload.isFromPool) {
    _addPoolPlaceToPosition(payload.poolPlace!, targetDayIndex, targetIndex);
    return;
  }

  final sourceDayIndex   = payload.dayIndex!;
  final sourcePlaceIndex = payload.placeIndex!;

  // Dropping onto its own current spot — nothing to do.
  if (sourceDayIndex == targetDayIndex &&
      (sourcePlaceIndex == targetIndex ||
          sourcePlaceIndex == targetIndex - 1)) {
    return;
  }

  final days = List<ItineraryDay>.from(_itinerary.days);

  final sourcePlaces = List<ItineraryPlace>.from(days[sourceDayIndex].places);
  if (sourcePlaceIndex >= sourcePlaces.length) return;
  final moved = sourcePlaces.removeAt(sourcePlaceIndex);
  days[sourceDayIndex] = days[sourceDayIndex].copyWith(places: sourcePlaces);

  var insertAt = targetIndex;
  if (sourceDayIndex == targetDayIndex && sourcePlaceIndex < targetIndex) {
    insertAt -= 1;
  }

  final targetPlaces = List<ItineraryPlace>.from(days[targetDayIndex].places);
  insertAt = insertAt.clamp(0, targetPlaces.length);
  targetPlaces.insert(insertAt, moved);
  days[targetDayIndex] = days[targetDayIndex].copyWith(places: targetPlaces);

  setState(() => _itinerary = _itinerary.copyWith(days: days));
  _invalidateLegs(sourceDayIndex);
  _invalidateLegs(targetDayIndex);
  _updateMapOverlays();

  if (sourceDayIndex != targetDayIndex) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${moved.name} moved to Day ${targetDayIndex + 1}',
            style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: const Color(0xFF1A1A2E),
      ),
    );
  }
}

// Adds a place dragged in from the leftover pool as a brand-new stop at
// [targetIndex] within [targetDayIndex]. This INCREASES that day's stop
// count — it never overwrites an existing stop (that's what the swap
// sheet on each place card is for). Removed from the pool once added so
// it can't be dropped in twice.
void _addPoolPlaceToPosition(
    PlaceModel poolPlace, int targetDayIndex, int targetIndex) {
  final days = List<ItineraryDay>.from(_itinerary.days);
  final targetPlaces = List<ItineraryPlace>.from(days[targetDayIndex].places);
  final insertAt = targetIndex.clamp(0, targetPlaces.length);

  // Anchor the new stop's suggested time near whatever's already
  // scheduled at this position, instead of a hardcoded default.
  int anchorMinutes;
  if (targetPlaces.isEmpty) {
    anchorMinutes = 9 * 60;
  } else if (insertAt > 0) {
    final prev = targetPlaces[insertAt - 1];
    anchorMinutes = _parseTimeToMinutes(prev.suggestedTime) + prev.durationMinutes;
  } else {
    anchorMinutes = _parseTimeToMinutes(targetPlaces.first.suggestedTime);
  }
  final hh = (anchorMinutes ~/ 60) % 24;
  final mm = anchorMinutes % 60;

  final newPlace = _placeModelToItineraryPlace(
    poolPlace,
    suggestedTime: '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}',
    durationMinutes: 60,
  );

  targetPlaces.insert(insertAt, newPlace);
  days[targetDayIndex] = days[targetDayIndex].copyWith(places: targetPlaces);

  setState(() {
    _itinerary = _itinerary.copyWith(days: days);
    _leftovers.removeWhere((p) => p.id == poolPlace.id);
  });
  _invalidateLegs(targetDayIndex);
  _updateMapOverlays();

  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('${poolPlace.name} added to Day ${targetDayIndex + 1}',
          style: const TextStyle(fontSize: 13)),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: const Color(0xFF1A1A2E),
    ),
  );
}

  
  
  // ─────────────────────────────────────────────
  // Time / Duration editing
  // ─────────────────────────────────────────────

  void _updatePlace(int dayIndex, int placeIndex, ItineraryPlace updated) {
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    places[placeIndex] = updated;
    days[dayIndex] = days[dayIndex].copyWith(places: places);
    setState(() => _itinerary = _itinerary.copyWith(days: days));
    _invalidateLegs(dayIndex);
  }

  TimeOfDay _parseTime(String t) {
    try {
      final parts = t.split(':');
      return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    } catch (_) {
      return const TimeOfDay(hour: 9, minute: 0);
    }
  }

  Future<void> _pickTime(
      int dayIndex, int placeIndex, ItineraryPlace place) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _parseTime(place.suggestedTime),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF7C4DFF),
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      final hh = picked.hour.toString().padLeft(2, '0');
      final mm = picked.minute.toString().padLeft(2, '0');
      _updatePlace(dayIndex, placeIndex,
          place.copyWith(suggestedTime: '$hh:$mm'));
    }
  }

  Future<void> _pickDuration(
      int dayIndex, int placeIndex, ItineraryPlace place) async {
    const presets = [15, 30, 45, 60, 90, 120, 150, 180, 240];
    int selected  = place.durationMinutes;

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Visit Duration',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Select how long you plan to stay',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: presets.map((mins) {
                  final isSelected = selected == mins;
                  final label = mins < 60
                      ? '$mins min'
                      : mins % 60 == 0
                          ? '${mins ~/ 60}h'
                          : '${mins ~/ 60}h ${mins % 60}min';
                  return ChoiceChip(
                    label: Text(label),
                    selected: isSelected,
                    onSelected: (_) => setSheet(() => selected = mins),
                    selectedColor: const Color(0xFF7C4DFF),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.black87,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _updatePlace(dayIndex, placeIndex,
                        place.copyWith(durationMinutes: selected));
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C4DFF),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Confirm',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  // ─────────────────────────────────────────────
  // Save
  // ─────────────────────────────────────────────

  Future<void> _saveAndContinue() async {
    final hasAnyPlace = _itinerary.days.any((d) => d.places.isNotEmpty);
    if (!hasAnyPlace) return;
    setState(() => _isSaving = true);

    // 🆕 把用户这次 session 里最终的候补池 id 写回去，
    // 这样下次再 edit，候补池还是这次离开时的状态
    _itinerary = _itinerary.copyWith(
      leftoverPlaceIds: _leftovers.map((p) => p.id).toList(),
    );
    
    String? savedId;
    if (_itinerary.id.isEmpty) {
      savedId = await ItineraryService.instance.save(_itinerary);
    } else {
      await ItineraryService.instance.update(_itinerary);
      savedId = _itinerary.id;
    }

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (savedId == null) {
      final isLoggedIn = FirebaseAuth.instance.currentUser != null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isLoggedIn
            ? 'Failed to save itinerary'
            : 'Please log in to save itinerary'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    final saved = ItineraryModel.fromMap(savedId, _itinerary.toMap());

    if (widget.isEditingExisting) {
      // Editing a trip that already has its own ItineraryDetailPage on the
      // stack below us — just hand the updated itinerary back to it instead
      // of pushing a second, duplicate detail page on top.
      Navigator.pop(context, saved);
      return;
    }

    // `result: true` lets whoever pushed this page (e.g. GenerateItineraryPage)
    // know the draft was actually confirmed & saved, vs. just backed out of.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ItineraryDetailPage(itinerary: saved)),
      result: true,
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      body: Stack(
        children: [

          // ── Map behind everything ──
          Column(children: [
            _buildHeader(),
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: _sheetExtentNotifier,
                builder: (context, extent, _) {
                  return GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: LatLng(widget.startLat, widget.startLng),
                      zoom: 13,
                    ),
                    markers:   _markers,
                    polylines: _polylines,
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    padding: EdgeInsets.only(bottom: screenHeight * extent),
                    onMapCreated: (c) {
                      _mapController = c;
                      Future.delayed(const Duration(milliseconds: 400),
                          () => _updateMapOverlays());
                    },
                  );
                },
              ),
            ),
          ]),

          // ── Draggable sheet ──
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (n) {
              _paddingDebounce?.cancel();
              _paddingDebounce = Timer(const Duration(milliseconds: 16), () {
                if (mounted) _sheetExtentNotifier.value = n.extent;
              });
              return false;
            },
            child: DraggableScrollableSheet(
              controller:       _sheetController,
              initialChildSize: 0.5,
              minChildSize:     _minSheetSize,
              maxChildSize:     0.88,
              snap:             false,
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24)),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    )],
                  ),
                  child: _buildSheetContent(scrollController),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Header
  // ─────────────────────────────────────────────

  Widget _buildHeader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white, size: 18),
                  onPressed: () => Navigator.pop(context),
                ),
                Expanded(
                  child: Text(
                      widget.isEditingExisting
                          ? 'Edit Itinerary'
                          : 'Adjust Your Trip',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 8),
                child: Row(children: [
                  const Icon(Icons.info_outline_rounded,
                      color: Colors.white60, size: 13),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                     // _buildHeader 提示文字：
                      _selectedIndex == 0
                          ? 'Drag a place onto another day to move it'
                          : _selectedIndex == _poolTabIndex
                              ? 'Drag a place onto a day tab to add it as a new stop'
                              : 'Drag stops to reorder • Tap × to remove',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Sheet content
  // ─────────────────────────────────────────────

  Widget _buildSheetContent(ScrollController scrollController) {
    return Column(
      children: [
        _buildSheetHandle(),
        _buildTripHeader(),
        _buildDayTabs(),
        const SizedBox(height: 8),
        const Divider(height: 1, thickness: 0.5),
       Expanded(
          child: _selectedIndex == 0
              ? _buildOverviewContent(scrollController)
              : _selectedIndex == _poolTabIndex
                  ? _buildPoolContent(scrollController)
                  : _buildDayContent(_selectedIndex - 1, scrollController),
        ),
        _buildBottomBar(),
      ],
    );
  }

  Widget _buildSheetHandle() {
    return GestureDetector(
      onTap: () {
        final current = _sheetExtentNotifier.value;
        final next = current < 0.30
            ? 0.5
            : current < 0.70
                ? 0.85
                : _minSheetSize;
        _sheetController.animateTo(
          next,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      },
      onVerticalDragUpdate: (details) {
        final screenHeight = MediaQuery.of(context).size.height;
        final delta = -details.delta.dy / screenHeight;
        final newSize = (_sheetController.size + delta).clamp(_minSheetSize, 0.88);
        _sheetController.jumpTo(newSize);
      },
      behavior: HitTestBehavior.translucent,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Center(
          child: Container(
            width: 44, height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTripHeader() {
    final totalPlaces = _itinerary.totalPlaces;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) {
        final screenHeight = MediaQuery.of(context).size.height;
        final delta = -details.delta.dy / screenHeight;
        final newSize = (_sheetController.size + delta).clamp(_minSheetSize, 0.88);
        _sheetController.jumpTo(newSize);
      },
      child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_itinerary.title,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                  '${_itinerary.totalDays} '
                  '${_itinerary.totalDays == 1 ? "day" : "days"} · '
                  '$totalPlaces stops · Starting ${_itinerary.startDate}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
          if (_selectedIndex != 0 && _selectedIndex != _poolTabIndex)
            Builder(builder: (context) {
              final dayIndex = _selectedIndex - 1;
              final isBusy = _reOptimizingDays.contains(dayIndex);
              return GestureDetector(
                onTap: isBusy ? null : () => _reOptimizeDay(dayIndex),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C4DFF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (isBusy)
                      const SizedBox(
                        width: 13, height: 13,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: Color(0xFF7C4DFF)),
                      )
                    else
                      const Icon(Icons.auto_fix_high_rounded,
                          size: 13, color: Color(0xFF7C4DFF)),
                    const SizedBox(width: 4),
                    Text(isBusy ? 'Optimizing...' : 'Re-optimize',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF7C4DFF),
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              );
            }),
        ],
      ),
      ),
    );
  }

  Widget _buildDayTabs() {
  return SizedBox(
    height: 54,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        _dayTabChip(index: 0, label: 'Overview',
            color: const Color(0xFF1A1A2E), icon: Icons.map_rounded),
        for (int d = 0; d < _itinerary.days.length; d++)
          _dayTabChip(
            index: d + 1,
            label: 'Day ${d + 1}',
            subLabel: _formatDayDate(_itinerary.days[d].date),
            color: _dayColors[d % _dayColors.length],
            isComplete: _itinerary.days[d].isCompleted &&
                _itinerary.days[d].totalCount > 0,
            dropDayIndex: d,
          ),
        _dayTabChip(
          index: _poolTabIndex,
          label: 'More Places',
          subLabel: _leftovers.isEmpty ? null : '${_leftovers.length} found',
          color: const Color(0xFF00BFA5),
          icon: Icons.add_location_alt_rounded,
        ),
      ],
    ),
  );
}
  
  String _formatDayDate(String date) {
    try {
      return DateFormat('MMM dd').format(DateTime.parse(date));
    } catch (_) {
      return '';
    }
  }

  Widget _dayTabChip({
  required int index,
  required String label,
  String? subLabel,
  required Color color,
  IconData? icon,
  bool isComplete = false,
  int? dropDayIndex, // set only for real "Day N" chips — lets a place be
                      // dropped straight onto the tab to append it there
                      // without switching tabs first (used by the pool).
}) {
  final isSelected = _selectedIndex == index;

  Widget chipBody({bool isHovering = false}) => Container(
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(
      color: isSelected ? color : color.withOpacity(isHovering ? 0.18 : 0.08),
      borderRadius: BorderRadius.circular(14),
      border: isHovering ? Border.all(color: color, width: 1.5) : null,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: isSelected ? Colors.white : color),
          const SizedBox(width: 5),
        ] else
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: isSelected ? Colors.white : color,
              shape: BoxShape.circle,
            ),
          ),
        const SizedBox(width: 5),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? Colors.white : color)),
            if (subLabel != null && subLabel.isNotEmpty)
              Text(subLabel,
                  style: TextStyle(
                      fontSize: 9,
                      color: isSelected ? Colors.white70 : color.withOpacity(0.7))),
          ],
        ),
        if (isComplete) ...[
          const SizedBox(width: 4),
          Icon(Icons.check_circle_rounded,
              size: 12, color: isSelected ? Colors.white : color),
        ],
      ],
    ),
  );

  if (dropDayIndex == null) {
    return GestureDetector(onTap: () => _switchTab(index), child: chipBody());
  }

  return DragTarget<_DragPayload>(
    onWillAccept: (payload) => payload != null,
    onAccept: (payload) => _movePlaceToPosition(
        payload, dropDayIndex, _itinerary.days[dropDayIndex].places.length),
    builder: (context, candidateData, rejectedData) => GestureDetector(
      onTap: () => _switchTab(index),
      child: chipBody(isHovering: candidateData.isNotEmpty),
    ),
  );
}
  
  // ─────────────────────────────────────────────
  // Overview content (all days, cross-day drag)
  // ─────────────────────────────────────────────

  Widget _buildOverviewContent(ScrollController scrollController) {
    return ListView.builder(
      key: const ValueKey('overview_scroll'),
      controller: scrollController,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      itemCount: _itinerary.days.length,
      itemBuilder: (_, dayIndex) => _buildOverviewDaySection(dayIndex),
    );
  }

  Widget _buildOverviewDaySection(int dayIndex) {
    final day   = _itinerary.days[dayIndex];
    final legs  = _legsFor(dayIndex);
    final color = _dayColors[dayIndex % _dayColors.length];

    return DragTarget<_DragPayload>(
      onWillAccept: (payload) => payload != null,
      onAccept: (payload) =>
          _movePlaceToPosition(payload, dayIndex, day.places.length),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return Container(
          margin: const EdgeInsets.only(bottom: 22),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            border: Border.all(
                color: isHovering ? color : Colors.transparent, width: 2),
            borderRadius: BorderRadius.circular(20),
            color: isHovering ? color.withOpacity(0.05) : Colors.transparent,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => _switchTab(dayIndex + 1),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(children: [
                    Container(
                        width: 10, height: 10,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(
                        'Day ${dayIndex + 1} · ${_formatDayDate(day.date)}',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: color)),
                    const SizedBox(width: 6),
                    if (day.isCompleted && day.totalCount > 0)
                      const Icon(Icons.check_circle_rounded,
                          size: 14, color: Colors.green),
                    const Spacer(),
                    if (_reOptimizingDays.contains(dayIndex))
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: SizedBox(
                          width: 10, height: 10,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Colors.grey),
                        ),
                      ),
                    Text(
                        '${day.places.length} stops · '
                        '${legs.totalKm.toStringAsFixed(1)} km',
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey[500])),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: Colors.grey[400]),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              if (day.places.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: Center(
                    child: Text('No places · drag one here',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[400])),
                  ),
                )
              else
                ...day.places.asMap().entries.map((entry) =>
                    _buildDropZoneChip(dayIndex, entry.key, entry.value, color)),
            ],
          ),
        );
      },
    );
  }

  // A drop target wrapping a single chip: dropping any place here — from
  // this same day or any other day — inserts it right at this position.
  Widget _buildDropZoneChip(
      int dayIndex, int placeIndex, ItineraryPlace place, Color color) {
    return DragTarget<_DragPayload>(
      onWillAccept: (payload) =>
          payload != null &&
          !(payload.dayIndex == dayIndex && payload.placeIndex == placeIndex),
      onAccept: (payload) =>
          _movePlaceToPosition(payload, dayIndex, placeIndex),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: isHovering ? color : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: _buildDraggableChip(dayIndex, placeIndex, place, color),
        );
      },
    );
  }

  Widget _buildDraggableChip(
      int dayIndex, int placeIndex, ItineraryPlace place, Color color) {
    final chip = GestureDetector(   // 🆕 包一层，点击看详情
    onTap: () => _openPlaceDetailFromItinerary(place),
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[100]!),
        boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Icon(Icons.drag_indicator_rounded, size: 16, color: Colors.grey[350]),
        const SizedBox(width: 6),
        Container(
          width: 22, height: 22,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Center(
            child: Text('${placeIndex + 1}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(width: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: place.photoUrl != null
              ? Image.network(place.photoUrl!,
                  width: 36, height: 36, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _photoPlaceholder(size: 36))
              : _photoPlaceholder(size: 36),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(place.name,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              Text(place.suggestedTime,
                  style: TextStyle(fontSize: 10, color: Colors.grey[500])),
            ],
          ),
        ),
      ]),
    )
    );

    return LongPressDraggable<_DragPayload>(
      data: _DragPayload.fromDay(
      dayIndex: dayIndex, placeIndex: placeIndex, place: place),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
            width: 260, child: Opacity(opacity: 0.9, child: chip)),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      child: chip,
    );
  }

  // ─────────────────────────────────────────────
  // Day content (single-day timeline editing)
  // ─────────────────────────────────────────────

  Widget _buildDayContent(int dayIndex, ScrollController scrollController) {
    final day  = _itinerary.days[dayIndex];
    final legs = _legsFor(dayIndex);

    return CustomScrollView(
      key: ValueKey('day_scroll_$dayIndex'),
      controller: scrollController,
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(child: _buildDaySummaryBar(dayIndex, legs)),
        const SliverToBoxAdapter(child: Divider(height: 1, thickness: 0.5)),
        if (day.places.isEmpty)
          SliverToBoxAdapter(child: _emptyDayPlaceholder(dayIndex))
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            sliver: SliverReorderableList(
              itemCount: day.places.length,
              onReorder: (o, n) => _reorderWithinDay(dayIndex, o, n),
              itemBuilder: (context, i) => _buildPlaceCard(
                dayIndex, i, day.places[i], legs,
                isLast: i == day.places.length - 1,
                key: ValueKey('${dayIndex}_${day.places[i].placeId}'),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildPoolContent(ScrollController scrollController) {

    if (_isHydratingPool) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 28, height: 28, child: TravelLoadingIndicator()),
            SizedBox(height: 12),
          ],
        ),
      );
    }
    
  if (_leftovers.isEmpty) {
    return ListView(controller: scrollController, physics: const ClampingScrollPhysics(),
      children: [
        SizedBox(
          height: 260,
          child: Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.explore_off_rounded, size: 56, color: Colors.grey[300]),
              const SizedBox(height: 12),
              Text('No extra places found nearby',
                  style: TextStyle(fontSize: 15, color: Colors.grey[400])),
              const SizedBox(height: 6),
              Text('Every candidate we found made it into your trip',
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  textAlign: TextAlign.center),
            ]),
          ),
        ),
      ],
    );
  }

  final byType = <String, List<PlaceModel>>{};
  for (final p in _leftovers) {
    final label = _typeLabel(p.primaryType ?? 'other');   // 🔧 先转成显示文字
    byType.putIfAbsent(label, () => []).add(p);           // 🔧 再用这个文字当 key 分组
  }

  return ListView(
    key: const ValueKey('pool_scroll'),
    controller: scrollController,
    physics: const ClampingScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: [
      Row(children: [
        Icon(Icons.info_outline_rounded, size: 13, color: Colors.grey[400]),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            "Places we found but didn't schedule. Long-press and drag one onto a Day tab to add it.",
            style: TextStyle(fontSize: 11, color: Colors.grey[400]),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      for (final entry in byType.entries) ...[
        Text(entry.key,    // 🔧 直接用 entry.key,不要再套 _typeLabel
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E))),
        const SizedBox(height: 8),
        ...entry.value.map(_buildPoolChip),
        const SizedBox(height: 12),
      ],
    ],
  );
}

String _typeLabel(String type) {
  const labels = {
    'restaurant':         '🍜 Food',
    'meal_takeaway':      '🍜 Food',
    'cafe':               '☕ Cafe',
    'bakery':             '🥐 Bakery',
    'tourist_attraction': '🏛️ Historical',
    'shopping_mall':      '🛍️ Shopping',
    'amusement_park':     '🎭 Entertainment',
    'park':               '🌿 Nature',
    'hospital':           '🏥 Medical',
    'university':         '🎓 Education',
    'florist':            '💐 Florist',
  };
  return labels[type] ?? '📍 Other';
}

Widget _buildPoolChip(PlaceModel place) {
  final chip = GestureDetector(
    onTap: () => _openPlaceDetail(place),
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[100]!),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
            blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Icon(Icons.drag_indicator_rounded, size: 16, color: Colors.grey[350]),
        const SizedBox(width: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: place.photoUrl != null
              ? Image.network(place.photoUrl!, width: 40, height: 40, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _photoPlaceholder(size: 40))
              : _photoPlaceholder(size: 40),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E))),
              Row(children: [
                if (place.rating != null) ...[
                  const Icon(Icons.star_rounded, size: 11, color: Colors.orange),
                  const SizedBox(width: 2),
                  Text('${place.rating}', style: const TextStyle(fontSize: 10, color: Colors.orange)),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(place.address ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                ),
              ]),
            ],
          ),
        ),
        Icon(Icons.info_outline_rounded, size: 15, color: Colors.grey[350]),
      ]),
    ),
  );

  return LongPressDraggable<_DragPayload>(
    data: _DragPayload.fromPool(place),
    feedback: Material(color: Colors.transparent,
        child: SizedBox(width: 260, child: Opacity(opacity: 0.9, child: chip))),
    childWhenDragging: Opacity(opacity: 0.3, child: chip),
    child: chip,
  );
}




  Widget _buildDaySummaryBar(int dayIndex, _DayLegs legs) {
    final day = _itinerary.days[dayIndex];
    final visitMin =
        day.places.fold<int>(0, (s, p) => s + p.durationMinutes);
    final color = _dayColors[dayIndex % _dayColors.length];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          _summaryChip(
              Icons.place_rounded, '${day.places.length} stops', color),
          const SizedBox(width: 10),
          _summaryChip(Icons.straighten_rounded,
              '${legs.totalKm.toStringAsFixed(1)} km', Colors.blue),
          const SizedBox(width: 10),
          _summaryChip(
              _travelIcon, '${legs.totalMin} min $_travelLabel', Colors.teal),
          const SizedBox(width: 10),
          _summaryChip(Icons.schedule_rounded,
              '~${(visitMin / 60).toStringAsFixed(1)}h', Colors.orange),
          if (!legs.isReal && day.places.isNotEmpty) ...[
            const SizedBox(width: 10),
            const SizedBox(
              width: 10, height: 10,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Colors.grey),
            ),
            const SizedBox(width: 5),
            Text('refining route...',
                style: TextStyle(fontSize: 10, color: Colors.grey[400])),
          ],
        ]),
      ),
    );
  }

  Widget _summaryChip(IconData icon, String label, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _emptyDayPlaceholder(int dayIndex) {
  return DragTarget<_DragPayload>(
    onWillAccept: (payload) => payload != null,
    onAccept: (payload) => _movePlaceToPosition(payload, dayIndex, 0),
    builder: (context, candidateData, rejectedData) {
      final isHovering = candidateData.isNotEmpty;
      final color = _dayColors[dayIndex % _dayColors.length];
      return SizedBox(
        height: 260,
        child: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.playlist_remove_rounded, size: 56,
                color: isHovering ? color : Colors.grey[300]),
            const SizedBox(height: 12),
            Text('No stops on Day ${dayIndex + 1} yet',
                style: TextStyle(fontSize: 15, color: Colors.grey[400])),
            const SizedBox(height: 6),
            Text('Drag a place here from Overview or More Places to add it',
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                textAlign: TextAlign.center),
          ]),
        ),
      );
    },
  );
}

  // ── Place card ─────────────────────────────

  Widget _buildPlaceCard(
    int dayIndex,
    int index,
    ItineraryPlace place,
    _DayLegs legs, {
    required bool isLast,
    required Key key,
  }) {
    final dayColor = _dayColors[dayIndex % _dayColors.length];
    final numColor = _stopColor(
        index, _itinerary.days[dayIndex].places.length, dayColor);

    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDelayedDragStartListener(
            index: index,
            child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey[100]!),
              boxShadow: [BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 3))],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 40, height: 76,
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.drag_indicator_rounded,
                          color: Colors.grey[400], size: 20),
                    ],
                  ),
                ),
                Container(
                  width: 28, height: 28,
                  decoration:
                      BoxDecoration(color: numColor, shape: BoxShape.circle),
                  child: Center(
                    child: Text('${index + 1}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: place.photoUrl != null
                      ? Image.network(place.photoUrl!,
                          width: 52, height: 52, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _photoPlaceholder())
                      : _photoPlaceholder(),
                ),
                const SizedBox(width: 10),
               Expanded(
                child: GestureDetector(   // 🆕 点击看详情
                  onTap: () => _openPlaceDetailFromItinerary(place),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(place.name,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A1A2E)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 3),
                        Text(place.address,
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey[500]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                       Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          GestureDetector(
                            onTap: () => _pickTime(dayIndex, index, place),
                            child: Container(/* 时间chip 原样保留 */),
                          ),
                          GestureDetector(
                            onTap: () => _pickDuration(dayIndex, index, place),
                            child: Container(/* 时长chip 原样保留 */),
                          ),
                        ],
                      ),
                      ],
                    ),
                  ),
                ),
                ),
                GestureDetector(   // 🆕 换一个
                  onTap: () => _showSwapSheet(dayIndex, index, place),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: Colors.blue[50], shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.swap_horiz_rounded,
                          size: 16, color: Colors.blue[400]),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => _removePlace(dayIndex, index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                          color: Colors.red[50], shape: BoxShape.circle),
                      child: Icon(Icons.close_rounded,
                          size: 16, color: Colors.red[400]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ),
          if (!isLast) _buildLegConnector(legs, index + 1),
        ],
      ),
    );
  }

  String _formatDuration(int mins) {
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}min';
  }

  Widget _buildLegConnector(_DayLegs legs, int toIndex) {
    if (toIndex >= legs.distances.length) return const SizedBox.shrink();
    final km  = (legs.distances[toIndex] / 1000).toStringAsFixed(1);
    final min = legs.minutes[toIndex];

    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 6),
      child: Row(children: [
        Column(children: List.generate(4, (_) => Container(
          width: 2, height: 5,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: Colors.blue[200],
            borderRadius: BorderRadius.circular(1),
          ),
        ))),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.blue[50],
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.blue[100]!),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_travelIcon, size: 11, color: Colors.blue[600]),
            const SizedBox(width: 4),
            Text('$km km · $min min',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue[700],
                    fontWeight: FontWeight.w500)),
          ]),
        ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // Bottom bar
  // ─────────────────────────────────────────────

  Widget _buildBottomBar() {
    final totalPlaces = _itinerary.totalPlaces;
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, 10 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(0, -3))],
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF7C4DFF).withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: const Color(0xFF7C4DFF).withOpacity(0.2)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$totalPlaces',
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF7C4DFF))),
            const Text('stops',
                style: TextStyle(fontSize: 10, color: Color(0xFF7C4DFF))),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: (totalPlaces == 0 || _isSaving)
                  ? null
                  : _saveAndContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C4DFF),
                disabledBackgroundColor: Colors.grey[300],
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_circle_rounded,
                            color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Text(
                            widget.isEditingExisting
                                ? 'Save Changes'
                                : 'Confirm Itinerary',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        Icon(Icons.arrow_forward_rounded,
                            color: Colors.white70, size: 16),
                      ],
                    ),
            ),
          ),
        ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────

  // ─────────────────────────────────────────────
  // Leftover pool — view details & swap
  // ─────────────────────────────────────────────

  double _distSqStatic(double lat1, double lng1, double lat2, double lng2) {
    final dlat = lat1 - lat2;
    final dlng = lng1 - lng2;
    return dlat * dlat + dlng * dlng;
  }

  // 🆕 用 ItineraryPlace 打开详情页（行程里已经排好的地点）
  void _openPlaceDetailFromItinerary(ItineraryPlace place) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlaceDetailPage(
        placeId:   place.placeId,
        placeName: place.name,
        lat:       place.lat,
        lng:       place.lng,
        userLat:   widget.startLat,
        userLng:   widget.startLng,
        source:    'google',
      ),
    ));
  }

  // 🆕 用候补池的 PlaceModel 打开详情页
  void _openPlaceDetail(PlaceModel place) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlaceDetailPage(
        placeId:   place.id,
        placeName: place.name,
        lat:       place.lat,
        lng:       place.lng,
        userLat:   widget.startLat,
        userLng:   widget.startLng,
        source:    'google',
      ),
    ));
  }

  // 🆕 把候补池里的 PlaceModel，换装成能放进行程的 ItineraryPlace，
  // 时间段/停留时长沿用被替换掉那个地点的设定，只换地点本身。
  ItineraryPlace _placeModelToItineraryPlace(
    PlaceModel p, {
    required String suggestedTime,
    required int durationMinutes,
  }) {
    return ItineraryPlace(
      placeId:         p.id,
      name:            p.name,
      address:         p.address ?? '',
      photoUrl:        p.photoUrl,
      lat:             p.lat,
      lng:             p.lng,
      primaryType:     p.primaryType,
      suggestedTime:   suggestedTime,
      durationMinutes: durationMinutes,
    );
  }

  // 🆕 用候补池里的某个地点，替换某天某个位置原本的地点。
  // 被替换下来的原地点会重新放回候补池，避免用户换来换去丢失选项。
  void _swapPlace(int dayIndex, int placeIndex, PlaceModel replacement) {
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    final old    = places[placeIndex];

    places[placeIndex] = _placeModelToItineraryPlace(
      replacement,
      suggestedTime:   old.suggestedTime,
      durationMinutes: old.durationMinutes,
    );
    days[dayIndex] = days[dayIndex].copyWith(places: places);

    setState(() {
      _itinerary = _itinerary.copyWith(days: days);
      _leftovers.removeWhere((p) => p.id == replacement.id);
      if (old.lat != null && old.lng != null &&
          !_leftovers.any((p) => p.id == old.placeId)) {
        _leftovers.add(PlaceModel(
          id: old.placeId,
          name: old.name,
          address: old.address,
          lat: old.lat,
          lng: old.lng,
          photoUrl: old.photoUrl,
          source: 'google',
          primaryType: old.primaryType,
          allTypes: old.primaryType != null ? [old.primaryType!] : const [],
        ));
      }
    });

    _invalidateLegs(dayIndex);
    _updateMapOverlays();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Swapped to ${replacement.name}',
            style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: const Color(0xFF1A1A2E),
      ),
    );
  }

  // 🆕 弹出候补名单——只显示跟当前地点同类型的候选，按离当前地点的距离排序
  void _showSwapSheet(int dayIndex, int placeIndex, ItineraryPlace current) {
    final candidates = _leftovers
        .where((p) => p.primaryType == current.primaryType)
        .toList()
      ..sort((a, b) {
        if (current.lat == null || current.lng == null) return 0;
        final da = (a.lat != null && a.lng != null)
            ? _distSqStatic(a.lat!, a.lng!, current.lat!, current.lng!)
            : double.infinity;
        final db = (b.lat != null && b.lng != null)
            ? _distSqStatic(b.lat!, b.lng!, current.lat!, current.lng!)
            : double.infinity;
        return da.compareTo(db);
      });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(context).size.height * 0.6,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Swap this place',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  Text('${candidates.length} options',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: candidates.isEmpty
                  ? Center(
                      child: Text('No alternatives found for this category',
                          style: TextStyle(color: Colors.grey[400])),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: candidates.length,
                      itemBuilder: (_, i) {
                        final c = candidates[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: c.photoUrl != null
                                ? Image.network(c.photoUrl!,
                                    width: 52, height: 52, fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => _photoPlaceholder())
                                : _photoPlaceholder(),
                          ),
                          title: Text(c.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          subtitle: Row(children: [
                            if (c.rating != null) ...[
                              const Icon(Icons.star_rounded, size: 13, color: Colors.orange),
                              const SizedBox(width: 2),
                              Text('${c.rating}',
                                  style: const TextStyle(fontSize: 12, color: Colors.orange)),
                            ],
                          ]),
                          trailing: IconButton(
                            icon: const Icon(Icons.info_outline_rounded, size: 20),
                            onPressed: () => _openPlaceDetail(c),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _swapPlace(dayIndex, placeIndex, c);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }


  Color _stopColor(int index, int total, Color base) {
    if (total <= 1) return base;
    final light = Color.lerp(base, Colors.white, 0.55)!;
    final t = index / (total - 1);
    return Color.lerp(base, light, t)!;
  }

  Widget _photoPlaceholder({double size = 52}) => Container(
    width: size, height: size,
    color: Colors.grey[100],
    child: Icon(Icons.location_on_rounded,
        color: Colors.grey[300], size: size * 0.46),
  );
}

// ─────────────────────────────────────────────
// Support classes
// ─────────────────────────────────────────────

class _DayLegs {
  final List<double> distances;
  final List<int> minutes;
  final List<List<LatLng>> segments;
  final double totalKm;
  final int totalMin;
  final bool isReal;

  const _DayLegs({
    required this.distances,
    required this.minutes,
    required this.segments,
    required this.totalKm,
    required this.totalMin,
    required this.isReal,
  });

  static const empty = _DayLegs(
    distances: [], minutes: [], segments: [],
    totalKm: 0, totalMin: 0, isReal: false,
  );

  // 🆕 转成能存进 Firestore 的纯 JSON 结构
  List<Map<String, dynamic>> toStoredData() {
    return List.generate(distances.length, (i) => {
      'distance': distances[i],
      'minutes':  minutes[i],
      'points': (i < segments.length ? segments[i] : <LatLng>[])
          .map((p) => {'lat': p.latitude, 'lng': p.longitude})
          .toList(),
    });
  }

  // 🆕 从存储结构还原
  static _DayLegs fromStoredData(List<Map<String, dynamic>> data) {
    final distances = <double>[];
    final minutes   = <int>[];
    final segments  = <List<LatLng>>[];
    double totalM = 0;

    for (final leg in data) {
      final d = (leg['distance'] as num).toDouble();
      final m = (leg['minutes'] as num).toInt();
      final pts = (leg['points'] as List<dynamic>? ?? [])
          .map((p) => LatLng(
              (p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()))
          .toList();
      distances.add(d);
      minutes.add(m);
      segments.add(pts);
      totalM += d;
    }

    return _DayLegs(
      distances: distances,
      minutes:   minutes,
      segments:  segments,
      totalKm:   totalM / 1000,
      totalMin:  minutes.fold(0, (a, b) => a + b),
      isReal:    true, // 存下来的必然是当初已经算好的真实数据
    );
  }
}

// A unified drag payload: either an existing itinerary stop being moved
// (dayIndex/placeIndex/place all set), or a place from the leftover pool
// being added as a brand-new stop (poolPlace set, dayIndex/placeIndex null).
class _DragPayload {
  final int? dayIndex;
  final int? placeIndex;
  final ItineraryPlace? place;
  final PlaceModel? poolPlace;

  const _DragPayload.fromDay({
    required int dayIndex,
    required int placeIndex,
    required ItineraryPlace place,
  })  : dayIndex = dayIndex,
        placeIndex = placeIndex,
        place = place,
        poolPlace = null;

  const _DragPayload.fromPool(PlaceModel poolPlace)
      : dayIndex = null,
        placeIndex = null,
        place = null,
        poolPlace = poolPlace;

  bool get isFromPool => poolPlace != null;
}

class _LegPair {
  final double fromLat;
  final double fromLng;
  final double toLat;
  final double toLng;
  final bool skip; // true for day>0's first leg — no known real start point

  const _LegPair({
    required this.fromLat,
    required this.fromLng,
    required this.toLat,
    required this.toLng,
    required this.skip,
  });
}

class _LegResult {
  final double distance;
  final int minutes;
  final List<LatLng> points;

  const _LegResult({
    required this.distance,
    required this.minutes,
    required this.points,
  });
}