import 'dart:async';
import 'dart:convert';
import 'placeDetailPage.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

class RealTimeGuidePage extends StatefulWidget {
  final double? landmarkLat;
  final double? landmarkLng;

  const RealTimeGuidePage({super.key, this.landmarkLat, this.landmarkLng});

  @override
  State<RealTimeGuidePage> createState() => _RealTimeGuidePageState();
}

class _RealTimeGuidePageState extends State<RealTimeGuidePage> {
  GoogleMapController? _mapController;
  Position? _currentPosition;

  final Set<Marker> _markers = {};
  List<Map<String, dynamic>> _nearbyPlaces = [];
  int _searchToken = 0; // 用来防止旧请求污染新结果

  // 多选 filter
  List<String> _selectedTypes = ['all'];

  bool _isLoading = false;

  final String googleAPIKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';

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

  late CameraPosition _initialCameraPosition;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
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
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showErrorDialog('位置服务未启用', '请启用位置服务以使用此功能');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showErrorDialog('权限被拒绝', '需要位置权限才能使用此功能');
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        _showErrorDialog('权限被永久拒绝', '请在设置中启用位置权限');
        return;
      }

      _currentPosition = await Geolocator.getCurrentPosition();
    }

    _initialCameraPosition = CameraPosition(
      target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      zoom: 14, // 随便一个合理初始值，之后会被 animate 覆盖
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

    // 默认显示所有类别
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

  Future<void> _searchSelectedFilters() async { //filter
    if (_currentPosition == null) return;

    final int currentToken = ++_searchToken; // ⭐ 新一轮搜索ID

    setState(() {
      _isLoading = true;
      _nearbyPlaces.clear();
      _markers.removeWhere((m) => m.markerId.value != 'me'); // 只留自己
    });

    List<String> typesToSearch = _selectedTypes.contains('all')
        ? categories.where((c) => c['type'] != 'all').map((c) => c['type'] as String).toList()
        : _selectedTypes;

    for (final type in typesToSearch) {
      await _searchNearbyPlaces(type, currentToken);
    }

    // 如果在等待期间用户又点了别的 filter，这一轮直接作废
    if (currentToken != _searchToken) return;

    setState(() {
      _isLoading = false;
    });

    _animateToFitMarkers();
  }


  void _animateToFitMarkers() {
    if (_mapController == null || _markers.isEmpty) return;

    // 至少要有 2 个点才有意义（自己 + 至少一个 place）
    if (_markers.length == 1) {
      final only = _markers.first.position;
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(only, 15),
      );
      return;
    }

    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;

    for (final m in _markers) {
      final lat = m.position.latitude;
      final lng = m.position.longitude;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80), // 80 是 padding
    );
  }

  Future<void> _searchNearbyPlaces(String type, int token) async {
  if (_currentPosition == null) return;

  final url = Uri.parse('https://places.googleapis.com/v1/places:searchNearby');

  final body = jsonEncode({
    "locationRestriction": {
      "circle": {
        "center": {
          "latitude": _currentPosition!.latitude,
          "longitude": _currentPosition!.longitude
        },
        "radius": 5000
      }
    },
    "includedTypes": [type],
    "maxResultCount": 20  // ⭐ v1 用 maxResultCount，不是 pageSize
  });

  try {
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': googleAPIKey,
        // ⭐ 修改 FieldMask，包含所有需要的字段
        'X-Goog-FieldMask': 'places.id,places.displayName,places.location,places.formattedAddress,places.types,places.rating,places.photos'

      },
      body: body,
    );

    if (token != _searchToken) return;

    final data = json.decode(response.body);

    // ⭐ 添加调试信息
    print('API Response for $type: ${data.toString()}');

    if (data['places'] == null || data['places'].isEmpty) {
      print('No places found for type: $type');
      return;
    }

    final List<dynamic> results = data['places'];
    print('Found ${results.length} places for $type');

    for (int i = 0; i < results.length; i++) {
      if (token != _searchToken) return;

      final place = results[i];
      final loc = place['location'];
      final lat = loc['latitude'];
      final lng = loc['longitude'];

      double distanceInMeters = Geolocator.distanceBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        lat,
        lng,
      );

      if (distanceInMeters > 5000) continue;

      // ⭐ 使用正确的 ID 字段
      final markerId = MarkerId(place['id'] ?? 'place_${type}_$i');

      if (_markers.any((m) => m.markerId == markerId)) continue;

      _markers.add(
        Marker(
          markerId: markerId,
          position: LatLng(lat, lng),
          infoWindow: InfoWindow(
            title: place['displayName']?['text'] ?? '未知',  // ⭐ displayName 是个对象
            snippet: place['formattedAddress'] ?? '',
            onTap: () => _showPlaceDetails(place),
          ),
          onTap: () => _showPlaceDetails(place),
        ),
      );

      if (!_nearbyPlaces.any((p) => p['id'] == place['id'])) {
        _nearbyPlaces.add(place);
      }
    }
    
    // ⭐ 触发 UI 更新
    setState(() {});
    
  } catch (e) {
    debugPrint('Places API search error for $type: $e');
  }
}
  

 void _showPlaceDetails(Map<String, dynamic> place) {
  final loc = place['location'];
  final lat = loc['latitude'];
  final lng = loc['longitude'];

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
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 名字
          Text(
            place['displayName']?['text'] ?? '未知地点',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 8),

          // 地址
          Row(
            children: [
              const Icon(Icons.location_on, size: 20, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(child: Text(place['formattedAddress'] ?? '地址未知')),
            ],
          ),

          const SizedBox(height: 8),

          // Rating（如果有）
          if (place['rating'] != null)
            Row(
              children: [
                const Icon(Icons.star, color: Colors.orange, size: 18),
                const SizedBox(width: 4),
                Text(
                  place['rating'].toString(),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange,
                  ),
                ),
              ],
            ),

          const Spacer(),

          // 按钮区
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(LatLng(lat, lng), 16),
                    );
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
                        builder: (_) => PlaceDetailPage(placeId: place['id']),
                      ),
                    );
                  },
                  icon: const Icon(Icons.info),
                  label: const Text('查看更多'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
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

  @override

  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 地图
          GoogleMap(
            initialCameraPosition: _initialCameraPosition,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            markers: _markers,
            onMapCreated: (controller) => _mapController = controller,
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
          // DraggableScrollableSheet + Filter bar
          if (_nearbyPlaces.isNotEmpty)
            DraggableScrollableSheet(
              initialChildSize: 0.4,
              minChildSize: 0.2,
              maxChildSize: 0.7,
              builder: (context, scrollController) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                    boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
                  ),
                  child: Column(
                    children: [
                      // 顶部的拉手
                      Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      // Filter bar
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
                                      Icon(cat['icon'], color: isSelected ? Colors.white : Colors.grey[600], size: 30),
                                      const SizedBox(height: 5),
                                      Text(cat['name'],
                                          style: TextStyle(
                                              color: isSelected ? Colors.white : Colors.grey[600],
                                              fontSize: 12,
                                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
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
                    
                      // Place 列表
                      Expanded(
  child: ListView.builder(
    controller: scrollController,
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    itemCount: _nearbyPlaces.length,
    itemBuilder: (context, index) {
      final place = _nearbyPlaces[index];
      final name = place['displayName']?['text'] ?? '未知地点';
      final rating = place['rating']; // double
      final photoUrl = place['photos'] != null && place['photos'].isNotEmpty 
          ? place['photos'][0]['photoUri'] 
          : null;

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
                  offset: const Offset(0, 4),
                ),
              ],
              border: Border.all(color: Colors.grey[100]!),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 左边照片或默认图标
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.blue[50],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: photoUrl != null
                        ? Image.network(photoUrl, fit: BoxFit.cover)
                        : Icon(Icons.location_on, color: Colors.blue[400], size: 26),
                  ),
                ),
                const SizedBox(width: 12),

                // 中间地点名
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // 右边评分
                if (rating != null)
                  Row(
                    children: [
                      const Icon(Icons.star, color: Colors.orange, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        rating.toString(),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    },
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
}