import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'placeDetailPage.dart';
import '../../services/placesAPI_service.dart';
import '../../services/location_service.dart';
import '../../services/placeModal.dart';
import '../../services/nearbyPlace_service.dart';
import 'guidePage.dart';

// 二级缓存
class _CacheEntry {
  final DateTime ts;
  final List<PlaceModel> places;
  _CacheEntry(this.ts, this.places);
}
enum SortMode { distance, rating }
enum TravelMode { walk, drive, motor }
 

class RealTimeDetectPage extends StatefulWidget {
  final double? landmarkLat;
  final double? landmarkLng;
  final VoidCallback onBack;
  final Map<String, dynamic>? initialNavigation;

    const RealTimeDetectPage({
      super.key, 
      this.landmarkLat, 
      this.landmarkLng, 
      required this.onBack,
      this.initialNavigation, // ✅ 新增
    });

  @override
  State<RealTimeDetectPage> createState() => _RealTimeDetectPageState();
}

class _RealTimeDetectPageState extends State<RealTimeDetectPage> {

  GoogleMapController? _mapController;
  Position? _currentPosition;

  // 当前正在导航的 PlaceModel
  PlaceModel? _currentNavPlace;

  // 当前导航的路线结果
  RouteResult? _currentRouteResult;


  final Set<Marker> _markers = {};
  SortMode _sortMode = SortMode.distance; // 默认：按距离
  TravelMode _travelMode = TravelMode.walk; // 默认：走路
  bool _isTravelModeExpanded = false; // 放在 class 的顶部变量区

  //位置监听相关
  Timer? _locationIdleTimer;
  static const Duration _locationIdleDelay = Duration(seconds: 2000); // 你可以调 5~15 秒
  StreamSubscription<Position>? _positionStream; // 添加位置监听的变量

  //数据存储
  final List<PlaceModel> _nearbyPlaces = [];
  Map<String, RouteResult> _routeResults = {};
  int _searchToken = 0;
  bool _isLoading = false;

  //筛选相关
  List<String> _selectedTypes = ['all'];
  String? _selectedPrimary;
  String? _selectedSecondary;
  Timer? _secondaryDebounce;
  CameraPosition? _initialCameraPosition;


  //缓存系统
  // -----------------------------
  // 一级缓存
  // -----------------------------


  // -----------------------------
  // 二级缓存
  // -----------------------------

  final Map<String, _CacheEntry> _secondaryCache = {};
  static const Duration _secondaryCacheTtl = Duration(minutes: 5);


  //一级分类
  // -----------------------------
  // 一级 category bar
  // -----------------------------
  final List<Map<String, dynamic>> categories = [
    {'name': 'All', 'icon': Icons.all_inclusive, 'type': 'all', 'color': Colors.black},
    {'name': 'Food', 'icon': Icons.restaurant, 'type': 'restaurant', 'color': Colors.orange},
    {'name': 'Nature', 'icon': Icons.park, 'type': 'park', 'color': Colors.blue},
    // {'name': 'Stay', 'icon': Icons.hotel, 'type': 'lodging', 'color': Colors.blue},
    {'name': 'Historical', 'icon': Icons.place, 'type': 'tourist_attraction', 'color': Colors.green},
    {'name': 'Shopping', 'icon': Icons.shopping_bag, 'type': 'shopping_mall', 'color': Colors.purple},
    {'name': 'Entertainment', 'icon': Icons.local_activity_rounded, 'type': 'amusement_park', 'color': Colors.purple},
    // {'name': 'Cafe', 'icon': Icons.local_cafe, 'type': 'cafe', 'color': Colors.brown},
    // {'name': 'Oil', 'icon': Icons.local_gas_station, 'type': 'gas_station', 'color': Colors.red},
    // {'name': 'Hospital', 'icon': Icons.local_hospital, 'type': 'hospital', 'color': Colors.redAccent},
    // {'name': 'Bank', 'icon': Icons.account_balance, 'type': 'bank', 'color': Colors.teal},
  ];

