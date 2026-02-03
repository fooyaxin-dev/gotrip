import 'dart:async';
import 'dart:math';
import 'placeDetailPage.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/placesAPI_service.dart';
import '../../services/location_service.dart';
import '../../services/placeModal.dart';
import 'guidePage.dart';

    // 二级缓存
  class _CacheEntry {
    final DateTime ts;
    final List<PlaceModel> places;
    _CacheEntry(this.ts, this.places);
  }

class RealTimeDetectPage extends StatefulWidget {
  final double? landmarkLat;
  final double? landmarkLng;

  const RealTimeDetectPage({super.key, this.landmarkLat, this.landmarkLng});

  @override
  State<RealTimeDetectPage> createState() => _RealTimeDetectPageState();
}

class _RealTimeDetectPageState extends State<RealTimeDetectPage> {
  GoogleMapController? _mapController;
  Position? _currentPosition;

  final Set<Marker> _markers = {};

  StreamSubscription<Position>? _positionStream; // 添加位置监听的变量
  
  final List<PlaceModel> _nearbyPlaces = [];

  int _searchToken = 0;
  bool _isLoading = false;

  List<String> _selectedTypes = ['all'];
  String? _selectedPrimary;
  String? _selectedSecondary;

  Timer? _secondaryDebounce;

