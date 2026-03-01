import 'dart:ui';

import '../place/detectPlacePage.dart';
import 'package:flutter/material.dart';
import 'bottomnav.dart';
import '../../services/location_service.dart';
import '../../services/placeModal.dart';
import '../../services/nearbyPlace_service.dart';
import 'package:geolocator/geolocator.dart';
import '../place/placeDetailPage.dart';
import 'package:geocoding/geocoding.dart';



// ================= MainPage  =================
class MainPage extends StatefulWidget {
  final dynamic username;


  const MainPage({super.key, required this.username});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {

  late PageController _pageController;
  List<PlaceModel> _nearbyPlaces = [];
  bool _loadingNearby = true;

  // ===== 天气状态（假数据）=====
  final String _weatherCondition = "sunny"; // sunny / cloudy / rainy
  final int _temperature = 19;
  String _currentLocationText = "Detecting your location...";


@override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(viewportFraction: 0.8);
    _initAndLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initAndLoad();
    }
  }

  Future<void> _initAndLoad() async {
    await _initLocation();
    await _loadNearby();
    _calculateRoutes();
  }

  Future<void> _initLocation() async {
    final status = await LocationService.instance.initLocation();

    switch (status) {
      case LocationStatus.serviceDisabled:
        _showLocationServiceDialog();
        return;

      case LocationStatus.permissionDenied:
        _showPermissionDialog();
        return;

      case LocationStatus.permissionDeniedForever:
        _showPermissionForeverDialog();
        return;

      case LocationStatus.success:
        break;
    }

    final pos = LocationService.instance.currentPosition;

    if (pos != null) {
      print('User location: ${pos.latitude}, ${pos.longitude}');

      final placemarks = await placemarkFromCoordinates(
        pos.latitude,
        pos.longitude,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;

        final city = place.locality ??
            place.subAdministrativeArea ??
            place.administrativeArea ??
            "Unknown";

        final country = place.country ?? "";

        setState(() {
          _currentLocationText =
              country.isNotEmpty ? "$city, $country" : city;
        });
      }
    }
  }

  void _showLocationServiceDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Location Disabled"),
        content: const Text(
            "Please enable location services to see nearby places."),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openLocationSettings();
            },
            child: const Text("Open Settings"),
          ),
        ],
      ),
    );
  }


  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Permission Required"),
        content: const Text(
            "Location permission is required to load nearby places."),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _initAndLoad(); // 🔥 重新尝试
            },
            child: const Text("Retry"),
          ),
        ],
      ),
    );
  }

  void _showPermissionForeverDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Permission Permanently Denied"),
        content: const Text(
            "Please enable location permission in app settings."),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openAppSettings();
            },
            child: const Text("Open App Settings"),
          ),
        ],
      ),
    );
  }

  // 保存每个地点的距离和预计用时
  Map<String, RouteResult> _routeResults = {};


  // ===== 根据天气决定 icon =====
  IconData _getWeatherIcon(String condition) {
    switch (condition) {
      case "cloudy":
        return Icons.cloud_rounded;
      case "rainy":
        return Icons.umbrella_rounded;
      case "sunny":
      default:
        return Icons.wb_sunny_rounded;
    }
  }

  // ===== Category =====