  //二级分类
  // -----------------------------
  // 二级筛选（按 primary 分类）
  // - keyword: 用于 Google searchText 召回
  // - allowTypes: 用于精筛（避免噪音）
  // -----------------------------
  final Map<String, List<Map<String, dynamic>>> subCategories = {
    'restaurant': [
      {'key': 'all', 'label': 'All', 'keyword': '', 'allowTypes': <String>[]},
      {'key': 'korean', 'label': 'Korean', 'keyword': 'korean restaurant', 'allowTypes': <String>['korean_restaurant', 'restaurant']},
      {'key': 'chinese', 'label': 'Chinese', 'keyword': 'chinese restaurant dim sum', 'allowTypes': <String>['chinese_restaurant', 'restaurant']},
      {'key': 'japanese', 'label': 'Japanese', 'keyword': 'japanese restaurant sushi ramen', 'allowTypes': <String>['japanese_restaurant', 'restaurant']},
      {'key': 'dessert', 'label': 'Dessert', 'keyword': 'dessert bakery cake ice cream gelato', 'allowTypes': <String>['bakery', 'cafe', 'restaurant', 'meal_takeaway']},
      {'key': 'western', 'label': 'Western', 'keyword': 'western restaurant steak grill', 'allowTypes': <String>['restaurant']},
      {'key': 'malay', 'label': 'Malay', 'keyword': 'malay restaurant nasi lemak', 'allowTypes': <String>['malay_restaurant', 'restaurant']},
      {'key': 'indian', 'label': 'Indian', 'keyword': 'indian restaurant', 'allowTypes': <String>['indian_restaurant', 'restaurant']},
    ],
    'cafe': [
      {'key': 'all', 'label': 'All', 'keyword': '', 'allowTypes': <String>[]},
      {'key': 'coffee', 'label': 'Coffee', 'keyword': 'coffee cafe', 'allowTypes': <String>['cafe', 'coffee_shop']},
      {'key': 'bakery', 'label': 'Bakery', 'keyword': 'bakery pastry', 'allowTypes': <String>['bakery']},
      {'key': 'tea', 'label': 'Tea', 'keyword': 'tea bubble tea', 'allowTypes': <String>['cafe', 'tea_house']},
    ],
    'tourist_attraction': [
      {'key': 'all', 'label': 'All', 'keyword': '', 'allowTypes': <String>[]},
      {'key': 'museum', 'label': 'Museum', 'keyword': 'museum', 'allowTypes': <String>['museum', 'tourist_attraction']},
      {'key': 'park', 'label': 'Park', 'keyword': 'park garden', 'allowTypes': <String>['park', 'tourist_attraction']},
      {'key': 'historic', 'label': 'Historic', 'keyword': 'heritage site monument', 'allowTypes': <String>['tourist_attraction']},
      {'key': 'temple', 'label': 'Temple', 'keyword': 'temple mosque church shrine', 'allowTypes': <String>['hindu_temple', 'mosque', 'church', 'tourist_attraction']},
    ],
    'shopping_mall': [
      {'key': 'all', 'label': 'All', 'keyword': '', 'allowTypes': <String>[]},
      {'key': 'fashion', 'label': 'Clothing', 'keyword': 'clothing store fashion', 'allowTypes': <String>['clothing_store', 'shopping_mall', 'store']},
      {'key': 'electronics', 'label': 'Electronics', 'keyword': 'electronics store', 'allowTypes': <String>['electronics_store', 'store']},
      {'key': 'supermarket', 'label': 'Supermarket', 'keyword': 'supermarket grocery', 'allowTypes': <String>['supermarket', 'grocery_store', 'store']},
    ],
    'lodging': [
      {'key': 'all', 'label': 'All', 'keyword': '', 'allowTypes': <String>[]},
      {'key': 'hotel', 'label': 'Hotel', 'keyword': 'hotel', 'allowTypes': <String>['lodging']},
      {'key': 'resort', 'label': 'Resort', 'keyword': 'resort', 'allowTypes': <String>['lodging']},
      {'key': 'hostel', 'label': 'Hostel', 'keyword': 'hostel', 'allowTypes': <String>['lodging']},
      {'key': 'homestay', 'label': 'Guest House', 'keyword': 'guest house homestay', 'allowTypes': <String>['lodging']},
    ],
  };

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _secondaryDebounce?.cancel();
    _positionStream?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _isLoading = true);

    if (widget.landmarkLat != null && widget.landmarkLng != null) {
      _currentPosition = Position(
        latitude: widget.landmarkLat!,
        longitude: widget.landmarkLng!,
        timestamp: DateTime.now(),
        accuracy: 1,
        altitude: 0,
        heading: 0,
        speed: 0,
        speedAccuracy: 0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );
    } else {
      try {
        await LocationService.instance.initLocation();
        final pos = LocationService.instance.currentPosition;
        if (pos == null) {
          _showErrorDialog('定位失败', '无法获取当前位置');
          return;
        }
        _currentPosition = pos;
      } catch (e) {
        _showErrorDialog('定位错误', e.toString());
        return;
      }
    }

    _initialCameraPosition = CameraPosition(
      target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      zoom: 14,
    );

    _markers.add(
      Marker(
        markerId: const MarkerId('me'),
        position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: '我的位置'),
      ),
    );

    setState(() {});
    // ✅ 改成这样
    await _loadFromServiceCache();      // 先从 Service 缓存加载
    if (_nearbyPlaces.isEmpty) {        // 如果没有缓存
      await _refreshAllPlacesFromService(); // 才去请求 API
    }
    _startLocationWatch();

      // ✅ 如果有初始导航数据，自动开启导航
    if (widget.initialNavigation != null) {
      _handleInitialNavigation(widget.initialNavigation!);
    }

  }

  // ✅ 新增方法：处理初始导航
  void _handleInitialNavigation(Map<String, dynamic> navData) {
    final targetLat = navData['lat'] as double;
    final targetLng = navData['lng'] as double;
    final routeResult = navData['routeResult'] as RouteResult?;

    setState(() {
      _isNavigating = true;
      
      _currentNavPlace = PlaceModel(
        id: navData['id'] ?? '',
        name: navData['name'] ?? 'Unknown',
        lat: targetLat,
        lng: targetLng,
        rating: navData['rating'],
        address: navData['address'],
        photoUrl: navData['photoUrl'],
        source: 'google',
      );
      
      // 清理地图
      _markers.retainWhere((m) =>
          m.markerId.value == 'me' ||
          m.position == LatLng(targetLat, targetLng));
      _nearbyPlaces.clear();
    });

    if (routeResult != null) {
      _routeResults[_currentNavPlace!.id] = routeResult;
      _currentRouteResult = routeResult;
      _showRouteOnMap(routeResult, LatLng(targetLat, targetLng));
    }
  }


      //辅助方法
  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('确定'))],
      ),
    );
  }
  
  // Future<void> _searchNearbyPlaces(String type, int token) async {
  //     if (_currentPosition == null) return;

  //     try {
  //       List<PlaceModel> results;

  //       if (_placesByTypeCache.containsKey(type)) {
  //         results = _placesByTypeCache[type]!;
  //       } else {
  //         final apiResults = await PlacesApiService.searchNearby(
  //           lat: _currentPosition!.latitude,
  //           lng: _currentPosition!.longitude,
  //           type: type,
  //           radius: 5000,
  //         );

  //         results = apiResults.map((p) {
  //           try {
  //             final place = PlaceModel.fromGoogle(p, primary: type);
  //             if (place.lat == null || place.lng == null) return null;
  //             return place;
  //           } catch (_) {
  //             return null;
  //           }
  //         }).whereType<PlaceModel>().toList();

  //         _placesByTypeCache[type] = results;
  //         for (final p in results) {
  //           if (!_allPlacesCache.any((e) => e.id == p.id)) _allPlacesCache.add(p);
  //         }
  //       }

  //       for (final place in results) {
  //         if (token != _searchToken) return;
  //         _addMarkerAndPlace(place);
  //       }

  //       setState(() => _isLoading = false);
  //       _animateToFitMarkers(keepZoom: true);
  //     } catch (_) {
  //       if (token != _searchToken) return;
  //       setState(() => _isLoading = false);
  //     }
  //   }

  void _toggleType(String type) {
    setState(() {
      if (type == 'all') {
        _selectedTypes = ['all'];
      } else {
        _selectedTypes.remove('all');
        if (_selectedTypes.contains(type)) {
          _selectedTypes.remove(type);
        } else {
          _selectedTypes.add(type);
        }
        if (_selectedTypes.isEmpty) _selectedTypes = ['all'];
      }

      // ✅ 切换一级时，默认把二级 reset
      _selectedPrimary = type == 'all' ? null : type;
      _selectedSecondary = 'all';
    });

    _searchSelectedFilters();
  }

  void _searchSelectedFilters() {
    final int token = ++_searchToken;

    setState(() {
      _isLoading = true;
      _nearbyPlaces.clear();
      _markers.removeWhere((m) => m.markerId.value != 'me');
    });

    // ✅ 改成从 Service 获取
    final allPlacesCache = NearbyPlacesService.instance.allPlaces;
    final placesByTypeCache = NearbyPlacesService.instance.placesByType;

    List<PlaceModel> base;

    if (_selectedTypes.contains('all')) {
      base = List.from(allPlacesCache);
    } else {
      base = [];
      for (final t in _selectedTypes) {
        base.addAll(placesByTypeCache[t] ?? []);
      }
    }

    for (final p in base) {
      if (token != _searchToken) return;
      _addMarkerAndPlace(p);
    }

    setState(() => _isLoading = false);
    _animateToFitMarkers(keepZoom: true);
  }

  
  // -----------------------------
  // 二级（Google 化）：searchText + types 精筛 + cache + 去重
  // -----------------------------
  String _secondaryCacheKey() {
    final lat = _currentPosition?.latitude ?? 0;
    final lng = _currentPosition?.longitude ?? 0;
    final rLat = (lat * 1000).round() / 1000;
    final rLng = (lng * 1000).round() / 1000;
    return '${_selectedPrimary ?? ''}|${_selectedSecondary ?? ''}|$rLat,$rLng';
  }

  // -----------------------------
  // 二级（Google 化）：searchText + types 精筛 + cache + 去重
  // -----------------------------
  Future<void> _applySecondaryFilterGoogle() async {
    if (_currentPosition == null || _selectedPrimary == null || _selectedSecondary == null) return;

    if (_selectedSecondary == 'all') {
      _searchSelectedFilters();
      return;
    }

    final int currentToken = ++_searchToken;

    final key = _secondaryCacheKey();
    final cached = _secondaryCache[key];
    if (cached != null && DateTime.now().difference(cached.ts) <= _secondaryCacheTtl) {
      setState(() {
        _isLoading = true;
        _nearbyPlaces.clear();
        _markers.removeWhere((m) => m.markerId.value != 'me');
      });

      for (final p in cached.places) {
        if (currentToken != _searchToken) return;
        _addMarkerAndPlace(p);
      }

      setState(() => _isLoading = false);
      
      // 使用缓存时也保持缩放
      _animateToFitMarkers(keepZoom: true); 
      return;
    }

    // 找到二级配置
    final list = subCategories[_selectedPrimary] ?? [];
    final cfg = list.firstWhere(
      (e) => e['key'] == _selectedSecondary,
      orElse: () => {},
    );

    final keyword = (cfg['keyword'] as String?)?.trim();
    final allowTypes = (cfg['allowTypes'] as List?)?.cast<String>() ?? <String>[];

    if (keyword == null || keyword.isEmpty) {
      _searchSelectedFilters();
      return;
    }

    setState(() {
      _isLoading = true;
      _nearbyPlaces.clear();
      _markers.removeWhere((m) => m.markerId.value != 'me');
    });

    try {
      // ✅ 召回：Google searchText
      final raw = await PlacesApiService.searchNearbyWithKeyword(
        lat: _currentPosition!.latitude,
        lng: _currentPosition!.longitude,
        keyword: keyword,
        radius: 5000,
        maxResultCount: 30,
      );

      if (currentToken != _searchToken) return;

      bool pass(Map<String, dynamic> p) {
        final types = (p['types'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
        final primaryOk = types.contains(_selectedPrimary);
        if (allowTypes.isEmpty) return primaryOk;
        final allowOk = types.any((t) => allowTypes.contains(t));
        return primaryOk || allowOk;
      }

      final filtered = raw.where(pass).toList();

      final Map<String, PlaceModel> uniq = {};
      for (final m in filtered) {
        final place = PlaceModel.fromGoogle(m, primary: _selectedPrimary, secondary: _selectedSecondary);
        if (place.lat == null || place.lng == null) continue;
        uniq[place.id] = place;
      }

      // 这里定义的变量名是 places
      final placesList = uniq.values.toList(); 

      if (currentToken != _searchToken) return;

      for (final p in placesList) {
        _addMarkerAndPlace(p);
      }

      _secondaryCache[key] = _CacheEntry(DateTime.now(), placesList);

      setState(() => _isLoading = false);

      if (placesList.isNotEmpty) {

        _animateToFitMarkers(keepZoom: true); 
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('附近没有找到相关地点'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (currentToken != _searchToken) return;
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e'), duration: const Duration(seconds: 3)),
        );
      }
    }
  }


  void _startLocationWatch() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      _currentPosition = pos;

      _locationIdleTimer?.cancel();
      _locationIdleTimer = Timer(_locationIdleDelay, () {
        _refreshAllPlacesFromService(); // ✅ 改用新方法
      });
    });
  }

  // Future<void> _refreshAllPlacesFromApi() async {
  //   if (_currentPosition == null) return;

  //   setState(() {
  //     _isLoading = true;
  //     _allPlacesCache.clear();
  //     _placesByTypeCache.clear();
  //     _nearbyPlaces.clear();
  //     _markers.removeWhere((m) => m.markerId.value != 'me');
  //   });

  //   final types = categories
  //       .where((c) => c['type'] != 'all')
  //       .map((c) => c['type'] as String)
  //       .toList();

  //   for (final type in types) {
  //     final apiResults = await PlacesApiService.searchNearby(
  //       lat: _currentPosition!.latitude,
  //       lng: _currentPosition!.longitude,
  //       type: type,
  //       radius: 5000,
  //     );

  //     final results = apiResults.map((p) {
  //       try {
  //         final place = PlaceModel.fromGoogle(p, primary: type);
  //         if (place.lat == null || place.lng == null) return null;
  //         return place;
  //       } catch (_) {
  //         return null;
  //       }
  //     }).whereType<PlaceModel>().toList();

  //     _placesByTypeCache[type] = results;

  //     for (final p in results) {
  //       if (!_allPlacesCache.any((e) => e.id == p.id)) {
  //         _allPlacesCache.add(p);
  //       }
  //     }
  //   }

  //   // 默认显示 All
  //   _drawFromCache(_allPlacesCache, ++_searchToken);

  //   setState(() => _isLoading = false);
  // }
  // ✅ 新增：从 Service 加载缓存
