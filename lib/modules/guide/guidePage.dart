import 'dart:async';
import 'dart:convert';

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

  // 多选 filter
  List<String> _selectedTypes = ['all'];

  bool _isLoading = false;

  final String googleAPIKey = 'YOUR_API_KEY_HERE';

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
      zoom: 15,
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

  Future<void> _searchSelectedFilters() async {
    if (_currentPosition == null) return;

    setState(() {
      _isLoading = true;
      _nearbyPlaces.clear();
      _markers.removeWhere((m) => m.markerId.value != 'me');
    });

    List<String> typesToSearch = _selectedTypes.contains('all')
        ? categories.where((c) => c['type'] != 'all').map((c) => c['type'] as String).toList()
        : _selectedTypes;

    for (final type in typesToSearch) {
      await _searchNearbyPlaces(type);
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _searchNearbyPlaces(String type) async {
    final url =
        'https://maps.googleapis.com/maps/api/place/nearbysearch/json?'
        'location=${_currentPosition!.latitude},${_currentPosition!.longitude}'
        '&radius=5000&type=$type&key=$googleAPIKey';

    try {
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body);

      if (data['status'] == 'OK') {
        final results = List<Map<String, dynamic>>.from(data['results']);
        for (int i = 0; i < results.length; i++) {
          final place = results[i];
          final loc = place['geometry']['location'];
          final markerId = MarkerId(place['place_id'] ?? 'place_$i');

          if (_markers.any((m) => m.markerId == markerId)) continue;

          _markers.add(
            Marker(
              markerId: markerId,
              position: LatLng(loc['lat'], loc['lng']),
              infoWindow: InfoWindow(
                title: place['name'],
                snippet: place['vicinity'],
                onTap: () => _showPlaceDetails(place),
              ),
              onTap: () => _showPlaceDetails(place),
            ),
          );
        }

        for (var place in results) {
          if (!_nearbyPlaces.any((p) => p['place_id'] == place['place_id'])) {
            _nearbyPlaces.add(place);
          }
        }
      }
    } catch (e) {
      _showErrorDialog('搜索失败', e.toString());
    }
  }

  void _showPlaceDetails(Map<String, dynamic> place) {
    final loc = place['geometry']['location'];
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
            Text(place['name'], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.location_on, size: 20, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(child: Text(place['vicinity'] ?? '地址未知')),
              ],
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(LatLng(loc['lat'], loc['lng']), 16));
                },
                icon: const Icon(Icons.directions),
                label: const Text('开始导航'),
              ),
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
              child: CircleAvatar(
                backgroundColor: Colors.white,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
          // Filter bar
          Positioned(
            bottom: 120, // 离 BottomNavigationBar 上一点
            left: 0,
            right: 0,
            child: SizedBox(
              height: 100,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: categories.length,
                padding: const EdgeInsets.symmetric(horizontal: 10),
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
          ),
          if (_isLoading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
