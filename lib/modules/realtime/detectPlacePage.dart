import 'dart:async';
import 'placeDetailPage.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../services/placesAPI_service.dart';
import '../../services/location_service.dart';
import '../../services/fourSquare.dart'; 
import '../../services/placeModal.dart'; // 确保文件名拼写正确，通常是 placeModel.dart

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
  
  // ✅ 关键：这里必须改成 List<PlaceModel>
  List<PlaceModel> _nearbyPlaces = [];
  int _searchToken = 0; 

  List<String> _selectedTypes = ['all'];
  
  // ✅ 关键：Cache 也要改成 List<PlaceModel>
  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};

  bool _isLoading = false;

  String? _selectedPrimary;   
  String? _selectedSecondary; 

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

  final Map<String, List<Map<String, String>>> subCategories = {
    'restaurant': [
      {'key': 'all', 'label': 'All', 'fs_id': ''},
      {'key': 'korean', 'label': 'Korean', 'fs_id': '13065'},
      {'key': 'chinese', 'label': 'Chinese', 'fs_id': '13029'},
      {'key': 'japanese', 'label': 'Japanese', 'fs_id': '13060'},
      {'key': 'dessert', 'label': 'Dessert', 'fs_id': '13040'},
      {'key': 'western', 'label': 'Western', 'fs_id': '13049'},
      {'key': 'malay', 'label': 'Malay', 'fs_id': '13145'},
      {'key': 'indian', 'label': 'Indian', 'fs_id': '13199'},
    ],
    'lodging': [
      {'key': 'all', 'label': 'All', 'fs_id': ''},
      {'key': 'hotel', 'label': 'Hotel', 'fs_id': '19014'},
      {'key': 'resort', 'label': 'Resort', 'fs_id': '19021'},
      {'key': 'hostel', 'label': 'Hostel', 'fs_id': '19013'},
      {'key': 'homestay', 'label': 'Guest House', 'fs_id': '19012'},
    ],
    'tourist_attraction': [
      {'key': 'all', 'label': 'All', 'fs_id': ''},
      {'key': 'museum', 'label': 'Museum', 'fs_id': '10027'},
      {'key': 'park', 'label': 'Park', 'fs_id': '16032'},
      {'key': 'historic', 'label': 'Historic Site', 'fs_id': '16026'},
      {'key': 'temple', 'label': 'Temple', 'fs_id': '12124'},
    ],
    'shopping_mall': [
      {'key': 'all', 'label': 'All', 'fs_id': ''},
      {'key': 'fashion', 'label': 'Clothing', 'fs_id': '17043'},
      {'key': 'electronics', 'label': 'Electronics', 'fs_id': '17066'},
      {'key': 'supermarket', 'label': 'Supermarket', 'fs_id': '17069'},
    ],
    'cafe': [
      {'key': 'all', 'label': 'All', 'fs_id': ''},
      {'key': 'coffee', 'label': 'Coffee Shop', 'fs_id': '13035'},
      {'key': 'bakery', 'label': 'Bakery', 'fs_id': '13002'},
      {'key': 'tea', 'label': 'Tea Room', 'fs_id': '13032'},
    ],
  };

  late CameraPosition _initialCameraPosition;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {

    setState(() {
      _isLoading = true; // 🌟 一进来就设为 true，确保 DraggableSheet 会显示
    });

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
    } catch (e) {
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

  debugPrint('🔍 Searching nearby places for type: $type');

  try {
    List<PlaceModel> results;

    // 先检查缓存
    if (_placesByTypeCache.containsKey(type)) {
      results = _placesByTypeCache[type]!;
      debugPrint('⚡ Using cached results for $type, count: ${results.length}');
    } else {
      // 调用 Google Places API
      final List<Map<String, dynamic>> apiResults = await PlacesApiService.searchNearby(
        lat: _currentPosition!.latitude,
        lng: _currentPosition!.longitude,
        type: type,
        radius: 5000,
      );

      debugPrint('✅ API returned ${apiResults.length} items for type: $type');
      if (apiResults.isEmpty) {
        debugPrint('⚠️ No results from API for type $type');
      }

      // Map -> PlaceModel，注意安全转换
      results = apiResults.map((p) {
        try {
          final place = PlaceModel.fromGoogle(p, primary: type);
          if (place.lat == null || place.lng == null) {
            debugPrint('⚠️ Place skipped due to missing lat/lng: ${place.name}');
            return null;
          }
          return place;
        } catch (e) {
          debugPrint('❌ Error parsing PlaceModel: $e');
          return null;
        }
      }).whereType<PlaceModel>().toList();

      debugPrint('✅ Converted to PlaceModel count: ${results.length}');

      // 保存缓存
      _placesByTypeCache[type] = results;
      for (final p in results) {
        if (!_allPlacesCache.any((e) => e.id == p.id)) _allPlacesCache.add(p);
      }
    }

    // 加入 markers 和列表
    for (var place in results) {
      if (token != _searchToken) return;
      _addMarkerAndPlace(place);
    }

    setState(() => _isLoading = false);
    _animateToFitMarkers();
  } catch (e) {
    debugPrint('❌ Search Error: $e');
    if (token != _searchToken) return;
    setState(() => _isLoading = false);
  }
}


  Future<void> _applySecondaryFilter() async {
  if (_selectedPrimary == null || _selectedSecondary == null) {
    debugPrint('⚠️ No primary or secondary filter selected');
    return;
  }

  // 如果选的是 "All"，直接回到一级 filter 搜索
  if (_selectedSecondary == 'all') {
    debugPrint('🔄 Secondary filter set to "all", reverting to primary filter');
    _searchSelectedFilters();
    return;
  }

  final subList = subCategories[_selectedPrimary];
  final selectedSub = subList?.firstWhere(
    (e) => e['key'] == _selectedSecondary,
    orElse: () => {},
  );
  final String? fsId = selectedSub?['fs_id'];

  if (fsId == null || fsId.isEmpty) {
    debugPrint('⚠️ No Foursquare ID found for $_selectedSecondary');
    return;
  }

  final int currentToken = ++_searchToken;

  setState(() {
    _isLoading = true;
    _nearbyPlaces.clear();
    _markers.removeWhere((m) => m.markerId.value != 'me');
  });

  try {
    debugPrint('🔍 === Foursquare Secondary Filter ===');
    debugPrint('   Primary Type: $_selectedPrimary');
    debugPrint('   Secondary Type: $_selectedSecondary');
    debugPrint('   Foursquare Category ID: $fsId');
    debugPrint('   Location: (${_currentPosition!.latitude}, ${_currentPosition!.longitude})');
    
    // 调用 Foursquare API
    final List<Map<String, dynamic>> results = await FoursquareApiService.searchNearby(
      lat: _currentPosition!.latitude,
      lng: _currentPosition!.longitude,
      categoryId: fsId,
    );

    debugPrint('✅ Foursquare API returned ${results.length} results');
    
    // 打印第一个结果的样本数据
    if (results.isNotEmpty) {
      debugPrint('📋 First result sample:');
      debugPrint('   ${results.first}');
    } else {
      debugPrint('⚠️ No results from Foursquare for category $fsId');
    }

    // 检查是否被取消
    if (currentToken != _searchToken) {
      debugPrint('⚠️ Search token mismatch (${currentToken} vs ${_searchToken}), aborting');
      return;
    }

    // 如果没有结果，显示提示
    if (results.isEmpty) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('附近没有找到相关地点'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // 转成 PlaceModel，添加详细的错误处理
    final List<PlaceModel> placeModels = [];
    int successCount = 0;
    int failCount = 0;
    
    for (int i = 0; i < results.length; i++) {
      final f = results[i];
      
      try {
        debugPrint('🔄 Parsing result ${i + 1}/${results.length}: ${f['name']}');
        
        final place = PlaceModel.fromFoursquare(
          f,
          primary: _selectedPrimary,
          secondary: _selectedSecondary,
        );
        
        // 检查必要字段
        if (place.lat == null || place.lng == null) {
          debugPrint('⚠️ Skipped place "${place.name}" - missing coordinates');
          debugPrint('   lat: ${place.lat}, lng: ${place.lng}');
          failCount++;
          continue;
        }
        
        placeModels.add(place);
        successCount++;
        debugPrint('✅ Successfully parsed: ${place.name} at (${place.lat}, ${place.lng})');
        
      } catch (e, stackTrace) {
        failCount++;
        debugPrint('❌ Error parsing Foursquare result ${i + 1}:');
        debugPrint('   Error: $e');
        debugPrint('   Raw data: $f');
        debugPrint('   Stack trace: $stackTrace');
      }
    }

    debugPrint('📊 Parsing Summary:');
    debugPrint('   Total results: ${results.length}');
    debugPrint('   Successfully parsed: $successCount');
    debugPrint('   Failed to parse: $failCount');

    // 再次检查是否被取消
    if (currentToken != _searchToken) {
      debugPrint('⚠️ Search token mismatch after parsing, aborting');
      return;
    }

    // 添加到地图和列表
    if (placeModels.isNotEmpty) {
      debugPrint('🗺️ Adding ${placeModels.length} markers to map');
      
      for (var place in placeModels) {
        _addMarkerAndPlace(place);
      }
      
      debugPrint('✅ Total markers on map: ${_markers.length}');
      debugPrint('✅ Total places in list: ${_nearbyPlaces.length}');
    }

    setState(() => _isLoading = false);
    
    // 如果有结果，调整地图视角
    if (placeModels.isNotEmpty) {
      debugPrint('📍 Animating camera to fit markers');
      _animateToFitMarkers();
    } else {
      debugPrint('⚠️ No valid places to display after filtering');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('找到的地点缺少位置信息'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
    
  } catch (e, stackTrace) {
    debugPrint('❌ === Secondary Filter Error ===');
    debugPrint('   Error: $e');
    debugPrint('   Stack trace: $stackTrace');
    
    if (currentToken != _searchToken) {
      debugPrint('⚠️ Search was cancelled, not showing error');
      return;
    }
    
    setState(() => _isLoading = false);
    
    // 显示错误提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('加载失败: ${e.toString()}'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: '重试',
            onPressed: () => _applySecondaryFilter(),
          ),
        ),
      );
    }
  }
}

  void _addMarkerAndPlace(PlaceModel place) {
  if (place.lat == null || place.lng == null) {
    debugPrint('⚠️ Skipping place with null lat/lng: ${place.name}');
    return;
  }

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
    debugPrint('Added place: ${place.name}, lat: ${place.lat}, lng: ${place.lng}');
  }
}


  void _animateToFitMarkers() {
    if (_mapController == null || _markers.isEmpty) return;
    if (_markers.length == 1) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_markers.first.position, 15));
      return;
    }
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final m in _markers) {
      if (m.position.latitude < minLat) minLat = m.position.latitude;
      if (m.position.latitude > maxLat) maxLat = m.position.latitude;
      if (m.position.longitude < minLng) minLng = m.position.longitude;
      if (m.position.longitude > maxLng) maxLng = m.position.longitude;
    }
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 80));
  }

  // --- UI 部分已修复数据引用 ---

  void _showPlaceDetails(PlaceModel place) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.4,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 20),
            Text(place.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(children: [const Icon(Icons.location_on, size: 20, color: Colors.grey), const SizedBox(width: 8), Expanded(child: Text(place.address ?? '地址未知'))]),
            const SizedBox(height: 8),
            if (place.rating != null) Row(children: [const Icon(Icons.star, color: Colors.orange, size: 18), const SizedBox(width: 4), Text(place.rating.toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.orange))]),
            const Spacer(),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () { Navigator.pop(context); _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(place.lat!, place.lng!), 16)); }, icon: const Icon(Icons.directions), label: const Text('导航'))),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton.icon(onPressed: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => PlaceDetailPage(placeId: place.id))); }, icon: const Icon(Icons.info), label: const Text('查看更多'))),
            ]),
          ],
        ),
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(context: context, builder: (context) => AlertDialog(title: Text(title), content: Text(message), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('确定'))]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: _initialCameraPosition,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            markers: _markers,
            onMapCreated: (controller) => _mapController = controller,
          ),
          Positioned(top: 40, left: 20, child: SafeArea(child: Material(color: Colors.white, shape: const CircleBorder(), elevation: 4, child: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context))))),
          
            DraggableScrollableSheet(
              initialChildSize: 0.4,
              minChildSize: 0.2,
              maxChildSize: 0.7,
              builder: (context, scrollController) {
                return Container(
                  decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)]),
                  child: Column(
                    children: [
                      Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 10), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
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
                                onTap: () {
                                  _toggleType(cat['type']);
                                  setState(() {
                                    _selectedPrimary = cat['type'] == 'all' ? null : cat['type'];
                                    _selectedSecondary = 'all';
                                  });
                                },
                                child: Container(
                                  width: 80,
                                  decoration: BoxDecoration(color: isSelected ? cat['color'] : Colors.grey[200], borderRadius: BorderRadius.circular(10)),
                                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(cat['icon'], color: isSelected ? Colors.white : Colors.grey[600], size: 30), const SizedBox(height: 5), Text(cat['name'], style: TextStyle(color: isSelected ? Colors.white : Colors.grey[600], fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal))]),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Divider(height: 1),
                      if (_selectedPrimary != null && subCategories.containsKey(_selectedPrimary)) _buildSecondaryBar(),
                      const Divider(height: 1),
                      Expanded(
                        child: _nearbyPlaces.isEmpty && !_isLoading
                            ? _buildEmptyState()
                            : ListView.builder(
                                controller: scrollController,
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                itemCount: _nearbyPlaces.length,
                                itemBuilder: (context, index) => _buildPlaceCard(_nearbyPlaces[index]),
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          if (_isLoading) const Center(child: CircularProgressIndicator()),
        ],
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
          ElevatedButton(onPressed: () { setState(() => _selectedSecondary = 'all'); _searchSelectedFilters(); }, child: const Text('显示全部')),
        ],
      ),
    );
  }

  Widget _buildPlaceCard(PlaceModel place) {
    // ✅ 修复：直接使用传入的 place 对象
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
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))], border: Border.all(color: Colors.grey[100]!)),
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
                    : Icon(Icons.location_on, color: Colors.blue[400], size: 26)
                )
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (rating != null) Row(children: [const Icon(Icons.star, color: Colors.orange, size: 16), const SizedBox(width: 4), Text(rating.toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.orange))]),
            ],
          ),
        ),
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
          final isSelected = _selectedSecondary == item['key'];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ChoiceChip(
              label: Text(item['label']!),
              selected: isSelected,
              onSelected: (_) {
                setState(() {
                  _selectedSecondary = item['key'];
                });

                // ⭐ 点击二级 filter 立即刷新列表
                if (_selectedSecondary == 'all') {
                  _searchSelectedFilters(); // 回到一级 filter
                } else {
                  _applySecondaryFilter(); // 调用 Foursquare API
                }
              },
            ),
          );
        },
      ),
    );
  }

}