Future<void> _loadFromServiceCache() async {
  final cachedPlaces = NearbyPlacesService.instance.allPlaces;
  
  if (cachedPlaces.isEmpty) return;

  setState(() {
    _isLoading = true;
    _nearbyPlaces.clear();
    _markers.removeWhere((m) => m.markerId.value != 'me');
  });

  for (final place in cachedPlaces) {
    _addMarkerAndPlace(place);
  }

  setState(() => _isLoading = false);
  _animateToFitMarkers(keepZoom: true);
}

// ✅ 新增：从 Service 刷新数据
Future<void> _refreshAllPlacesFromService() async {
  if (_currentPosition == null) return;

  setState(() {
    _isLoading = true;
    _nearbyPlaces.clear();
    _markers.removeWhere((m) => m.markerId.value != 'me');
  });

  try {
    final places = await NearbyPlacesService.instance
        .loadNearbyPlacesOnce(categories);

    for (final place in places) {
      _addMarkerAndPlace(place);
    }

    setState(() => _isLoading = false);
    _animateToFitMarkers(keepZoom: true);

  } catch (e) {
    setState(() => _isLoading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载失败: $e')),
      );
    }
  }
}


  void _drawFromCache(List<PlaceModel> cache, int token) {
    for (final place in cache) {
      if (token != _searchToken) return;
      _addMarkerAndPlace(place);
    }
    setState(() => _isLoading = false);
    _animateToFitMarkers();
  }


  void _addMarkerAndPlace(PlaceModel place) {
    if (place.lat == null || place.lng == null) return;

    final markerId = MarkerId(place.id);
    if (!_markers.any((m) => m.markerId == markerId)) {
      _markers.add(
        Marker(
          markerId: markerId,
          position: LatLng(place.lat!, place.lng!),
          infoWindow: InfoWindow(
            title: place.name,
            snippet: place.address,
            onTap: () => _showPlaceDetails(place),
          ),
          onTap: () => _showPlaceDetails(place),
        ),
      );
    }

    if (!_nearbyPlaces.any((p) => p.id == place.id)) {
      _nearbyPlaces.add(place);
    }

    // -----------------------------
    // 新增：用直线距离 + 估算时间
    // -----------------------------
    if (_currentPosition != null) {
      final distanceMeters = Geolocator.distanceBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        place.lat!,
        place.lng!,
      );

      final speed = _getSpeedMeterPerSecond();
      final durationSeconds = (distanceMeters / speed).round();


      _routeResults[place.id] = RouteResult(
        polylinePoints: [], // 不需要路线
        bounds: LatLngBounds(
          southwest: LatLng(
            min(_currentPosition!.latitude, place.lat!),
            min(_currentPosition!.longitude, place.lng!),
          ),
          northeast: LatLng(
            max(_currentPosition!.latitude, place.lat!),
            max(_currentPosition!.longitude, place.lng!),
          ),
        ),
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
      );
    }
  }

  double _getSpeedMeterPerSecond() {
    switch (_travelMode) {
      case TravelMode.walk:
        return 1.4;   // 🚶 走路 ~5 km/h
      case TravelMode.motor:
        return 6.0;   // 🛵 摩托 / 骑车 ~20 km/h
      case TravelMode.drive:
        return 12.0;  // 🚗 开车（市区）~43 km/h
    }
  }



  void _animateToFitMarkers({bool keepZoom = false}) {
    if (_mapController == null || _markers.isEmpty) return;

    if (_markers.length == 1) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(_markers.first.position, 15),
      );
      return;
    }

    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final m in _markers) {
      if (m.position.latitude < minLat) minLat = m.position.latitude;
      if (m.position.latitude > maxLat) maxLat = m.position.latitude;
      if (m.position.longitude < minLng) minLng = m.position.longitude;
      if (m.position.longitude > maxLng) maxLng = m.position.longitude;
    }

    LatLng center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);

    if (keepZoom) {
      // 保持当前缩放，只移动中心
      _mapController!.animateCamera(CameraUpdate.newLatLng(center));
    } else {
      // 自动缩放以适应所有标记
      _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
          80,
        ),
      );
    }
  }