  // -----------------------------
  // 一级缓存（你原本就有）
  // -----------------------------
  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};

  // -----------------------------
  // 二级缓存（新增）
  // -----------------------------

  final Map<String, _CacheEntry> _secondaryCache = {};
  static const Duration _secondaryCacheTtl = Duration(minutes: 5);

  // -----------------------------
  // 一级 category bar
  // -----------------------------
  final List<Map<String, dynamic>> categories = [
    {'name': 'All', 'icon': Icons.all_inclusive, 'type': 'all', 'color': Colors.black},
    {'name': '餐厅', 'icon': Icons.restaurant, 'type': 'restaurant', 'color': Colors.orange},
    {'name': '酒店', 'icon': Icons.hotel, 'type': 'lodging', 'color': Colors.blue},
    {'name': '景点', 'icon': Icons.place, 'type': 'tourist_attraction', 'color': Colors.green},
    {'name': '购物', 'icon': Icons.shopping_bag, 'type': 'shopping_mall', 'color': Colors.purple},
    {'name': '咖啡厅', 'icon': Icons.local_cafe, 'type': 'cafe', 'color': Colors.brown},
    {'name': '加油站', 'icon': Icons.local_gas_station, 'type': 'gas_station', 'color': Colors.red},
    {'name': '医院', 'icon': Icons.local_hospital, 'type': 'hospital', 'color': Colors.redAccent},
    {'name': '银行', 'icon': Icons.account_balance, 'type': 'bank', 'color': Colors.teal},
  ];

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

  late CameraPosition _initialCameraPosition;

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
    _searchSelectedFilters();
  }

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

  Future<void> _searchSelectedFilters() async {
    if (_currentPosition == null) return;
    final int currentToken = ++_searchToken;

    setState(() {
      _isLoading = true;
      _nearbyPlaces.clear();
      _markers.removeWhere((m) => m.markerId.value != 'me');
    });

    if (_selectedTypes.contains('all') && _allPlacesCache.isNotEmpty) {
      _drawFromCache(_allPlacesCache, currentToken);
      return;
    }

    final List<String> typesToSearch = _selectedTypes.contains('all')
        ? categories.where((c) => c['type'] != 'all').map((c) => c['type'] as String).toList()
        : List<String>.from(_selectedTypes);

    try {
      for (final type in typesToSearch) {
        if (currentToken != _searchToken) return;
        await _searchNearbyPlaces(type, currentToken);
      }
      if (currentToken != _searchToken) return;
      setState(() => _isLoading = false);
      _animateToFitMarkers();
    } catch (_) {
      if (currentToken != _searchToken) return;
      setState(() => _isLoading = false);
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

  Future<void> _searchNearbyPlaces(String type, int token) async {
    if (_currentPosition == null) return;

    try {
      List<PlaceModel> results;

      if (_placesByTypeCache.containsKey(type)) {
        results = _placesByTypeCache[type]!;
      } else {
        final apiResults = await PlacesApiService.searchNearby(
          lat: _currentPosition!.latitude,
          lng: _currentPosition!.longitude,
          type: type,
          radius: 5000,
        );

        results = apiResults.map((p) {
          try {
            final place = PlaceModel.fromGoogle(p, primary: type);
            if (place.lat == null || place.lng == null) return null;
            return place;
          } catch (_) {
            return null;
          }
        }).whereType<PlaceModel>().toList();

        _placesByTypeCache[type] = results;
        for (final p in results) {
          if (!_allPlacesCache.any((e) => e.id == p.id)) _allPlacesCache.add(p);
        }
      }

      for (final place in results) {
        if (token != _searchToken) return;
        _addMarkerAndPlace(place);
      }

      setState(() => _isLoading = false);
      _animateToFitMarkers(keepZoom: true);
    } catch (_) {
      if (token != _searchToken) return;
      setState(() => _isLoading = false);
    }
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
        // --- 核心修复：这里传入 keepZoom: true ---
        // 这样点击 Dessert 时地图只会平移中心点，不会改变你的 Zoom Level
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
        return Container(
          height: MediaQuery.of(context).size.height * 0.4,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              Text(place.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.location_on, size: 20, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(child: Text(place.address ?? '地址未知')),
                ],
              ),
              const SizedBox(height: 8),
              if (place.rating != null)
                Row(
                  children: [
                    const Icon(Icons.star, color: Colors.orange, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      place.rating.toString(),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: Colors.orange),
                    ),
                  ],
                ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(context); // ✅ 关闭ModalSheet
                        final targetLat = place.lat!;
                        final targetLng = place.lng!;

                        // 标记导航状态
                        setState(() {
                          _isNavigating = true;

                          // 清除其他Markers，只保留用户 + 目的地
                          _markers.retainWhere((m) =>
                              m.markerId.value == 'me' || m.position == LatLng(targetLat, targetLng));

                          // 清除附近地点列表
                          _nearbyPlaces.clear();

                          // Sheet会隐藏，因为 build里加了 !_isNavigating
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
                          _showRouteOnMap(result, LatLng(targetLat, targetLng));
                        }
                      },
                      icon: const Icon(Icons.directions),
                      label: const Text('导航'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PlaceDetailPage(placeId: place.id),
                          ),
                        );
                      },
                      icon: const Icon(Icons.info),
                      label: const Text('更多信息'),
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


  bool _isNavigating = false;
  Set<Polyline> _polylines = {};

  // ✅ 只需要替换这个方法
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
          bearing: _currentPosition?.heading ?? 0, // 初始朝向
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
            bearing: position.heading, // 关键：让地图随你的方向转动
          ),
        ),
      );
    });
  }


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

  // 替换掉之前的 _panelExtent
  final ValueNotifier<double> _mapBottomPadding = ValueNotifier(0.4);
  // 在类顶部定义
  final ValueNotifier<double> _bottomPaddingNotifier = ValueNotifier(0.4);
  double _lastExtent = 0.4; // 记录上一次的面板高度

 @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 地图层
          ValueListenableBuilder<double>(
            valueListenable: _bottomPaddingNotifier,
            builder: (context, extent, child) {
              return GoogleMap(
                initialCameraPosition: _initialCameraPosition,
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                markers: _markers,
                polylines: _polylines,
                onMapCreated: (controller) => _mapController = controller,
                // 在 GoogleMap 构造函数里修改
                padding: EdgeInsets.only(
                bottom: _isNavigating ? 100 : 400, // 导航时底部留白改小，标就会回到中间
                top: 60,
                ),
              );
            },
          ),

          // 返回按钮
          Positioned(
            top: 40,
            left: 20,
            child: SafeArea(
              child: Material(
                color: Colors.white,
                shape: const CircleBorder(),
                elevation: 4,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),

          // DraggableScrollableSheet（仅在非导航时显示）
          if (!_isNavigating)
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (notification) {
                _bottomPaddingNotifier.value = notification.extent;
                return true;
              },
              child: DraggableScrollableSheet(
                key: const PageStorageKey('gotrip_sheet_unique'),
                initialChildSize: 0.4,
                minChildSize: 0.2,
                maxChildSize: 0.7,
                snap: true,
                builder: (context, scrollController) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                      boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
                    ),
                    child: Column(
                      children: [
                        // 面板把手
                        Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),

                        // 一级分类 Category Bar
                        SizedBox(
                          height: 90,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            itemCount: categories.length,
                            itemBuilder: (context, index) {
                              final cat = categories[index];
                              final isSelected = _selectedTypes.contains(cat['type']);
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 5),
                                child: GestureDetector(
                                  onTap: () => _toggleType(cat['type']),
                                  child: Container(
                                    width: 80,
                                    decoration: BoxDecoration(
                                      color: isSelected ? cat['color'] : Colors.grey[200],
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(cat['icon'],
                                            color: isSelected ? Colors.white : Colors.grey[600],
                                            size: 30),
                                        const SizedBox(height: 5),
                                        Text(
                                          cat['name'],
                                          style: TextStyle(
                                            color: isSelected ? Colors.white : Colors.grey[600],
                                            fontSize: 12,
                                            fontWeight:
                                                isSelected ? FontWeight.bold : FontWeight.normal,
                                          ),
                                        )
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),

                        const SizedBox(height: 10),
                        const Divider(height: 1),

                        // 二级分类 Bar
                        if (_selectedPrimary != null && subCategories.containsKey(_selectedPrimary))
                          _buildSecondaryBar(),

                        const Divider(height: 1),

                        // 地点列表
                        Expanded(
                          child: _nearbyPlaces.isEmpty && !_isLoading
                              ? _buildEmptyState()
                              : ListView.builder(
                                  controller: scrollController,
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  itemCount: _nearbyPlaces.length,
                                  itemBuilder: (context, index) =>
                                      _buildPlaceCard(_nearbyPlaces[index]),
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

          // 加载动画
          if (_isLoading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }



  Widget _buildSecondaryBar() {
    final subs = subCategories[_selectedPrimary] ?? [];
    return SizedBox(
      height: 60,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: subs.length,
        itemBuilder: (context, index) {
          final item = subs[index];
          final key = item['key'] as String;
          final isSelected = _selectedSecondary == key;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ChoiceChip(
              label: Text(item['label'] as String),
              selected: isSelected,
              onSelected: (_) {
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
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
            border: Border.all(color: Colors.grey[100]!),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.blue[50]),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: photoUrl != null
                      ? Image.network(photoUrl, fit: BoxFit.cover, errorBuilder: (c, e, s) => const Icon(Icons.image_not_supported))
                      : Icon(Icons.location_on, color: Colors.blue[400], size: 26),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (rating != null)
                Row(
                  children: [
                    const Icon(Icons.star, color: Colors.orange, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      rating.toString(),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.orange),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
