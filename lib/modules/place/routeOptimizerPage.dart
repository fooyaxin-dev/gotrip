//routeOptimizerPage.dart
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gotrip/services/apps_Loading.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';


import '../../models/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../itinerary/itineraryDetail.dart';
import '../../services/route_service.dart';
import '../../models/placeModel.dart';
import '../../services/placesAPI_service.dart';
import 'placeDetailPage.dart';   // 跟 RealTimeDetectPage 用的是同一个相对路径，如果不在同一文件夹，按实际路径调整
import '../../services/connectivity_service.dart';
import '../../services/category_mapper.dart';


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

  // 🆕 legs 缓存改成按天独立的 ValueNotifier —— 某一天的路线数据更新时，
  // 只有真正监听它的 widget（那一天的汇总条 + 地点列表）会重建，
  // 不再触发整页 setState()（地图、header、tab 栏、其他天全部跟着
  // 重建的问题）。
  final Map<int, ValueNotifier<_DayLegs>> _legsNotifiers = {};

  ValueNotifier<_DayLegs> _legsNotifierFor(int dayIndex) {
    return _legsNotifiers.putIfAbsent(
      dayIndex,
      () => ValueNotifier<_DayLegs>(_DayLegs.empty),
    );
  }

  // Map
  GoogleMapController? _mapController;

  // 🆕 markers/polylines 合并成一个 ValueNotifier，地图数据更新时只有
  // GoogleMap 本身重建，不再牵连整个 State。
  final ValueNotifier<_MapOverlayData> _mapOverlayNotifier =
      ValueNotifier<_MapOverlayData>(
          const _MapOverlayData(markers: {}, polylines: {}));

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
  bool _isReOptimizingAll = false;

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
    // Handle + trip header + day tabs + spacing/divider + bottom action bar.
    // Keep all fixed controls inside the sheet even on shorter Android screens.
    const fixedChromeHeight = 24.0 + 66.0 + 62.0 + 9.0 + 1.0 + 76.0;
    return ((fixedChromeHeight + bottomInset) / screenHeight).clamp(0.30, 0.48);
  }

  bool _isDayLocked(int dayIndex) {
    if (dayIndex < 0 ||
        dayIndex >= _itinerary.days.length) {
      return true;
    }

    final day = _itinerary.days[dayIndex];

    return _itinerary.isCompleted ||
        (day.totalCount > 0 && day.isCompleted);
  }

  bool _isDayStarted(int dayIndex) {
    if (dayIndex < 0 || dayIndex >= _itinerary.days.length) return false;
    return _itinerary.days[dayIndex].places.any((place) => place.isVisited);
  }

  bool _isPlaceLocked(int dayIndex, int placeIndex) {
    if (_isDayLocked(dayIndex)) return true;
    final places = _itinerary.days[dayIndex].places;
    return placeIndex < 0 ||
        placeIndex >= places.length ||
        places[placeIndex].isVisited ||
        placeIndex <= _lastVisitedIndex(dayIndex);
  }

  int _lastVisitedIndex(int dayIndex) {
    final places = _itinerary.days[dayIndex].places;
    for (int i = places.length - 1; i >= 0; i--) {
      if (places[i].isVisited) return i;
    }
    return -1;
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
    _improveCrossDayAssignments();
    for (int d = 0; d < _itinerary.days.length; d++) {
      if (!mounted) return;
      if (_itinerary.days[d].places.length >= 2) {
        await _reOptimizeDay(d);
      }
    }
  }

  double _dayCompactnessCost(List<ItineraryPlace> places) {
    if (places.length < 2) return 0;
    var total = 0.0;
    var pairs = 0;
    for (int i = 0; i < places.length - 1; i++) {
      final a = places[i];
      if (a.lat == null || a.lng == null) continue;
      for (int j = i + 1; j < places.length; j++) {
        final b = places[j];
        if (b.lat == null || b.lng == null) continue;
        total += Geolocator.distanceBetween(a.lat!, a.lng!, b.lat!, b.lng!);
        pairs++;
      }
    }
    return pairs == 0 ? 0 : total / pairs;
  }

  bool _improveCrossDayAssignments() {
    if (_itinerary.days.length < 2) return false;
    final days = _itinerary.days
        .map((day) => List<ItineraryPlace>.from(day.places))
        .toList();
    var changed = false;

    bool isRestaurant(ItineraryPlace place) => CategoryMapper.isRestaurant(
          place.primaryType,
          const <String>[],
        );

    for (int pass = 0; pass < 60; pass++) {
      double bestSaving = 0;
      int? bestDayA;
      int? bestIndexA;
      int? bestDayB;
      int? bestIndexB;

      for (int dayA = 0; dayA < days.length - 1; dayA++) {
        if (_isDayLocked(dayA) || _isDayStarted(dayA)) continue;
        for (int dayB = dayA + 1; dayB < days.length; dayB++) {
          if (_isDayLocked(dayB) || _isDayStarted(dayB)) continue;
          final before =
              _dayCompactnessCost(days[dayA]) + _dayCompactnessCost(days[dayB]);

          for (int indexA = 0; indexA < days[dayA].length; indexA++) {
            for (int indexB = 0; indexB < days[dayB].length; indexB++) {
              if (isRestaurant(days[dayA][indexA]) !=
                  isRestaurant(days[dayB][indexB])) {
                continue;
              }
              final placeA = days[dayA][indexA];
              final placeB = days[dayB][indexB];
              days[dayA][indexA] = placeB;
              days[dayB][indexB] = placeA;
              final after = _dayCompactnessCost(days[dayA]) +
                  _dayCompactnessCost(days[dayB]);
              days[dayA][indexA] = placeA;
              days[dayB][indexB] = placeB;

              final saving = before - after;
              if (saving > bestSaving + 1.0) {
                bestSaving = saving;
                bestDayA = dayA;
                bestIndexA = indexA;
                bestDayB = dayB;
                bestIndexB = indexB;
              }
            }
          }
        }
      }

      if (bestDayA == null || bestDayB == null) break;
      final indexA = bestIndexA!;
      final indexB = bestIndexB!;
      final placeA = days[bestDayA][indexA];
      days[bestDayA][indexA] = days[bestDayB][indexB];
      days[bestDayB][indexB] = placeA;
      changed = true;
    }

    if (!changed) return false;
    final updatedDays = List<ItineraryDay>.generate(
      _itinerary.days.length,
      (i) => _itinerary.days[i].copyWith(
        places: days[i],
        clearLegs: true,
      ),
    );
    _itinerary = _itinerary.copyWith(days: updatedDays);
    for (int i = 0; i < updatedDays.length; i++) {
      _invalidateLegs(i);
    }
    _updateMapOverlays();
    return true;
  }

  Future<void> _reOptimizeAllDays() async {
    if (_isReOptimizingAll) return;
    setState(() => _isReOptimizingAll = true);
    try {
      _improveCrossDayAssignments();
      if (mounted) setState(() {});
      for (int day = 0; day < _itinerary.days.length; day++) {
        if (!mounted) return;
        await _reOptimizeDay(day);
      }
    } finally {
      if (mounted) setState(() => _isReOptimizingAll = false);
    }
  }

  @override
  void dispose() {
    _mapController?.dispose();
    _sheetController.dispose();
    _sheetExtentNotifier.dispose();
    _mapOverlayNotifier.dispose();   
    for (final notifier in _legsNotifiers.values) {
      notifier.dispose();
    }
    _paddingDebounce?.cancel();
    for (final t in _legsFetchDebounce.values) {
      t.cancel();
    } 
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
  final Map<int, Timer> _legsFetchDebounce = {};

  static const _legsFetchDebounceDuration = Duration(milliseconds: 400);

  void _scheduleFetchRealLegs(int dayIndex) {
    _legsFetchDebounce[dayIndex]?.cancel();
    _legsFetchDebounce[dayIndex] = Timer(_legsFetchDebounceDuration, () {
      _legsFetchDebounce.remove(dayIndex);
      if (mounted) _fetchRealLegsForDay(dayIndex);
    });
  }

  _DayLegs _legsFor(int dayIndex) {
    if (dayIndex < 0 || dayIndex >= _itinerary.days.length) {
      return _DayLegs.empty;
    }

    final notifier = _legsNotifierFor(dayIndex);
    if (!identical(notifier.value, _DayLegs.empty)) return notifier.value;

    final day = _itinerary.days[dayIndex];
    final currentSignature = _computeLegsSignature(dayIndex);
    if (day.legsSignature != null &&
        day.legsSignature == currentSignature &&
        day.legsData != null) {
      final hydrated = _DayLegs.fromStoredData(day.legsData!);
      notifier.value = hydrated;
      return hydrated;
    }

    final fallback = _computeStraightLegsForDay(dayIndex);
    notifier.value = fallback;
    _scheduleFetchRealLegs(dayIndex); 
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

    final newLegs = _DayLegs(
      distances: distances,
      minutes:   minutes,
      segments:  segments,
      totalKm:   totalM / 1000,
      totalMin:  minutes.fold(0, (a, b) => a + b),
      isReal:    true,
    );

    // 🔧 CHANGED: 不再用 setState —— 只更新这一天的 legs notifier，
    // 只有监听它的汇总条/地点列表会重建。
    _legsNotifierFor(dayIndex).value = newLegs;

    // legsSignature/legsData 只在 _legsFor() 的缓存命中分支和保存行程
    // 时会被读取，不影响任何已渲染的 UI，所以直接赋值即可，不用 setState。
    final days = List<ItineraryDay>.from(_itinerary.days);
    days[dayIndex] = days[dayIndex].copyWith(
      legsSignature: _computeLegsSignature(dayIndex),
      legsData: newLegs.toStoredData(),
    );
    _itinerary = _itinerary.copyWith(days: days);

    _updateMapOverlays();
  }

  void _invalidateLegs(int dayIndex) {
    // 重置回 empty，_legsFor() 下次调用会正确检测到"需要重算"，
    // 同时正在监听这个 notifier 的 UI 会立刻收到"变回估算态"的通知。
    _legsNotifierFor(dayIndex).value = _DayLegs.empty;

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
    _mapOverlayNotifier.value =
        _MapOverlayData(markers: newMarkers, polylines: newPolylines);
    _fitCamera(allPoints);   // _updateDayOverlays 里保持 _fitCamera(points)
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

      if (!mounted) return;                                    // 🔧 加回来
      _mapOverlayNotifier.value =                               // 🔧 加回来
          _MapOverlayData(markers: newMarkers, polylines: newPolylines);
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
    if (_selectedIndex == index) {
      return;
    }

    setState(() {
      _selectedIndex = index;
    });

    _updateMapOverlays();

    if (index == _poolTabIndex &&
        !_poolHydrated &&
        !_isHydratingPool) {
      _hydrateLeftoverPool();
    }
  }

  // 🆕 把 _pendingLeftoverIds 逐个补全成 PlaceModel。
  // 单个 id 失败（place 下架/无效）不影响其他的，直接跳过。
  Future<void> _hydrateLeftoverPool() async {
    if (_pendingLeftoverIds.isEmpty) {
      if (mounted) {
        setState(() {
          _poolHydrated = true;
          _isHydratingPool = false;
        });
      }
      return;
    }

    if (!mounted) return;

    setState(() {
      _isHydratingPool = true;
    });

    // Work from a snapshot so the source list cannot
    // change while the async requests are running.
    final idsToHydrate =
        List<String>.from(_pendingLeftoverIds);

    final successfulPlaces = <PlaceModel>[];
    final failedIds = <String>[];

    await Future.wait(
      idsToHydrate.map((id) async {
        try {
          final place =
              await PlacesApiService.getPlaceModelDetails(
            id,
          );

          successfulPlaces.add(place);
        } catch (e) {
          // IMPORTANT:
          // A temporary API/network/cache failure must NOT
          // permanently remove this candidate from the pool.
          failedIds.add(id);

          debugPrint(
            '⚠️ Failed to hydrate leftover place '
            '$id: $e',
          );
        }
      }),
    );

    if (!mounted) return;

    setState(() {
      // Add successful candidates without duplicates.
      final existingIds =
          _leftovers.map((p) => p.id).toSet();

      for (final place in successfulPlaces) {
        if (existingIds.add(place.id)) {
          _leftovers.add(place);
        }
      }

      // Keep ONLY failed IDs pending.
      //
      // They remain stored and can be retried later.
      _pendingLeftoverIds = failedIds;

      _isHydratingPool = false;

      // Fully hydrated only when nothing remains unresolved.
      _poolHydrated = _pendingLeftoverIds.isEmpty;
    });

    debugPrint(
      '✅ Leftover hydration: '
      '${successfulPlaces.length} loaded, '
      '${failedIds.length} pending retry',
    );
  }

  // ─────────────────────────────────────────────
  // Reorder / Remove / Undo / Re-optimize (within a day)
  // ─────────────────────────────────────────────

  void _reorderWithinDay(
    int dayIndex,
    int oldIndex,
    int newIndex,
  ) {
    if (_isDayLocked(dayIndex)) {
      return;
    }

    final currentPlaces = _itinerary.days[dayIndex].places;
    if (oldIndex < 0 ||
        oldIndex >= currentPlaces.length ||
        currentPlaces[oldIndex].isVisited) {
      return;
    }

    if (newIndex > oldIndex) {
      newIndex--;
    }

    // Future stops may be reordered, but never across the visited history.
    if (newIndex <= _lastVisitedIndex(dayIndex)) return;

    final days =
        List<ItineraryDay>.from(
      _itinerary.days,
    );

    final places =
        List<ItineraryPlace>.from(
      days[dayIndex].places,
    );

    final item =
        places.removeAt(oldIndex);

    places.insert(
      newIndex,
      item,
    );

    days[dayIndex] =
        days[dayIndex].copyWith(
      places: places,
    );

    setState(() {
      _itinerary =
          _itinerary.copyWith(
        days: days,
      );
    });

    _invalidateLegs(dayIndex);
    _updateMapOverlays();
  }

  void _removePlace(int dayIndex, int placeIndex) {

    if (_isPlaceLocked(dayIndex, placeIndex)) {
      return;
    }

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

    // Historical/visited stops are immutable. Re-optimizing a partially
    // travelled day could change their order, so only untouched days enter
    // the automatic solver; future stops remain manually editable.
    if (_isDayLocked(dayIndex) || _isDayStarted(dayIndex)) {
      return;
    }

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

      // Route optimization has two levels:
      //   1. preserve sensible meal slots;
      //   2. choose the nearest candidate that matches the current slot.
      //
      // A completely unconstrained nearest-neighbour pass can put two nearby
      // restaurants next to each other and destroy the itinerary's meal
      // pattern. Food-only days remain all-Food naturally.
      final placeOffset = hasStart ? 1 : 0;
      final remaining = List<int>.generate(
        geoPlaces.length,
        (i) => i + placeOffset,
      );
      final order = <int>[];
      final restaurantCount = geoPlaces.where((place) {
        return CategoryMapper.isRestaurant(
          place.primaryType,
          const <String>[],
        );
      }).length;
      final mealPattern = _buildMealSlotPattern(
        geoPlaces.length,
        restaurantCount,
      );

      bool isRestaurantPoint(int pointIndex) {
        final place = geoPlaces[pointIndex - placeOffset];
        return CategoryMapper.isRestaurant(
          place.primaryType,
          const <String>[],
        );
      }

      int? currentPoint = hasStart ? 0 : null;
      for (int slot = 0; slot < mealPattern.length; slot++) {
        final desiredRestaurant = mealPattern[slot];
        var eligible = remaining
            .where((idx) => isRestaurantPoint(idx) == desiredRestaurant)
            .toList();

        // Defensive fallback for incomplete/misclassified place data.
        if (eligible.isEmpty) eligible = List<int>.from(remaining);

        int selected;
        if (currentPoint != null) {
          selected = eligible.reduce((best, candidate) {
            return distBetween(currentPoint!, candidate) <
                    distBetween(currentPoint!, best)
                ? candidate
                : best;
          });
        } else {
          // Later days have no user origin. Start at the most central candidate
          // of the required type instead of arbitrarily fixing list index 0.
          selected = eligible.reduce((best, candidate) {
            final candidateTotal = remaining
                .where((idx) => idx != candidate)
                .fold<double>(0, (sum, idx) => sum + distBetween(candidate, idx));
            final bestTotal = remaining
                .where((idx) => idx != best)
                .fold<double>(0, (sum, idx) => sum + distBetween(best, idx));
            return candidateTotal < bestTotal ? candidate : best;
          });
        }

        order.add(selected);
        remaining.remove(selected);
        currentPoint = selected;
      }

      final slotMinutes = geoPlaces
          .map((p) => _parseTimeToMinutes(p.suggestedTime))
          .toList()
        ..sort();
      final optimizedOrder = _improveRouteOrder(
        order,
        distance: distBetween,
        isRestaurantPoint: isRestaurantPoint,
        slotMinutes: slotMinutes,
        startPoint: hasStart ? 0 : null,
      );

      final reordered = optimizedOrder
          .map((idx) => geoPlaces[idx - placeOffset])
          .toList();

      // Preserve the day's existing chronological slots. Sequentially adding
      // only visit duration used to collapse lunch/dinner gaps after a route
      // reorder, which is another way restaurants became grouped together.
      final retimed = List<ItineraryPlace>.generate(
        reordered.length,
        (i) => reordered[i].copyWith(
          suggestedTime: _minutesToTimeString(slotMinutes[i]),
        ),
      );

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

  List<int> _improveRouteOrder(
    List<int> initial, {
    required double Function(int, int) distance,
    required bool Function(int) isRestaurantPoint,
    required List<int> slotMinutes,
    int? startPoint,
  }) {
    if (initial.length < 2) return List<int>.from(initial);
    final restaurantCount = initial.where(isRestaurantPoint).length;
    final allRestaurants = restaurantCount == initial.length;

    int minutesOutsideMealWindows(int minute) {
      const windows = <(int, int)>[
        (11 * 60, 14 * 60),
        (17 * 60 + 30, 20 * 60 + 30),
      ];
      var nearest = 24 * 60;
      for (final window in windows) {
        if (minute >= window.$1 && minute <= window.$2) return 0;
        final delta = minute < window.$1
            ? window.$1 - minute
            : minute - window.$2;
        if (delta < nearest) nearest = delta;
      }
      return nearest;
    }

    double objective(List<int> route) {
      var cost = 0.0;
      if (startPoint != null) cost += distance(startPoint, route.first);
      for (int i = 1; i < route.length; i++) {
        cost += distance(route[i - 1], route[i]);
      }

      if (!allRestaurants) {
        for (int i = 0; i < route.length && i < slotMinutes.length; i++) {
          if (isRestaurantPoint(route[i])) {
            // Soft time-window cost: distance can override it when necessary,
            // but lunch/dinner placement is normally preferred.
            cost += minutesOutsideMealWindows(slotMinutes[i]) * 35.0;
            if (i > 0 && isRestaurantPoint(route[i - 1])) cost += 4000.0;
          }
        }
      }
      return cost;
    }

    var best = List<int>.from(initial);
    var bestCost = objective(best);

    // Swap, relocate and 2-opt neighbourhoods. This evaluates the
    // whole route cost rather than greedily selecting only the next stop.
    for (int pass = 0; pass < 80; pass++) {
      List<int>? bestCandidate;
      var candidateCost = bestCost;

      for (int i = 0; i < best.length - 1; i++) {
        for (int j = i + 1; j < best.length; j++) {
          final swapped = List<int>.from(best);
          final temp = swapped[i];
          swapped[i] = swapped[j];
          swapped[j] = temp;
          final swapCost = objective(swapped);
          if (swapCost + 1.0 < candidateCost) {
            candidateCost = swapCost;
            bestCandidate = swapped;
          }

          final relocated = List<int>.from(best);
          final moved = relocated.removeAt(i);
          relocated.insert(j, moved);
          final relocateCost = objective(relocated);
          if (relocateCost + 1.0 < candidateCost) {
            candidateCost = relocateCost;
            bestCandidate = relocated;
          }

          final relocatedBack = List<int>.from(best);
          final movedBack = relocatedBack.removeAt(j);
          relocatedBack.insert(i, movedBack);
          final relocateBackCost = objective(relocatedBack);
          if (relocateBackCost + 1.0 < candidateCost) {
            candidateCost = relocateBackCost;
            bestCandidate = relocatedBack;
          }

          final reversed = <int>[
            ...best.take(i),
            ...best.sublist(i, j + 1).reversed,
            ...best.skip(j + 1),
          ];
          final reverseCost = objective(reversed);
          if (reverseCost + 1.0 < candidateCost) {
            candidateCost = reverseCost;
            bestCandidate = reversed;
          }
        }
      }

      if (bestCandidate == null) break;
      best = bestCandidate;
      bestCost = candidateCost;
    }

    return best;
  }

  List<bool> _buildMealSlotPattern(int totalStops, int restaurantCount) {
    if (totalStops <= 0 || restaurantCount <= 0) {
      return List<bool>.filled(totalStops, false);
    }
    if (restaurantCount >= totalStops) {
      return List<bool>.filled(totalStops, true);
    }

    final preferredRestaurantSlots = switch (totalStops) {
      1 => <int>[],
      2 => <int>[1],
      3 => <int>[1],
      4 => <int>[1, 3],
      5 => <int>[1, 3],
      _ => <int>[2, 4],
    };

    final selectedSlots = <int>{};
    for (final slot in preferredRestaurantSlots) {
      if (selectedSlots.length >= restaurantCount) break;
      if (slot < totalStops) selectedSlots.add(slot);
    }

    // Normally mixed itineraries need at most two restaurant slots. This
    // fallback still preserves every restaurant if older saved data contains
    // more, while spreading the extra Food stops as evenly as possible.
    while (selectedSlots.length < restaurantCount) {
      int? bestSlot;
      double bestSeparation = -1;
      for (int slot = 0; slot < totalStops; slot++) {
        if (selectedSlots.contains(slot)) continue;
        final separation = selectedSlots.isEmpty
            ? totalStops.toDouble()
            : selectedSlots
                .map((used) => (slot - used).abs().toDouble())
                .reduce((a, b) => a < b ? a : b);
        if (separation > bestSeparation) {
          bestSeparation = separation;
          bestSlot = slot;
        }
      }
      if (bestSlot == null) break;
      selectedSlots.add(bestSlot);
    }

    return List<bool>.generate(
      totalStops,
      selectedSlots.contains,
    );
  }

  // 晚上 22:00 之后才结束/开始，视为需要提醒用户"太晚了"
  static const int _lateNightThresholdMinutes = 22 * 60;

  /// 把"从0点算起的分钟数"转回 "HH:mm" 字符串。
  /// clamp 到 23:59，避免顺延不小心跨到隔天却毫无提示地悄悄变成"明天的
  /// 时间"——跨天这种情况应该由 hasLateWarning 提示用户，而不是被默默吞掉。
  String _minutesToTimeString(int minutes) {
    final clamped = minutes.clamp(0, 23 * 60 + 59);
    final hh = (clamped ~/ 60).toString().padLeft(2, '0');
    final mm = (clamped % 60).toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// 单点改动后的共用游标累加逻辑。整天 route optimization 会保留
  /// 原有 meal slots，所以不使用这个 sequential retiming helper。
  ///
  /// [legsMinutes]（若提供）：legsMinutes[i] = 上一站到 places[i] 的通勤
  /// 分钟数，跟 _legsFor(dayIndex) 返回的 legs.minutes 对齐。
  /// [skipFirstLegTravel]：true = 传入列表的第一项不加交通时间；
  /// false = 第一项也要加（用于"级联顺延"，因为这个"第一项"其实是被改
  /// 动地点后面的下一站，中间确实有一段真实交通时间要算进去）。
  List<ItineraryPlace> _assignSequentialTimes(
    List<ItineraryPlace> places, {
    required int startCursorMinutes,
    List<int>? legsMinutes,
    bool skipFirstLegTravel = true,
  }) {
    var cursor = startCursorMinutes;
    final result = <ItineraryPlace>[];

    for (int i = 0; i < places.length; i++) {
      final applyTravel = legsMinutes != null &&
          i < legsMinutes.length &&
          (i > 0 || !skipFirstLegTravel);
      final travel = applyTravel ? legsMinutes[i] : 0;
      final start = cursor + travel;
      result.add(places[i].copyWith(suggestedTime: _minutesToTimeString(start)));
      cursor = start + places[i].durationMinutes;
    }
    return result;
  }

  /// 从 [placeIndex]（已经套用了新时间/新时长）开始，用真实交通时间
  /// （_legsFor 算出来的，不是瞎猜）依次顺延同一天后续所有地点。
  /// 返回顺延后的 places 列表，以及是否触发了"太晚了"的警告。
  ({List<ItineraryPlace> places, bool hasLateWarning}) _cascadeTimes(
    int dayIndex,
    int placeIndex,
    List<ItineraryPlace> places,
  ) {
    final legs = _legsFor(dayIndex);
    final editedEnd = _parseTimeToMinutes(places[placeIndex].suggestedTime) +
        places[placeIndex].durationMinutes;

    final tailStart = placeIndex + 1;
    if (tailStart >= places.length) {
      // 被改的是当天最后一站，没有后续地点要顺延
      return (
        places: places,
        hasLateWarning: editedEnd >= _lateNightThresholdMinutes,
      );
    }

    final tail = places.sublist(tailStart);
    final tailLegsMinutes =
        tailStart < legs.minutes.length ? legs.minutes.sublist(tailStart) : null;

    final retimedTail = _assignSequentialTimes(
      tail,
      startCursorMinutes: editedEnd,
      legsMinutes: tailLegsMinutes,
      skipFirstLegTravel: false, // tail 第一站要算跟被改地点之间的交通时间
    );

    final updated = [...places.sublist(0, tailStart), ...retimedTail];

    final hasLateWarning = updated.sublist(placeIndex).any((p) {
      final end = _parseTimeToMinutes(p.suggestedTime) + p.durationMinutes;
      return end >= _lateNightThresholdMinutes;
    });

    return (places: updated, hasLateWarning: hasLateWarning);
  }

  /// 校验用户手动选的新开始时间，是否留了足够的交通时间从上一站赶过来。
  /// 只在用户改「开始时间」时检查（改时长不影响这个校验）。
  String? _checkArrivalFeasibility(
    int dayIndex,
    int placeIndex,
    List<ItineraryPlace> places,
    String newStartTime,
  ) {
    if (placeIndex == 0) return null; // 当天第一站，没有"上一站"可比较

    final legs = _legsFor(dayIndex);
    final travelMinutes =
        placeIndex < legs.minutes.length ? legs.minutes[placeIndex] : 0;

    final prevPlace = places[placeIndex - 1];
    final prevEnd = _parseTimeToMinutes(prevPlace.suggestedTime) +
        prevPlace.durationMinutes;
    final earliestFeasible = prevEnd + travelMinutes;
    final chosenStart = _parseTimeToMinutes(newStartTime);

    if (chosenStart < earliestFeasible) {
      final shortBy = earliestFeasible - chosenStart;
      return 'Only ${chosenStart - prevEnd} min available to travel from '
          '"${prevPlace.name}", but it takes about $travelMinutes min. '
          'You may arrive $shortBy min late.';
    }
    return null;
  }

  /// 统一入口：套用一次时间/时长改动 → 视情况校验交通可行性 → 级联顺延
  /// 后续地点 → 视情况提醒"太晚了" → 用户确认后才真正写入 _itinerary。
  /// 用户在任一警告弹窗里选择取消，这次编辑会被完整放弃，不留半改状态。
  Future<void> _applyTimeChange(
    int dayIndex,
    int placeIndex,
    ItineraryPlace updated, {
    required bool checkArrivalFeasibility,
  }) async {
    if (_isPlaceLocked(dayIndex, placeIndex)) return;
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);

    if (checkArrivalFeasibility) {
      final warning = _checkArrivalFeasibility(
          dayIndex, placeIndex, places, updated.suggestedTime);
      if (warning != null && mounted) {
        final proceed = await _showWarningDialog(
          icon: Icons.directions_walk_rounded,
          title: 'Tight travel time',
          message: warning,
        );
        if (proceed != true) return;
      }
    }

    places[placeIndex] = updated;

    final result = _cascadeTimes(dayIndex, placeIndex, places);

    if (result.hasLateWarning && mounted) {
      final lastPlace = result.places.last;
      final lastEnd = (_parseTimeToMinutes(lastPlace.suggestedTime) +
              lastPlace.durationMinutes)
          .clamp(0, 23 * 60 + 59);
      final endLabel = _minutesToTimeString(lastEnd);

      final proceed = await _showWarningDialog(
        icon: Icons.nightlight_round,
        title: 'This pushes your day quite late',
        message: 'With this change, later stops today will shift later — '
            '"${lastPlace.name}" would now end around $endLabel. Continue?',
      );
      if (proceed != true) return;
    }

    days[dayIndex] = days[dayIndex].copyWith(places: result.places);
    setState(() => _itinerary = _itinerary.copyWith(days: days));
    _invalidateLegs(dayIndex);
  }

  Future<bool?> _showWarningDialog({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Icon(icon, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ]),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C4DFF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Continue', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
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
    _DragPayload payload,
    int targetDayIndex,
    int targetIndex,
  ) {
    // Cannot modify a completed target day.
    if (_isDayLocked(targetDayIndex)) {
      return;
    }

    if (targetIndex <= _lastVisitedIndex(targetDayIndex)) return;

    if (payload.isFromPool) {
      _addPoolPlaceToPosition(
        payload.poolPlace!,
        targetDayIndex,
        targetIndex,
      );
      return;
    }

    final sourceDayIndex =
        payload.dayIndex!;

    final sourcePlaceIndex =
        payload.placeIndex!;

    // Cannot remove/reorder anything from a
    // completed historical day either.
    if (_isDayLocked(sourceDayIndex)) {
      return;
    }

    if (_isPlaceLocked(sourceDayIndex, sourcePlaceIndex)) return;

    if (sourceDayIndex ==
            targetDayIndex &&
        (sourcePlaceIndex ==
                targetIndex ||
            sourcePlaceIndex ==
                targetIndex - 1)) {
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

      if (_isDayLocked(targetDayIndex)) {
        return;
      }
      if (targetIndex <= _lastVisitedIndex(targetDayIndex)) return;

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
      _pendingLeftoverIds.remove(poolPlace.id); // 🔧 用掉了，不该再当候补写回去
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
      if (_isPlaceLocked(dayIndex, placeIndex)) return;
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
        await _applyTimeChange(
          dayIndex, placeIndex,
          place.copyWith(suggestedTime: '$hh:$mm'),
          checkArrivalFeasibility: true, // 改了开始时间 → 要查交通时间够不够
        );
      }
  }

  Future<void> _pickDuration(
      int dayIndex, int placeIndex, ItineraryPlace place) async {
    if (_isPlaceLocked(dayIndex, placeIndex)) return;
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
                    _applyTimeChange(
                      dayIndex, placeIndex,
                      place.copyWith(durationMinutes: selected),
                      checkArrivalFeasibility: false, // 只改时长，没碰开始时间
                    );
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
  final hasAnyPlace =
      _itinerary.days.any((d) => d.places.isNotEmpty);

  // No place to save / already saving.
  if (!hasAnyPlace || _isSaving) {
    return;
  }

  setState(() => _isSaving = true);

  try {
    // ─────────────────────────────────────────────
    // Step 1: Check connectivity
    // ─────────────────────────────────────────────
    final online =
        await ConnectivityService.instance.ensureConnected(
      context,
      onRetry: _saveAndContinue,
    );

    if (!online) {
      return;
    }

    if (!mounted) return;

    // ─────────────────────────────────────────────
    // Step 2: Preserve the COMPLETE leftover pool
    // ─────────────────────────────────────────────
    //
    // _leftovers:
    //   leftover candidates already resolved as PlaceModel
    //
    // _pendingLeftoverIds:
    //   leftover IDs that have not yet been resolved/loaded
    //
    // Combine both and remove duplicates.
    final leftoverIds = <String>{
      ..._leftovers.map((p) => p.id),
      ..._pendingLeftoverIds,
    }.toList();

    _itinerary = _itinerary.copyWith(
      leftoverPlaceIds: leftoverIds,
    );

    // ─────────────────────────────────────────────
    // Step 3: Save / update itinerary
    // ─────────────────────────────────────────────
    String? savedId;

    if (_itinerary.id.isEmpty) {
      savedId =
          await ItineraryService.instance.save(
        _itinerary,
      );
    } else {
      await ItineraryService.instance.update(
        _itinerary,
      );

      savedId = _itinerary.id;
    }

    if (!mounted) return;

    // save() may return null, e.g. user not logged in
    // or Firestore save could not be completed.
    if (savedId == null) {
      final isLoggedIn =
          FirebaseAuth.instance.currentUser != null;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isLoggedIn
                ? 'Failed to save itinerary. Please try again.'
                : 'Please log in to save itinerary.',
          ),
          backgroundColor: Colors.red,
        ),
      );

      return;
    }

    // Rebuild the model using the actual saved document ID.
    final saved = ItineraryModel.fromMap(
      savedId,
      _itinerary.toMap(),
    );

    // ─────────────────────────────────────────────
    // Step 4: Return / navigate
    // ─────────────────────────────────────────────

    if (widget.isEditingExisting) {
      // Existing ItineraryDetailPage is already below
      // RouteOptimizerPage in the navigation stack.
      //
      // Return the updated model instead of opening
      // another duplicate detail page.
      Navigator.pop(
        context,
        saved,
      );
      return;
    }

    // New itinerary:
    // replace RouteOptimizer with its detail page.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ItineraryDetailPage(
          itinerary: saved,
        ),
      ),
      result: true,
    );
  } catch (e) {
    if (!mounted) return;

    debugPrint(
      '❌ RouteOptimizer save failed: $e',
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Unable to save this itinerary. '
          'Please check your connection and try again.',
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  } finally {
    // Always restore the Save button state,
    // whether save succeeds, fails, goes offline,
    // or returns early.
    if (mounted) {
      setState(() {
        _isSaving = false;
      });
    }
  }
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
                  // 🔧 CHANGED: markers/polylines 从独立的 _mapOverlayNotifier
                  // 读取，地图数据更新时只有这一层重建。
                  return ValueListenableBuilder<_MapOverlayData>(
                    valueListenable: _mapOverlayNotifier,
                    builder: (context, overlay, _) {
                      return GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: LatLng(widget.startLat, widget.startLng),
                          zoom: 13,
                        ),
                        markers:   overlay.markers,
                        polylines: overlay.polylines,
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
          if (_selectedIndex != _poolTabIndex &&
              !_itinerary.isCompleted &&
              (_selectedIndex == 0 || !_isDayStarted(_selectedIndex - 1)))
            Builder(builder: (context) {
              final dayIndex = _selectedIndex - 1;
              final isOverview = _selectedIndex == 0;
              final isBusy = isOverview
                  ? _isReOptimizingAll
                  : _reOptimizingDays.contains(dayIndex);
              return GestureDetector(
                onTap: isBusy
                    ? null
                    : isOverview
                        ? _reOptimizeAllDays
                        : () => _reOptimizeDay(dayIndex),
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
                    Text(
                        isBusy
                            ? 'Optimizing...'
                            : isOverview
                                ? 'Optimize All'
                                : 'Re-optimize',
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
    final color = _dayColors[dayIndex % _dayColors.length];

    _legsFor(dayIndex); // 触发一次(需要时)带 debounce 的真实路线请求

    return ValueListenableBuilder<_DayLegs>(
      valueListenable: _legsNotifierFor(dayIndex),
      builder: (context, legs, _) {
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(children: [
                        Container(
                            width: 10, height: 10,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text('Day ${dayIndex + 1} · ${_formatDayDate(day.date)}',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.bold, color: color)),
                        const SizedBox(width: 6),
                        if (day.isCompleted && day.totalCount > 0)
                          const Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
                        const Spacer(),
                        if (_reOptimizingDays.contains(dayIndex))
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: SizedBox(
                              width: 10, height: 10,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey),
                            ),
                          ),
                        Text('${day.places.length} stops · ${legs.totalKm.toStringAsFixed(1)} km',
                            style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right_rounded, size: 16, color: Colors.grey[400]),
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
                            style: TextStyle(fontSize: 12, color: Colors.grey[400])),
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
    final locked = _isPlaceLocked(dayIndex, placeIndex);
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
        Icon(
          locked ? Icons.lock_outline_rounded : Icons.drag_indicator_rounded,
          size: 16,
          color: Colors.grey[350],
        ),
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
                        ? CachedNetworkImage(
            imageUrl: place.photoUrl!,
            width: 36, height: 36, fit: BoxFit.cover,
            errorWidget: (_, __, ___) => _photoPlaceholder(size: 36),
          )
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

    if (locked) return chip;

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
    // 保留"没缓存时触发一次真实路线请求"这个副作用，
    // 但渲染改成监听这一天的 legs notifier。
    _legsFor(dayIndex);

    return ValueListenableBuilder<_DayLegs>(
      valueListenable: _legsNotifierFor(dayIndex),
      builder: (context, legs, _) {
        final day = _itinerary.days[dayIndex];

        return CustomScrollView(
          key: ValueKey('day_scroll_$dayIndex'),
          controller: scrollController,
          physics: const ClampingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildDaySummaryBar(dayIndex, legs)),
            const SliverToBoxAdapter(child: Divider(height: 1, thickness: 0.5)),
            if (day.places.isEmpty)
            SliverToBoxAdapter(
              child: _emptyDayPlaceholder(
                dayIndex,
              ),
            )
          else if (_isDayLocked(dayIndex))
            SliverPadding(
              padding:
                  const EdgeInsets.fromLTRB(
                20,
                12,
                20,
                8,
              ),
              sliver: SliverList(
                delegate:
                    SliverChildBuilderDelegate(
                  (context, i) =>
                      _buildPlaceCard(
                    dayIndex,
                    i,
                    day.places[i],
                    legs,
                    isLast:
                        i ==
                            day.places.length -
                                1,
                    key: ValueKey(
                      '${dayIndex}_${day.places[i].placeId}',
                    ),
                  ),
                  childCount:
                      day.places.length,
                ),
              ),
            )
          else
            SliverPadding(
              padding:
                  const EdgeInsets.fromLTRB(
                20,
                12,
                20,
                8,
              ),
              sliver: SliverReorderableList(
                itemCount:
                    day.places.length,
                onReorder: (o, n) =>
                    _reorderWithinDay(
                  dayIndex,
                  o,
                  n,
                ),
                itemBuilder:
                    (context, i) =>
                        _buildPlaceCard(
                  dayIndex,
                  i,
                  day.places[i],
                  legs,
                  isLast:
                      i ==
                          day.places.length -
                              1,
                  key: ValueKey(
                    '${dayIndex}_${day.places[i].placeId}',
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  Widget _buildPoolContent(ScrollController scrollController) {

    if (_isHydratingPool) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 180, height: 180, child: TravelLoadingIndicator()),
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
    'entertainment':      '🎭 Entertainment',
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
              ? CachedNetworkImage(
              imageUrl: place.photoUrl!,
              width: 40, height: 40, fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _photoPlaceholder(size: 40),
            )
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
  final dayColor =
      _dayColors[dayIndex % _dayColors.length];

  final numColor = _stopColor(
    index,
    _itinerary.days[dayIndex].places.length,
    dayColor,
  );

  final locked = _isPlaceLocked(dayIndex, index);

  final card = Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Colors.grey[100]!,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: Row(
      crossAxisAlignment:
          CrossAxisAlignment.center,
      children: [
        // ─────────────────────────────────────────
        // Drag / Lock indicator
        // ─────────────────────────────────────────
        Container(
          width: 40,
          height: 76,
          color: Colors.transparent,
          child: Column(
            mainAxisAlignment:
                MainAxisAlignment.center,
            children: [
              Icon(
                locked
                    ? Icons.lock_outline_rounded
                    : Icons.drag_indicator_rounded,
                color: Colors.grey[400],
                size: 20,
              ),
            ],
          ),
        ),

        // ─────────────────────────────────────────
        // Stop number
        // ─────────────────────────────────────────
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: numColor,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),

        const SizedBox(width: 10),

        // ─────────────────────────────────────────
        // Image
        // ─────────────────────────────────────────
        ClipRRect(
          borderRadius:
              BorderRadius.circular(10),
          child: place.photoUrl != null
              ? CachedNetworkImage(
                  imageUrl: place.photoUrl!,
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  errorWidget:
                      (_, __, ___) =>
                          _photoPlaceholder(),
                )
              : _photoPlaceholder(),
        ),

        const SizedBox(width: 10),

        // ─────────────────────────────────────────
        // Place info
        // ─────────────────────────────────────────
        Expanded(
          child: GestureDetector(
            // Even locked days can still open
            // the place detail page.
            onTap: () =>
                _openPlaceDetailFromItinerary(
              place,
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(
                vertical: 12,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name,
                    style:
                        const TextStyle(
                      fontSize: 14,
                      fontWeight:
                          FontWeight.bold,
                      color:
                          Color(0xFF1A1A2E),
                    ),
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 3),

                  Text(
                    place.address,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                    ),
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 4),

                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      // ─────────────────────────────
                      // Suggested time
                      // ─────────────────────────────
                      GestureDetector(
                        onTap: locked
                            ? null
                            : () =>
                                _pickTime(
                                  dayIndex,
                                  index,
                                  place,
                                ),
                        child: Container(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration:
                              BoxDecoration(
                            color: locked
                                ? Colors
                                    .grey[100]
                                : const Color(
                                        0xFF7C4DFF)
                                    .withOpacity(
                                        0.08),
                            borderRadius:
                                BorderRadius
                                    .circular(8),
                          ),
                          child: Row(
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              Icon(
                                Icons
                                    .access_time_rounded,
                                size: 11,
                                color: locked
                                    ? Colors
                                        .grey[500]
                                    : const Color(
                                        0xFF7C4DFF),
                              ),
                              const SizedBox(
                                  width: 3),
                              Text(
                                place
                                    .suggestedTime,
                                style:
                                    TextStyle(
                                  fontSize: 10,
                                  color: locked
                                      ? Colors
                                          .grey[600]
                                      : const Color(
                                          0xFF7C4DFF),
                                  fontWeight:
                                      FontWeight
                                          .w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // ─────────────────────────────
                      // Duration
                      // ─────────────────────────────
                      GestureDetector(
                        onTap: locked
                            ? null
                            : () =>
                                _pickDuration(
                                  dayIndex,
                                  index,
                                  place,
                                ),
                        child: Container(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration:
                              BoxDecoration(
                            color: locked
                                ? Colors
                                    .grey[100]
                                : Colors.orange
                                    .withOpacity(
                                        0.08),
                            borderRadius:
                                BorderRadius
                                    .circular(8),
                          ),
                          child: Row(
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              Icon(
                                Icons
                                    .schedule_rounded,
                                size: 11,
                                color: locked
                                    ? Colors
                                        .grey[500]
                                    : Colors
                                        .orange[600],
                              ),
                              const SizedBox(
                                  width: 3),
                              Text(
                                _formatDuration(
                                  place
                                      .durationMinutes,
                                ),
                                style:
                                    TextStyle(
                                  fontSize: 10,
                                  color: locked
                                      ? Colors
                                          .grey[600]
                                      : Colors
                                          .orange[700],
                                  fontWeight:
                                      FontWeight
                                          .w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        // ─────────────────────────────────────────
        // Swap button
        // Only editable days can swap.
        // ─────────────────────────────────────────
        if (!locked)
          GestureDetector(
            onTap: () =>
                _showSwapSheet(
              dayIndex,
              index,
              place,
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 6,
              ),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.swap_horiz_rounded,
                  size: 16,
                  color: Colors.blue[400],
                ),
              ),
            ),
          ),

        // ─────────────────────────────────────────
        // Remove button
        // Only editable days can remove.
        // ─────────────────────────────────────────
        if (!locked)
          GestureDetector(
            onTap: () =>
                _removePlace(
              dayIndex,
              index,
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 12,
              ),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: Colors.red[400],
                ),
              ),
            ),
          ),

        // Keep some right spacing on locked cards,
        // because swap/delete are hidden.
        if (locked)
          const SizedBox(width: 12),
      ],
    ),
  );

  // ─────────────────────────────────────────────
  // Editable day:
  // wrap card with reorder listener.
  //
  // Completed day:
  // plain card only, no drag behavior.
  // ─────────────────────────────────────────────

  final cardContent = locked
      ? card
      : ReorderableDelayedDragStartListener(
          index: index,
          child: card,
        );

  return Container(
    key: key,
    margin:
        const EdgeInsets.only(
      bottom: 14,
    ),
    child: Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        cardContent,

        if (!isLast)
          _buildLegConnector(
            legs,
            index + 1,
          ),
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

    if (_isPlaceLocked(dayIndex, placeIndex)) {
      return;
    }

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
      _pendingLeftoverIds.remove(replacement.id); 
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

  // The leftover pool was built from the categories selected during Generate.
  // Swap may use any of those selected categories, rather than being locked to
  // the current place's category. No additional nearby-search API call is made.
    // The leftover pool was built from the categories selected during Generate.
  // Swap may use any of those selected categories, rather than being locked to
  // the current place's category. No additional nearby-search API call is made.
  void _showSwapSheet(
    int dayIndex,
    int placeIndex,
    ItineraryPlace current,
  ) {
    if (_isPlaceLocked(dayIndex, placeIndex)) return;

    final scheduledIds = _itinerary.days
        .expand((day) => day.places)
        .map((place) => place.placeId)
        .toSet();

    final candidates = _leftovers
        .where((place) {
          final category = CategoryMapper.resolvePrimaryType(
            place.primaryType,
            place.allTypes,
          );
          return !scheduledIds.contains(place.id) &&
              CategoryMapper.isLearnableCategory(category);
        })
        .toList()
      ..sort((a, b) {
        if (current.lat == null || current.lng == null) {
          return (b.rating ?? 0).compareTo(a.rating ?? 0);
        }
        final da = (a.lat != null && a.lng != null)
            ? _distSqStatic(a.lat!, a.lng!, current.lat!, current.lng!)
            : double.infinity;
        final db = (b.lat != null && b.lng != null)
            ? _distSqStatic(b.lat!, b.lng!, current.lat!, current.lng!)
            : double.infinity;
        final distanceOrder = da.compareTo(db);
        if (distanceOrder != 0) return distanceOrder;
        return (b.rating ?? 0).compareTo(a.rating ?? 0);
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
                      child: Text('No alternatives found nearby',
                          style: TextStyle(color: Colors.grey[400])),
                    )
                  : Builder(builder: (_) {
                      // Group while preserving the existing distance/rating
                      // order — candidates is already sorted, and Map
                      // insertion order keeps that ordering within each
                      // category bucket. Grouped by the canonical category
                      // (not the display string) so it lines up with
                      // _typeLabel's key set.
                      final grouped = <String, List<PlaceModel>>{};
                      for (final c in candidates) {
                        final category = CategoryMapper.resolvePrimaryType(
                          c.primaryType,
                          c.allTypes,
                        );
                        grouped.putIfAbsent(category, () => []).add(c);
                      }

                      return ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        children: [
                          for (final entry in grouped.entries) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10, top: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7C4DFF).withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  _typeLabel(entry.key),
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1A1A2E)),
                                ),
                              ),
                            ),
                            ...entry.value.map((c) => ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: c.photoUrl != null
                                        ? CachedNetworkImage(
                                            imageUrl: c.photoUrl!,
                                            width: 52, height: 52, fit: BoxFit.cover,
                                            errorWidget: (_, __, ___) => _photoPlaceholder(),
                                          )
                                        : _photoPlaceholder(),
                                  ),
                                  title: Text(c.name,
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600, fontSize: 14)),
                                  subtitle: c.rating != null
                                      ? Row(children: [
                                          const Icon(Icons.star_rounded,
                                              size: 13, color: Colors.orange),
                                          const SizedBox(width: 2),
                                          Text('${c.rating}',
                                              style: const TextStyle(
                                                  fontSize: 12, color: Colors.orange)),
                                        ])
                                      : null,
                                  trailing: IconButton(
                                    icon: const Icon(Icons.info_outline_rounded, size: 20),
                                    onPressed: () => _openPlaceDetail(c),
                                  ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _swapPlace(dayIndex, placeIndex, c);
                                  },
                                )),
                            const SizedBox(height: 6),
                          ],
                        ],
                      );
                    }),
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

class _MapOverlayData {
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  const _MapOverlayData({required this.markers, required this.polylines});
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