void _showPlaceDetails(PlaceModel place) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      final theme = Theme.of(context);
      
      return Container(
        height: MediaQuery.of(context).size.height * 0.42,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(color: Colors.black12, blurRadius: 10, spreadRadius: 1),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部指示条
            Center(
              child: Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // 标题与评分
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    place.name,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (place.rating != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star_rounded, color: Colors.orange, size: 20),
                        const SizedBox(width: 2),
                        Text(
                          place.rating.toString(),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            
            const SizedBox(height: 12),

            // 地址
            Row(
              children: [
                Icon(Icons.location_on_rounded, size: 18, color: theme.primaryColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    place.address ?? '地址未知',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // 路线结果标签 (Chip 风格)
            if (_routeResults[place.id] != null)
              Wrap(
                spacing: 12,
                children: [
                  _buildInfoChip(
                    Icons.directions_car_filled_rounded,
                    '${(_routeResults[place.id]!.distanceMeters / 1000).toStringAsFixed(1)} km',
                    Colors.blue,
                  ),
                  _buildInfoChip(
                    Icons.access_time_filled_rounded,
                    '${(_routeResults[place.id]!.durationSeconds ~/ 60)} min',
                    Colors.teal,
                  ),
                ],
              ),

            const Spacer(),

            // 底部操作栏
            Row(
              children: [
                // ✅ 更多信息按钮 - 修改后的版本
                Expanded(
                  flex: 2,
                  child: OutlinedButton(
                    onPressed: () async {
                      // 1. 先关闭 BottomSheet
                      Navigator.of(context).pop();
                      
                      // 2. 打开详情页
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlaceDetailPage(
                            placeId: place.id,
                            lat: place.lat,
                            lng: place.lng,
                          ),
                        ),
                      );

                      // 3. ✅ 处理返回结果
                      if (result != null && result['action'] == 'navigate') {
                        final targetLat = result['lat'] as double;
                        final targetLng = result['lng'] as double;

                        // 4. 开启导航模式
                        setState(() {
                          _isNavigating = true;
                          _currentNavPlace = PlaceModel(
                            id: result['id'] ?? place.id,
                            name: result['name'] ?? place.name,
                            lat: targetLat,
                            lng: targetLng,
                            rating: result['rating'] ?? place.rating,
                            address: result['address'] ?? place.address,
                            photoUrl: result['photoUrl'] ?? place.photoUrl,
                            source: place.source,              
                            primaryType: place.primaryType,    
                            secondaryType: place.secondaryType, 
                          );
                          
                          // 清理地图，只保留起点和终点
                          _markers.retainWhere((m) =>
                              m.markerId.value == 'me' ||
                              m.position == LatLng(targetLat, targetLng));
                          _nearbyPlaces.clear();
                        });

                        // 5. 计算路线
                        final routeResult = await Navigator.push<RouteResult>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => GuidePage(
                              startLat: _currentPosition!.latitude,
                              startLng: _currentPosition!.longitude,
                              endLat: targetLat,
                              endLng: targetLng,
                            ),
                          ),
                        );

                        // 6. 显示路线
                        if (routeResult != null) {
                          setState(() {
                            _routeResults[_currentNavPlace!.id] = routeResult;
                            _currentRouteResult = routeResult;
                          });
                          _showRouteOnMap(routeResult, LatLng(targetLat, targetLng));
                        }
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(color: Colors.grey[300]!),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text('详情', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                
                // 导航按钮 - 保持原样
                Expanded(
                  flex: 3,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      // 先关闭 BottomSheet
                      Navigator.of(context).pop();
                      
                      final targetLat = place.lat!;
                      final targetLng = place.lng!;

                      setState(() {
                        _isNavigating = true;
                        _currentNavPlace = place;
                        _markers.retainWhere((m) =>
                            m.markerId.value == 'me' ||
                            m.position == LatLng(targetLat, targetLng));
                        _nearbyPlaces.clear();
                      });

                      final result = await Navigator.push<RouteResult>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => GuidePage(
                            startLat: _currentPosition!.latitude,
                            startLng: _currentPosition!.longitude,
                            endLat: targetLat,
                            endLng: targetLng,
                          ),
                        ),
                      );

                      if (result != null) {
                        setState(() { 
                          _routeResults[place.id] = result;
                          _currentRouteResult = result;
                        });
                        _showRouteOnMap(result, LatLng(targetLat, targetLng));
                      }
                    },
                    icon: const Icon(Icons.near_me_rounded, color: Colors.white),
                    label: const Text('开始导航', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.primaryColor,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ],
            )
          ],
        ),
      );
    },
  );
}

  // 辅助方法：构建信息标签
  Widget _buildInfoChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }



  bool _isNavigating = false;
  Set<Polyline> _polylines = {};

  
  void _showRouteOnMap(RouteResult result, LatLng destination) async {
    if (_mapController == null) return;

    setState(() {
      _polylines = {
        Polyline(
          polylineId: const PolylineId('route'),
          points: result.polylinePoints,
          color: Colors.blue,
          width: 6,
        ),
      };
    });

    // 给一点延迟确保地图加载
    await Future.delayed(const Duration(milliseconds: 100));

    final startPoint = result.polylinePoints.first;

    // 这里的配置是关键：模拟图 2 的效果
    await _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: startPoint,
          zoom: 19.0,      // 足够近，看到街道细节
          tilt: 0,      // 大角度倾斜，产生 3D 纵深感
          bearing: 0, // 初始朝向
        ),
      ),
    );

    _startNavigationTracking(); 
  }


  void _startNavigationTracking() {
    _positionStream?.cancel();
    
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2, // 移动 2 米就更新，更平滑
      ),
    ).listen((Position position) {
      if (_mapController == null || !_isNavigating) return;

      // 更新 Marker 位置
      setState(() {
        _markers.removeWhere((m) => m.markerId.value == 'me');
        _markers.add(
          Marker(
            markerId: const MarkerId('me'),
            position: LatLng(position.latitude, position.longitude),
            // 这里可以使用一个自定义的箭头图标，根据 position.heading 旋转
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
            rotation: position.heading, 
            anchor: const Offset(0.5, 0.5), // 确保旋转中心在图标中间
          ),
        );
        _currentPosition = position;
      });

      // 核心：相机跟随更新
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 19.0,
            tilt: 0, 
            bearing: 0, // 固定北向  //bearing: position.heading, // 关键：让地图随你的方向转动
          ),
        ),
      );
    });
  }

  final ValueNotifier<double> _bottomPaddingNotifier = ValueNotifier(0.4);
  double _lastExtent = 0.4; // 记录上一次的面板高度