final List<Map<String, dynamic>> _categories = [
  {
    "label": "All",
    "type": "all",
    "icon": Icons.grid_view_rounded,
    "color": const Color(0xFFCCFBF1),
  },
  {
    "label": "Nature",
    "type": "park",
    "icon": Icons.park_rounded,
    "color": const Color(0xFFDCFCE7),
  },
  {
    "label": "Historical",
    "type": "tourist_attraction",
    "icon": Icons.account_balance_rounded,
    "color": const Color(0xFFFFEDD5),
  },
  {
    "label": "Shopping",
    "type": "shopping_mall",
    "icon": Icons.shopping_bag_rounded,
    "color": const Color(0xFFE0E7FF),
  },
  {
    "label": "Food",
    "type": "restaurant",
    "icon": Icons.restaurant_rounded,
    "color": const Color(0xFFFFE4E6),
  },
  {
    "label": "Entertainment",
    "type": "amusement_park",
    "icon": Icons.local_activity_rounded,
    "color": const Color(0xFFF3E8FF),
  },
  // {
  //   "label": "Stay",
  //   "type": "lodging",
  //   "icon": Icons.hotel_rounded,
  //   "color": const Color(0xFFBDE0FE),
  // },
  // {
  //   "label": "Cafe",
  //   "type": "cafe",
  //   "icon": Icons.local_cafe_rounded,
  //   "color": const Color(0xFFD6B4FF),
  // },
  // {
  //   "label": "Oil",
  //   "type": "gas_station",
  //   "icon": Icons.local_gas_station_rounded,
  //   "color": const Color(0xFFFFB3B3),
  // },
  // {
  //   "label": "Hospital",
  //   "type": "hospital",
  //   "icon": Icons.local_hospital_rounded,
  //   "color": const Color(0xFFFFA07A),
  // },
  // {
  //   "label": "Bank",
  //   "type": "bank",
  //   "icon": Icons.account_balance_rounded,
  //   "color": const Color(0xFF7FFFD4),
  // },
];

  String _selectedCategory = "All";

  // ✅ 移除硬编码，改为从真实数据动态生成
  // ✅ 正确版本
  Map<String, List<PlaceModel>> get _placeByCategory {
    if (_nearbyPlaces.isEmpty) return {"All": []};

    final Map<String, List<PlaceModel>> result = {"All": _nearbyPlaces};

    for (final category in _categories) {
      final type = category['type'] as String;
      if (type == 'all') continue;

      // ✅ 根据 primaryType 筛选
      result[category['label']] = _nearbyPlaces
          .where((p) => p.primaryType == type)
          .toList();
    }

    return result;
  }


 @override
  Widget build(BuildContext context) {
    return BasePage(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            _buildHeader(),
            const SizedBox(height: 25),
            const SizedBox(height: 20),
            _buildCategorySection(),
            const SizedBox(height: 30),

            _buildSectionHeader("Recommended Places", true),
            const SizedBox(height: 10),
            SizedBox(
              height: 320,
              child: _loadingNearby
                  ? const Center(child: CircularProgressIndicator())
                  : _placeByCategory[_selectedCategory]?.isEmpty ?? true
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.search_off,
                                  size: 48, color: Colors.grey[400]),
                              const SizedBox(height: 12),
                              Text(
                                'No places found in $_selectedCategory',
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        )
                      : PageView.builder(
                          controller: _pageController,
                          itemCount:
                              _placeByCategory[_selectedCategory]!.length,
                          physics: const BouncingScrollPhysics(),
                          itemBuilder: (context, index) {
                            return AnimatedBuilder(
                              animation: _pageController,
                              builder: (context, child) {
                                double value = 0;
                                if (_pageController.position.haveDimensions) {
                                  value = _pageController.page! - index;
                                }
                                return Transform(
                                  transform: Matrix4.identity()
                                    ..setEntry(3, 2, 0.001)
                                    ..rotateY(value * 0.4)
                                    ..scale(1 - (value.abs() * 0.1)),
                                  child: child,
                                );
                              },
                              child: _buildPlaceCard(index),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 20),

            _buildSectionHeader("Nearby Trending", false),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: _loadingNearby
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: List.generate(_nearbyTrending.length, (index) {
                        // 传入 index 来实现奇偶错位
                        return _buildSpecialAsymmetricCard(_nearbyTrending[index], index);
                      }),
                    ),
            ),
          ],
        ),
      ),
    );
  }


  // ✅ 改进后的加载方法
  Future<void> _loadNearby() async {
    setState(() => _loadingNearby = true);

    try {
      // 从 Service 获取真实数据
      final places = await NearbyPlacesService.instance
          .loadNearbyPlacesOnce(_categories);

      if (!mounted) return;

      setState(() {
        _nearbyPlaces = places;
        _loadingNearby = false;
      });
    } catch (e) {
      print("Load nearby error: $e");
      
      if (!mounted) return;

      setState(() {
        _loadingNearby = false;
      });

      // 可选：显示错误提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load nearby places: $e'),
          backgroundColor: Colors.red[400],
        ),
      );
    }
  }

   void _calculateRoutes() {
    final pos = LocationService.instance.currentPosition;
    if (pos == null || _nearbyPlaces.isEmpty) return;

    _routeResults.clear();
    for (final place in _nearbyPlaces) {
      if (place.lat != null && place.lng != null) {
        _routeResults[place.id!] =
            _calcRoute(pos.latitude!, pos.longitude!, place);
      }
    }
    setState(() {});
  }

  RouteResult _calcRoute(double lat, double lng, PlaceModel place) {
    final distanceMeters = Geolocator.distanceBetween(
      lat,
      lng,
      place.lat!,
      place.lng!,
    );
    final speed = 1.4; // walking speed in m/s
    final durationSeconds = (distanceMeters / speed).round();
    return RouteResult(
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
    );
  }

  List<PlaceModel> get _nearbyTrending {
    if (_nearbyPlaces.isEmpty) return [];
    final pos = LocationService.instance.currentPosition;
    if (pos == null) return [];
    final sorted = List<PlaceModel>.from(_nearbyPlaces)
      ..sort((a, b) {
        final distA = _routeResults[a.id]?.distanceMeters ?? double.infinity;
        final distB = _routeResults[b.id]?.distanceMeters ?? double.infinity;
        return distA.compareTo(distB);
      });
    return sorted.take(6).toList();
  }

    // Widget _buildNearbyCardWithDistance(PlaceModel place) {
    //   final route = _routeResults[place.id];
    //   final distanceKm = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";
    //   final durationMin = route != null ? (route.durationSeconds ~/ 60).toString() : "--";

    //   // 调用新的 _buildNearbyCard，传入格式化好的距离字符串
    //   return _buildNearbyCard(
    //     place.name ?? "",
    //     place.photoUrl ?? "",
    //     "$distanceKm km away • $durationMin mins walk", // 传入 distanceText
    //   );
    // }

  Widget _buildHeader() {
    return Stack(
      clipBehavior: Clip.none, 
      children: [
        // 1. 背景层
        Container(
          height: 260, 
          width: double.infinity,
          decoration: const BoxDecoration(
            image: DecorationImage(
              image: AssetImage('assets/images/longbg.jpg'),
              fit: BoxFit.cover,
            ),
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(30),
              bottomRight: Radius.circular(30),
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.6),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),

        // 2. 内容层
        SafeArea( 
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20), 
                
                // 顶部栏：Drawer + Location + Weather
                Row(
                  children: [
                    // --- 这里把 Drawer 按钮补回来了 ---
                    Builder(
                      builder: (context) => GestureDetector(
                        onTap: () => Scaffold.of(context).openDrawer(),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withOpacity(0.2)),
                          ),
                          child: const Icon(Icons.menu_rounded, color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                    
                    const SizedBox(width: 12), // 间隔一下

                    // 定位展示
                    Expanded( // 用 Expanded 包裹让它自动填充中间空间
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withOpacity(0.2)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.location_on_rounded, color: Colors.orangeAccent, size: 14),
                              const SizedBox(width: 4),
                              Flexible( // 防止地名太长溢出
                                child: Text(
                                  _currentLocationText,
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // 天气图标
                    Container(
                      margin: const EdgeInsets.only(left: 10),
                      decoration: const BoxDecoration(
                        boxShadow: [
                          BoxShadow(color: Colors.black26, blurRadius: 10)
                        ]
                      ),
                      child: Icon(_getWeatherIcon(_weatherCondition), color: Colors.amber, size: 24),
                    ),
                  ],
                ),
                
                const SizedBox(height: 48), 
                
                Text(
                  "Hello, ${widget.username.isEmpty ? "Traveler" : widget.username} 👋",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32, 
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const Text(
                  "Your next adventure starts here.",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),

        // 3. 搜索框
        Positioned(
          bottom: -28, 
          left: 20,
          right: 20,
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                const SizedBox(width: 15),
                const Icon(Icons.search_rounded, color: Color(0xFF6366F1), size: 24),
                const SizedBox(width: 10),
                const Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: "Explore new places...",
                      hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                Container(height: 20, width: 1, color: Colors.grey.shade200),
                IconButton(
                  icon: const Icon(Icons.tune_rounded, color: Color(0xFF6366F1), size: 20),
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
    
  
  Widget _buildCategorySection() {
    return SizedBox(
      height: 110,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 25),
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 18),
        itemBuilder: (context, index) {
          final category = _categories[index];
          final label = category["label"];
          final icon = category["icon"];
          final color = category["color"];
          final isSelected = label == _selectedCategory;

          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedCategory = label;
              });
            },
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: isSelected
                            ? Colors.black.withOpacity(0.15)
                            : Colors.black.withOpacity(0.05),
                        blurRadius: isSelected ? 10 : 6,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    icon,
                    size: 28,
                    color: isSelected
                        ? const Color.fromARGB(255, 194, 194, 199)
                        : Colors.black87,
                  ),

                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }



  Widget _buildSectionHeader(String title, bool showAll) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
          if (showAll) const Text("See All", style: TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildPlaceCard(int index) {
    final places = _placeByCategory[_selectedCategory] ?? [];
    if (index >= places.length) return const SizedBox();
    final place = places[index];
    final route = _routeResults[place.id];
    
    // 格式化距离和时间
    final distanceKm = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";
    final durationMin = route != null ? (route.durationSeconds ~/ 60).toString() : "--";

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(25),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 15,
              offset: const Offset(0, 8)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(25),
        child: Stack(
          children: [
            // ---- 背景图片 ----
            Positioned.fill(
              child: place.photoUrl != null
                  ? Image.network(place.photoUrl!, fit: BoxFit.cover)
                  : Container(color: Colors.indigo.shade50),
            ),

            // ---- 底部渐变遮罩 (为了看清文字) ----
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.05),
                      Colors.black.withOpacity(0.7),
                    ],
                  ),
                ),
              ),
            ),

            // ---- 右上角评分 (Stack) ----
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                    const SizedBox(width: 2),
                    Text(
                      (place.rating ?? 0.0).toStringAsFixed(1),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            // ---- 底部信息 ----
            Positioned(
              bottom: 15,
              left: 15,
              right: 15,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name ?? "Unknown",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.directions_walk, color: Colors.white70, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        "$distanceKm km • $durationMin min",
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildSpecialAsymmetricCard(PlaceModel place, int index) {
    final route = _routeResults[place.id];
    final dist = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";
    final time = route != null ? (route.durationSeconds ~/ 60).toString() : "--";
    
    bool isEven = index % 2 == 0;

    return GestureDetector(
      onTap: () async {
        if (place.id != null) {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlaceDetailPage(
                placeId: place.id!,
                lat: place.lat,
                lng: place.lng,
              ),
            ),
          );

          // ✅ 处理导航请求
          if (result != null && result['action'] == 'start_navigation') {
            // 打开 RealTimeDetectPage 并传入导航数据
            if (!mounted) return;
            
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RealTimeDetectPage(
                  landmarkLat: result['lat'],
                  landmarkLng: result['lng'],
                  onBack: () => Navigator.pop(context)
                ),
              ),
            );
          }
        }
      },
      
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // ✅ 修复点 1: 传入 place.id
            if (isEven) _buildImage(place.photoUrl ?? "", place.id), 
            
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  left: isEven ? 20 : 0,
                  right: isEven ? 0 : 20,
                  bottom: 10,
                ),
                child: Column(
                  crossAxisAlignment: isEven ? CrossAxisAlignment.start : CrossAxisAlignment.end,
                  children: [
                    Text(
                      "$dist KM",
                      style: TextStyle(
                        fontFamily: 'Courier', 
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF6366F1).withOpacity(0.2),
                      ),
                    ),
                    Text(
                      place.name ?? "未知地点",
                      textAlign: isEven ? TextAlign.left : TextAlign.right,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black, 
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        "$time MINS WALK",
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ✅ 修复点 2: 传入 place.id
            if (!isEven) _buildImage(place.photoUrl ?? "", place.id),
          ],
        ),
      ),
    );
  }
    
  
  // 独立的图片构建组件，增加漂浮感阴影
  Widget _buildImage(String url, String? placeId) {
  return Hero(
    tag: 'place-img-${placeId ?? UniqueKey()}', // 唯一的 Tag
    child: Container(
      width: 140,
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withOpacity(0.15),
            blurRadius: 20,
            offset: const Offset(5, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: url.isNotEmpty
            ? Image.network(url, fit: BoxFit.cover)
            : Container(color: Colors.grey[200], child: const Icon(Icons.broken_image)),
      ),
    ),
  );
}

}

  // ===== RouteResult =====
  class RouteResult {
    final double distanceMeters;
    final int durationSeconds;

    RouteResult({
      required this.distanceMeters,
      required this.durationSeconds,
    });
  }

