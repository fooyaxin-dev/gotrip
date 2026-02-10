import 'dart:math';
import 'package:flutter/material.dart';
import 'bottomnav.dart';
import '../../services/location_service.dart';
import '../../services/placeModal.dart';
import '../../services/nearbyPlace_service.dart';
import 'package:geolocator/geolocator.dart';
import '../realtime/placeDetailPage.dart';


// ================= MainPage  =================
class MainPage extends StatefulWidget {
  final dynamic username;


  const MainPage({super.key, required this.username});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {

  late PageController _pageController;
  List<PlaceModel> _nearbyPlaces = [];
  bool _loadingNearby = true;

  // ===== 天气状态（假数据）=====
  final String _weatherCondition = "sunny"; // sunny / cloudy / rainy
  final int _temperature = 19;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.8);
    _initAndLoad();

  }

  Future<void> _initAndLoad() async {
    await _initLocation();
    await _loadNearby();
    _calculateRoutes();
  }


Future<void> _initLocation() async {
  try {
    await LocationService.instance.initLocation();
    final pos = LocationService.instance.currentPosition;
    print('User location: ${pos?.latitude}, ${pos?.longitude}');
  } catch (e) {
    print('Location error: $e');
  }
}


  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(25, 60, 25, 35),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4F46E5), Color(0xFF818CF8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(40),
          bottomRight: Radius.circular(40),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu_rounded, color: Colors.white),
                      onPressed: () {
                        Scaffold.of(context).openDrawer();
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Hello, ${widget.username.isEmpty ? "User" : widget.username} 👋",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        "Explore the world!",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      _getWeatherIcon(_weatherCondition),
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "$_temperature°C",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 25),
          InkWell(
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.location_searching_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 12),
                  Text("Detect where the user are", style: TextStyle(color: Colors.white, fontSize: 14)),
                  Spacer(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            decoration: InputDecoration(
              hintText: "Search places...",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white70),
              filled: true,
              fillColor: Colors.white.withOpacity(0.2),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
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


// Widget _buildNearbyCard(String name, String pic, String distanceText) {
//   return Container(
//     margin: const EdgeInsets.only(bottom: 16),
//     // 增加内部 Padding 让呼吸感更强
//     padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
//     decoration: BoxDecoration(
//       color: Colors.white,
//       borderRadius: BorderRadius.circular(24),
//       boxShadow: [
//         BoxShadow(
//           color: const Color(0xFF6366F1).withOpacity(0.06), // 使用主色调的超淡阴影
//           offset: const Offset(0, 8),
//           blurRadius: 24,
//         ),
//       ],
//     ),
//     child: Row(
//       children: [
//         // ---- 1. 照片 (固定比例，增加轻微阴影) ----
//         Container(
//           decoration: BoxDecoration(
//             borderRadius: BorderRadius.circular(18),
//             boxShadow: [
//               BoxShadow(
//                 color: Colors.black.withOpacity(0.08),
//                 blurRadius: 8,
//                 offset: const Offset(0, 4),
//               )
//             ],
//           ),
//           child: ClipRRect(
//             borderRadius: BorderRadius.circular(18),
//             child: pic.isNotEmpty
//                 ? Image.network(
//                     pic,
//                     width: 80, 
//                     height: 80, 
//                     fit: BoxFit.cover,
//                   )
//                 : Container(
//                     width: 80,
//                     height: 80,
//                     color: const Color(0xFFF1F5F9),
//                     child: const Icon(Icons.map_outlined, color: Color(0xFF94A3B8)),
//                   ),
//           ),
//         ),
        
//         const SizedBox(width: 18),
        
//         // ---- 2. 名字 & 距离用时组合 ----
//         Expanded(
//           child: Column(
//             crossAxisAlignment: CrossAxisAlignment.start,
//             mainAxisSize: MainAxisSize.min,
//             children: [
//               // 名字：字体稍微拉大，颜色使用 Slate-800 更有质感
//               Text(
//                 name,
//                 style: const TextStyle(
//                   fontWeight: FontWeight.w800,
//                   fontSize: 16,
//                   color: Color(0xFF1E293B),
//                   letterSpacing: -0.3,
//                 ),
//                 maxLines: 1,
//                 overflow: TextOverflow.ellipsis,
//               ),
              
//               const SizedBox(height: 10),
              
//               // 距离与用时：使用横向并列的图标，看起来更清晰
//               Row(
//                 children: [
//                   // 距离
//                   _buildMiniInfoTag(Icons.location_on_rounded, distanceText.split("away").first.trim()),
//                   const SizedBox(width: 8),
//                   // 用时
//                   _buildMiniInfoTag(Icons.access_time_filled_rounded, distanceText.split("•").last.trim()),
//                 ],
//               ),
//             ],
//           ),
//         ),

//         // 右侧引导箭头
//         Icon(Icons.chevron_right_rounded, color: Colors.grey[300], size: 28),
//       ],
//     ),
//   );
// }


Widget _buildSpecialAsymmetricCard(PlaceModel place, int index) {
  final route = _routeResults[place.id];
  final dist = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";
  final time = route != null ? (route.durationSeconds ~/ 60).toString() : "--";
  
  bool isEven = index % 2 == 0;

  return GestureDetector(
    onTap: () {
      if (place.id != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PlaceDetailPage(
              placeId: place.id!,
              lat: place.lat,
              lng: place.lng,
            ),
          ),
        );
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