@override
Widget build(BuildContext context) {
  final screenHeight = MediaQuery.of(context).size.height;

  // 先准备一个按排序模式排序的列表
  final List<PlaceModel> sortedPlaces = List.from(_nearbyPlaces);
  sortedPlaces.sort((a, b) {
    final aRoute = _routeResults[a.id];
    final bRoute = _routeResults[b.id];

    final aDistance = aRoute?.distanceMeters ?? double.infinity;
    final bDistance = bRoute?.distanceMeters ?? double.infinity;

    final aRating = a.rating ?? 0.0;
    final bRating = b.rating ?? 0.0;

    if (_sortMode == SortMode.distance) {
      return aDistance.compareTo(bDistance);
    } else {
      return bRating.compareTo(aRating);
    }
  });

  if (_initialCameraPosition == null) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }

  return Scaffold(
    resizeToAvoidBottomInset: false,
    extendBodyBehindAppBar: true,
    body: Stack(
      children: [
        // ===== 1. 地图层 =====
        ValueListenableBuilder<double>(
          valueListenable: _bottomPaddingNotifier,
          builder: (context, extent, child) {
            return GoogleMap(
              initialCameraPosition: _initialCameraPosition!,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              markers: _markers,
              polylines: _polylines,
              onMapCreated: (controller) => _mapController = controller,
              padding: EdgeInsets.only(
                bottom: _isNavigating ? 120 : (screenHeight * extent),
                top: 60,
              ),
            );
          },
        ),

        // ===== 2. 返回按钮 =====
        Positioned(
          top: 50,
          left: 20,
          child: SafeArea(
            child: Material(
              elevation: 4,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              color: Colors.white,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 20, color: Colors.black87),
                onPressed: () {
                  widget.onBack();
                },
              ),
            ),
          ),
        ),

        // ===== 3. 底部滑动面板 =====
        NotificationListener<DraggableScrollableNotification>(
          onNotification: (notification) {
            _bottomPaddingNotifier.value = notification.extent;
            return false;
          },
          child: DraggableScrollableSheet(
            key: const PageStorageKey('gotrip_sheet_unique'),
            initialChildSize: _isNavigating ? 0.18 : 0.4,
            minChildSize: _isNavigating ? 0.18 : 0.2,
            maxChildSize: _isNavigating ? 0.25 : 0.85,
            snap: true,
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 15)],
                ),
                child: _isNavigating
                    ? _buildNavigationSheet()
                    : _buildPlaceListSheet(scrollController, sortedPlaces),
              );
            },
          ),
        ),

        // ===== 4. 加载中 =====
        if (_isLoading)
          const Center(child: CircularProgressIndicator(color: Colors.blueAccent)),
      ],
    ),
  );
}

  /// ===== 导航状态底部 Sheet =====
Widget _buildNavigationSheet() {
  if (_currentNavPlace == null || !_routeResults.containsKey(_currentNavPlace!.id)) {
    return const SizedBox.shrink();
  }

  final place = _currentNavPlace!;
  final route = _routeResults[place.id]!;

  // 根据你照片里的情况，底部导航栏+大紫色按钮的高度比较高
  // 建议预留 100-110 左右的空间，内容才不会被挡住
  final double bottomReservedSpace = 110.0;
  final double safeAreaBottom = MediaQuery.of(context).padding.bottom;

  return Container(
    // 增加底部内边距，确保按钮被推到紫色按钮上方
    padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottomReservedSpace + safeAreaBottom),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.15),
          blurRadius: 20,
          offset: const Offset(0, -5),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min, // 让高度随内容自适应
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部把手
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // 核心信息：大字绿色时间 + 距离
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${(route.durationSeconds ~/ 60)} min',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2E7D32), // 经典的导航绿
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '(${(route.distanceMeters / 1000).toStringAsFixed(1)} km)',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),

        // 目的地名称
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 20),
          child: Text(
            '目的地: ${place.name}',
            style: TextStyle(fontSize: 15, color: Colors.grey[600]),
            overflow: TextOverflow.ellipsis,
          ),
        ),

        // 操作按钮：现在它们会被顶到紫色按钮的上方
        Row(
          children: [
            Expanded(
              flex: 1,
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _isNavigating = false;
                    _currentNavPlace = null;
                  });
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: Colors.grey[300]!),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('取消', style: TextStyle(color: Colors.black87)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: () {
                  // 继续导航逻辑
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('继续导航', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
  
  
  
  
  /// ===== 原始 Place List / Filter Sheet =====
  Widget _buildPlaceListSheet(ScrollController scrollController, List<PlaceModel> sortedPlaces) {
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.zero,
      children: [
        // 把手
        Center(
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 45,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.05), spreadRadius: 1, blurRadius: 1, offset: const Offset(0, 1)),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),

        // 一级分类
        SizedBox(
          height: 95,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final cat = categories[index];
              final isSelected = _selectedTypes.contains(cat['type']);
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => _toggleType(cat['type']),
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isSelected ? cat['color'] : Colors.grey[100],
                          shape: BoxShape.circle,
                        ),
                        child: Icon(cat['icon'], color: isSelected ? Colors.white : Colors.grey[600], size: 26),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        cat['name'],
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? cat['color'] : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        const Divider(height: 1, thickness: 0.5),

        // Travel Mode
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text("Travel By:", style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              const SizedBox(width: 12),
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _isTravelModeExpanded = !(_isTravelModeExpanded ?? false);
                        });
                      },
                      child: Row(
                        children: [
                          Icon(_getTravelIcon(_travelMode), color: Colors.blue[800], size: 20),
                          Icon(
                            _isTravelModeExpanded == true ? Icons.arrow_left : Icons.arrow_drop_down,
                            color: Colors.blue[800],
                          ),
                        ],
                      ),
                    ),
                    if (_isTravelModeExpanded == true)
                      Row(
                        children: [
                          const VerticalDivider(width: 16),
                          _buildMiniIcon(TravelMode.walk, Icons.directions_walk),
                          _buildMiniIcon(TravelMode.motor, Icons.motorcycle),
                          _buildMiniIcon(TravelMode.drive, Icons.directions_car),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 排序 & 二级分类
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _buildStyledFilterChip(label: "Nearest", isSelected: _sortMode == SortMode.distance, onTap: () => setState(() => _sortMode = SortMode.distance), icon: Icons.near_me_outlined),
              const SizedBox(width: 8),
              _buildStyledFilterChip(label: "High", isSelected: _sortMode == SortMode.rating, onTap: () => setState(() => _sortMode = SortMode.rating), icon: Icons.star_outline_rounded),
            ],
          ),
        ),
        if (_selectedPrimary != null && subCategories.containsKey(_selectedPrimary)) _buildSecondaryBar(),

        const Divider(height: 1, thickness: 0.5),

        // 地点列表
        if (_nearbyPlaces.isEmpty && !_isLoading)
          SizedBox(height: 300, child: _buildEmptyState())
        else
          ...List.generate(
            sortedPlaces.length,
            (index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildPlaceCard(sortedPlaces[index]),
            ),
          ),

        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildModernChip({required String label, required bool isSelected, required VoidCallback onTap}) {
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onTap(),
      selectedColor: Colors.blue[100],
      labelStyle: TextStyle(
        color: isSelected ? Colors.blue[800] : Colors.grey[600],
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      backgroundColor: Colors.grey[100],
      shape: StadiumBorder(side: BorderSide(color: isSelected ? Colors.blue[300]! : Colors.transparent)),
    );
  }

  Widget _buildTravelModeItem(TravelMode mode, IconData icon, String label) {
    final isSelected = _travelMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _travelMode = mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? Colors.blue[50] : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? Colors.blue[400]! : Colors.grey[300]!,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: isSelected ? Colors.blue[700] : Colors.grey[600]),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.blue[800] : Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniIcon(TravelMode mode, IconData icon) {
    bool isSelected = _travelMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() {
          _travelMode = mode;
          _isTravelModeExpanded = false; // 选完自动收起
          _updateRouteTimesForTravelMode(); // ✅ 更新时间
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        margin: const EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[200] : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          size: 18,
          color: isSelected ? Colors.blue[900] : Colors.blue[400],
        ),
      ),
    );
  }

  IconData _getTravelIcon(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk: return Icons.directions_walk;
      case TravelMode.motor: return Icons.motorcycle;
      case TravelMode.drive: return Icons.directions_car;
      default: return Icons.directions_walk;
    }
  }

  Widget _buildSecondaryBar() {
    final subs = subCategories[_selectedPrimary] ?? [];
    return Container(
      height: 40, // 稍微压缩高度，更精致
      margin: const EdgeInsets.only(
        top: 4,     // 顶部间距
        bottom: 12, // ✅ 这里增加了底部的 Margin，让它离下方的分隔线或列表远一点
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: subs.length,
        itemBuilder: (context, index) {
          final item = subs[index];
          final key = item['key'] as String;
          final isSelected = _selectedSecondary == key;

          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildStyledFilterChip(
              label: item['label'] as String,
              isSelected: isSelected,
              onTap: () {
                setState(() => _selectedSecondary = key);
                _secondaryDebounce?.cancel();
                _secondaryDebounce = Timer(const Duration(milliseconds: 350), () {
                  if (_selectedSecondary == 'all') {
                    _searchSelectedFilters();
                  } else {
                    _applySecondaryFilterGoogle();
                  }
                });
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildStyledFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          // 选中时用深色/品牌色，未选中时用极浅灰色
          color: isSelected ? Colors.blue[600] : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.blue[600]! : Colors.grey[200]!,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 16,
                color: isSelected ? Colors.white : Colors.grey[600],
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? Colors.white : Colors.grey[700],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('附近没有符合条件的地点', style: TextStyle(fontSize: 16, color: Colors.grey)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () {
              setState(() => _selectedSecondary = 'all');
              _searchSelectedFilters();
            },
            child: const Text('显示全部'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceCard(PlaceModel place) {
    final name = place.name;
    final rating = place.rating;
    final photoUrl = place.photoUrl;
    final routeInfo = _routeResults[place.id];

    return Padding(
      
      padding: const EdgeInsets.only(bottom: 12),
      
      child: InkWell(
        onTap: () => _showPlaceDetails(place),
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(15),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05), 
                blurRadius: 10, 
                offset: const Offset(0, 4)
              )
            ],
            border: Border.all(color: Colors.grey[100]!),
          ),
          child: Row(
            
            crossAxisAlignment: CrossAxisAlignment.center, // 改为居中对齐，视觉更统一
            children: [
              // 图片部分
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10), 
                  color: Colors.blue[50]
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: photoUrl != null
                      ? Image.network(
                          photoUrl, 
                          fit: BoxFit.cover, 
                          errorBuilder: (c, e, s) => const Icon(Icons.image_not_supported, size: 20)
                        )
                      : Icon(Icons.location_on, color: Colors.blue[400], size: 24),
                ),
              ),
              const SizedBox(width: 12),
              
              // 信息部分
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, // 紧凑布局
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 16, 
                        fontWeight: FontWeight.bold, 
                        color: Colors.black87
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    
                    // Rating + Distance + Time (用 Dot 分隔)
                    // 核心数据行：Rating · Distance · Time
                    Row(
                      children: [
                        if (rating != null) ...[
                          const Icon(Icons.star_rounded, color: Colors.orange, size: 18),
                          const SizedBox(width: 2),
                          Text(
                            rating.toString(),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange,
                            ),
                          ),
                          _buildDotSeparator(), // 后面定义的点分隔符
                        ],
                        
                        if (routeInfo != null) ...[
                          Icon(Icons.near_me_rounded, size: 14, color: Colors.blue[400]),
                          const SizedBox(width: 4),
                          Text(
                            '${(routeInfo.distanceMeters / 1000).toStringAsFixed(1)} km',
                            style: TextStyle(fontSize: 13, color: Colors.grey[700], fontWeight: FontWeight.w500),
                          ),
                          _buildDotSeparator(),
                          Icon(Icons.access_time_filled_rounded, size: 14, color: Colors.grey[400]),
                          const SizedBox(width: 4),
                          Text(
                            '${(routeInfo.durationSeconds ~/ 60)} min',
                            style: TextStyle(fontSize: 13, color: Colors.grey[700], fontWeight: FontWeight.w500),
                          ),
                        ],
                        
                        // 如果都没有数据，显示默认提示
                        if (rating == null && routeInfo == null)
                          Text('查看详情', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                      ],
                    ),
                  ],
                ),
              ),
              
              // 右侧小箭头指示
              Icon(Icons.chevron_right_rounded, color: Colors.grey[300]),
            ],
          ),
        ),
      ),
    );
  }

  void _updateRouteTimesForTravelMode() {
    if (_currentPosition == null) return;

    for (final place in _nearbyPlaces) {
      final route = _routeResults[place.id];
      if (route == null) continue;

      final distanceMeters = route.distanceMeters;
      final speed = _getSpeedMeterPerSecond();
      final durationSeconds = (distanceMeters / speed).round();

      _routeResults[place.id] = RouteResult(
        polylinePoints: route.polylinePoints,
        bounds: route.bounds,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
      );
    }
  }


  // 辅助组件：分隔点
  Widget _buildDotSeparator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6), 
      child: Text(
        '•',
        style: TextStyle(
          color: Colors.grey[300], // 浅灰色，让它作为辅助元素存在
          fontWeight: FontWeight.bold, // 改为 bold，粗细适中
          fontSize: 14,
        ),
      ),
    );
  }

}
