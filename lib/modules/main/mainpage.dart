

import 'package:flutter/material.dart';
import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'bottomnav.dart';
import '../place/detectPlacePage.dart';
import '../place/placeDetailPage.dart';
import 'package:geocoding/geocoding.dart';
import '../../services/route_service.dart';
import '../../services/location_service.dart';
import '../../models/placeModal.dart';
import '../../services/nearbyPlace_service.dart';
import '../../services/userPreference_service.dart'; 

class MainPage extends StatefulWidget {
  final dynamic username;
  const MainPage({super.key, required this.username});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {

  late PageController _pageController;
  List<PlaceModel> _nearbyPlaces    = [];
  List<PlaceModel> _forYouPlaces    = []; 
  bool _loadingNearby               = true;

  final String _weatherCondition    = "sunny";
  final int _temperature            = 19;
  String _currentLocationText       = "Detecting your location...";

  Map<String, RouteResult> _routeResults = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(viewportFraction: 0.8);
    _initAndLoad();

    UserPreferenceService.instance.preferencesChanged.addListener(_onPreferencesChanged);
  }

  void _onPreferencesChanged() {
    if (mounted) _buildForYou();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    UserPreferenceService.instance.preferencesChanged.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!NearbyPlacesService.instance.hasLoaded) {
        _initAndLoad();
      } else {
        _buildForYou(); // ← 加这行，resume 时重新计算 For You
      }
    }
  }

  Future<void> _initAndLoad() async {
    await _initLocation();
    await _loadNearby();
    _calculateRoutes();
    _buildForYou(); 
  }

  Future<void> _initLocation() async {
    final status = await LocationService.instance.initLocation();
    switch (status) {
      case LocationStatus.serviceDisabled:
        _showLocationServiceDialog(); return;
      case LocationStatus.permissionDenied:
        _showPermissionDialog(); return;
      case LocationStatus.permissionDeniedForever:
        _showPermissionForeverDialog(); return;
      case LocationStatus.success:
        break;
    }

    final pos = LocationService.instance.currentPosition;
    if (pos != null) {
      final placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final city    = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? "Unknown";
        final country = p.country ?? "";
        setState(() {
          _currentLocationText = country.isNotEmpty ? "$city, $country" : city;
        });
      }
    }
  }

  double get _distanceLimitMeters {
    final mode = UserPreferenceService.instance.current.travelMode;
    switch (mode) {
      case 'walk':  return 2000;
      case 'drive': return 20000;
      default:      return 10000;
    }
  }

  String get _distanceLimitLabel {
    final mode = UserPreferenceService.instance.current.travelMode;
    switch (mode) {
      case 'walk':  return 'within 2 km (walking)';
      case 'drive': return 'within 20 km (driving)';
      default:      return 'within 10 km';
    }
  }

  IconData get _travelModeIcon {
    switch (UserPreferenceService.instance.current.travelMode) {
      case 'drive': return Icons.directions_car_rounded;
      case 'walk':  return Icons.directions_walk_rounded;
      default:      return Icons.near_me_rounded;
    }
  }

  // ─────────────────────────────────────────────
  // For You — 根据 preferences 评分排序
  // ─────────────────────────────────────────────

  Future<void> _buildForYou() async {
    await UserPreferenceService.instance.load();
    if (_nearbyPlaces.isEmpty) return;

    final limit = _distanceLimitMeters;

    const allowedTypes = {
      'restaurant',
      'park',
      'entertainment',
      'shopping_mall',
    };

    final withinRange = _nearbyPlaces.where((place) {
      final dist = _routeResults[place.id]?.distanceMeters ?? double.infinity;
      final isAllowed = allowedTypes.contains(place.primaryType) ||
          place.allTypes.any((t) => allowedTypes.contains(t));
      return dist <= limit &&
          place.photoUrl != null &&
          place.photoUrl!.isNotEmpty &&
          isAllowed;
    }).toList();

    // 评分
    final scored = withinRange.map((place) {
      final dist  = _routeResults[place.id]?.distanceMeters;
      final score = UserPreferenceService.instance.scorePlaceModel(
        primaryType:    place.primaryType,
        allTypes:       place.allTypes,
        distanceMeters: dist,
      );
      return MapEntry(place, score);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));


    print('🔍 ForYou withinRange: ${withinRange.length}');
    for (final p in withinRange) {
      print('  ${p.name} | primary: ${p.primaryType} | types: ${p.allTypes.take(3)}');
    }


    // 过滤 score = 0，最多 7 个
    final filtered = scored
        .where((e) => e.value > 0)
        .map((e) => e.key)
        .take(7)
        .toList();

    // Fallback：距离内、有照片、评分高
    final result = filtered.isNotEmpty
        ? filtered
        : (List<PlaceModel>.from(withinRange)
            ..removeWhere((p) => p.photoUrl == null || p.photoUrl!.isEmpty)
            ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0)))
            .take(7)
            .toList();

    setState(() => _forYouPlaces = result);
  }

  // ─────────────────────────────────────────────
  // Load nearby
  // ─────────────────────────────────────────────

  Future<void> _loadNearby() async {
    setState(() => _loadingNearby = true);
    try {
      final places = await NearbyPlacesService.instance
          .loadNearbyPlacesOnce(_categories, context);
      if (!mounted) return;
      setState(() {
        _nearbyPlaces    = places;
        _loadingNearby   = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingNearby = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load nearby places: $e'),
            backgroundColor: Colors.red[400]),
      );
    }
  }

  void _calculateRoutes() {
    final pos = LocationService.instance.currentPosition;
    if (pos == null || _nearbyPlaces.isEmpty) return;
    _routeResults.clear();
    for (final place in _nearbyPlaces) {
      if (place.lat != null && place.lng != null) {
        _routeResults[place.id] = _calcRoute(pos.latitude, pos.longitude, place);
      }
    }
    setState(() {});
  }

  RouteResult _calcRoute(double lat, double lng, PlaceModel place) {
    final dist = Geolocator.distanceBetween(lat, lng, place.lat!, place.lng!);
    final mode = UserPreferenceService.instance.current.travelMode;

    // 直线距离 × 迂回系数 = 实际路程估算
    final driveRoad = dist * 1.4;  // 驾车实际路程约是直线的 1.4 倍
    final walkRoad  = dist * 1.2;  // 走路实际路程约是直线的 1.2 倍

    final driveSecs = (driveRoad / 8.3).round();  // 8.3 m/s ≈ 30 km/h 城市均速
    final walkSecs  = (walkRoad / 1.4).round();   // 1.4 m/s ≈ 5 km/h

    return RouteResult(
      polylinePoints: const [],
      steps: const [],
      bounds: LatLngBounds(
        southwest: LatLng(
          min(lat, place.lat!),
          min(lng, place.lng!),
        ),
        northeast: LatLng(
          max(lat, place.lat!),
          max(lng, place.lng!),
        ),
      ),
      distanceMeters: dist,
      durationSeconds: mode == 'walk' ? walkSecs : driveSecs,
      walkDurationSeconds: mode == 'both' ? walkSecs : null,
    );
    
  }

  String _formatDuration(String placeId) {
    final route = _routeResults[placeId];
    if (route == null) return "--";
    final mode = UserPreferenceService.instance.current.travelMode;
    final mainMins = (route.durationSeconds ~/ 60).toString();

    if (mode == 'both' && route.walkDurationSeconds != null) {
      final walkMins = (route.walkDurationSeconds! ~/ 60).toString();
      return '$mainMins min drive • $walkMins min walk';
    }

    return mode == 'walk' ? '$mainMins min walk' : '$mainMins min drive';
  }


  // ─────────────────────────────────────────────
  // Categories & filter
  // ─────────────────────────────────────────────

  final List<Map<String, dynamic>> _categories = [
    {"label": "All",          "type": "all",           "icon": Icons.grid_view_rounded,      "color": const Color(0xFFCCFBF1)},
    {"label": "Food",         "type": "restaurant",    "icon": Icons.restaurant_rounded,     "color": const Color(0xFFFFE4E6)},
    {"label": "Nature",       "type": "park",          "icon": Icons.park_rounded,           "color": const Color(0xFFDCFCE7)},
    {"label": "Entertain",    "type": "entertainment", "icon": Icons.local_activity_rounded, "color": const Color(0xFFF3E8FF)},
    {"label": "Shopping",     "type": "shopping_mall", "icon": Icons.shopping_bag_rounded,   "color": const Color(0xFFE0E7FF)},
    {"label": "Transport",    "type": "transit",       "icon": Icons.directions_transit,     "color": const Color(0xFFDBEAFE)},
    {"label": "Service",      "type": "service",       "icon": Icons.miscellaneous_services, "color": const Color(0xFFCCFBF1)},
  ];

  String _selectedCategory = "All";

  Map<String, List<PlaceModel>> get _placeByCategory {
    if (_nearbyPlaces.isEmpty) return {"All": []};
    final Map<String, List<PlaceModel>> result = {"All": _nearbyPlaces};
    for (final category in _categories) {
      final type = category['type'] as String;
      if (type == 'all') continue;
      result[category['label']] = _nearbyPlaces
          .where((p) => p.primaryType == type).toList();
    }
    return result;
  }

  List<PlaceModel> get _nearbyTrending {
    if (_nearbyPlaces.isEmpty) return [];
    final pos = LocationService.instance.currentPosition;
    if (pos == null) return [];

    const allowedTypes = {
      'restaurant',
      'park',
      'entertainment',
      'shopping_mall',
      'tourist_attraction',
    };

    final sorted = List<PlaceModel>.from(_nearbyPlaces)
      ..removeWhere((p) =>
          p.photoUrl == null ||
          p.photoUrl!.isEmpty ||
          (!allowedTypes.contains(p.primaryType) &&
          !p.allTypes.any((t) => allowedTypes.contains(t))))  
      ..sort((a, b) {
        final distA = _routeResults[a.id]?.distanceMeters ?? double.infinity;
        final distB = _routeResults[b.id]?.distanceMeters ?? double.infinity;
        return distA.compareTo(distB);
      });
    return sorted.take(6).toList();
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

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

            // ── 1. For You ──────────────────────
            _buildSectionHeader("✨ For You", false),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: Row(
                children: [
                  Icon(Icons.near_me_rounded, size: 12, color: Colors.grey[400]),
                  const SizedBox(width: 4),
                  Text(
                    'Showing places $_distanceLimitLabel',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _buildForYouSection(),
            const SizedBox(height: 28),

            // ── 2. Browse by Category ───────────
            
            _buildSectionHeader("Recommended Places", true),
            const SizedBox(height: 10),
            _buildCategorySection(),
            
            SizedBox(
              height: 320,
              child: _loadingNearby
                  ? const Center(child: CircularProgressIndicator())
                  : _placeByCategory[_selectedCategory]?.isEmpty ?? true
                      ? Center(child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 12),
                            Text('No places found in $_selectedCategory',
                                style: TextStyle(color: Colors.grey[600])),
                          ],
                        ))
                      : PageView.builder(
                          controller: _pageController,
                          itemCount: _placeByCategory[_selectedCategory]!.length,
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

            // ── 3. Nearby Trending ───────────────
            _buildSectionHeader("Nearby Trending", false),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: _loadingNearby
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: List.generate(_nearbyTrending.length, (i) =>
                          _buildSpecialAsymmetricCard(_nearbyTrending[i], i)),
                    ),
            ),

            SizedBox(height: 10 + MediaQuery.of(context).padding.bottom + kBottomNavigationBarHeight),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // For You Section
  // ─────────────────────────────────────────────

  Widget _buildForYouSection() {
      if (_loadingNearby) {
        return const SizedBox(
          height: 200,
          child: Center(child: CircularProgressIndicator()),
        );
      }

      if (_forYouPlaces.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 25),
          child: Container(
            height: 120,
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.explore_outlined, size: 32, color: Colors.grey[400]),
                  const SizedBox(height: 8),
                  Text('No matching places $_distanceLimitLabel',
                      style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Try updating your preferences in Settings',
                      style: TextStyle(color: Colors.grey[400], fontSize: 11)),
                ],
              ),
            ),
          ),
        );
      }

      return SizedBox(
        height: 220,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 25),
          itemCount: _forYouPlaces.length,
          itemBuilder: (context, index) {
            return _buildForYouCard(_forYouPlaces[index]);
          },
        ),
      );
    }

  Widget _buildForYouCard(PlaceModel place) {
    final route = _routeResults[place.id];
    final dist  = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";
    final mins  = route != null ? (route.durationSeconds ~/ 60).toString() : "--";

    // 算分显示 match badge
    final score = UserPreferenceService.instance.scorePlaceModel(
      primaryType: place.primaryType,
      allTypes:    place.allTypes,
    );

    final reason = UserPreferenceService.instance.getRecommendReason(
      primaryType: place.primaryType,
      allTypes:    place.allTypes,
    );

    final isHighMatch = score >= 10;

    return GestureDetector(
      onTap: () => _openPlaceDetail(place),
      child: Container(
        width: 180,
        margin: const EdgeInsets.only(right: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1),
                blurRadius: 12, offset: const Offset(0, 6)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              // 背景图
              Positioned.fill(
                child: place.photoUrl != null && place.photoUrl!.isNotEmpty
                    ? Image.network(
                        place.photoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _buildPlaceholderBg(place), // ← 网络错误也有 fallback
                      )
                    : _buildPlaceholderBg(place),
              ),

              // 渐变遮罩
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.7),
                      ],
                    ),
                  ),
                ),
              ),

              // Match badge
              if (isHighMatch)
                Positioned(
                  top: 10, left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C4DFF),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.favorite_rounded, color: Colors.white, size: 10),
                        SizedBox(width: 4),
                        Text('For You', style: TextStyle(
                            color: Colors.white, fontSize: 10,
                            fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),

              // 评分
              if (place.rating != null)
                Positioned(
                  top: 10, right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
                        const SizedBox(width: 2),
                        Text(place.rating!.toStringAsFixed(1),
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),

              // 底部信息
              Positioned(
                bottom: 12, left: 12, right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    if (reason != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(reason,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 10)),
                      ),
                    Text(place.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.straighten_rounded, color: Colors.white70, size: 12),
                      const SizedBox(width: 3),
                      Text('~$dist km away',
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderBg(PlaceModel place) {
    
    const typeConfig = {
      'restaurant':    {'color': Color(0xFFFFE4E6), 'icon': Icons.restaurant_rounded},
      'park':          {'color': Color(0xFFDCFCE7), 'icon': Icons.park_rounded},
      'entertainment': {'color': Color(0xFFF3E8FF), 'icon': Icons.local_activity_rounded},
      'shopping_mall': {'color': Color(0xFFE0E7FF), 'icon': Icons.shopping_bag_rounded},
      'transit':       {'color': Color(0xFFDBEAFE), 'icon': Icons.directions_transit},
      'service':       {'color': Color(0xFFCCFBF1), 'icon': Icons.miscellaneous_services},
    };

    final config = typeConfig[place.primaryType] ?? 
        {'color': const Color(0xFFE8E8E8), 'icon': Icons.location_on_rounded};

    return Container(
      color: config['color'] as Color,
      child: Center(
        child: Icon(
          config['icon'] as IconData,
          size: 48,
          color: (config['color'] as Color).withOpacity(0.5),  // 淡淡的图标
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Helper: open place detail
  // ─────────────────────────────────────────────

  Future<void> _openPlaceDetail(PlaceModel place) async {
    final pos = LocationService.instance.currentPosition;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceDetailPage(
          placeId: place.id,
          lat: place.lat,
          lng: place.lng,
          userLat: pos?.latitude,
          userLng: pos?.longitude,
        ),
      ),
    );
    if (result != null && result['action'] == 'start_navigation' && mounted) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => RealTimeDetectPage(
          landmarkLat: result['lat'],
          landmarkLng: result['lng'],
          onBack: () => Navigator.pop(context),
        ),
      ));
    }
  }

  // ─────────────────────────────────────────────
  // Existing widgets (unchanged)
  // ─────────────────────────────────────────────

  IconData _getWeatherIcon(String condition) {
    switch (condition) {
      case "cloudy": return Icons.cloud_rounded;
      case "rainy":  return Icons.umbrella_rounded;
      default:       return Icons.wb_sunny_rounded;
    }
  }

  void _showLocationServiceDialog() {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text("Location Disabled"),
      content: const Text("Please enable location services to see nearby places."),
      actions: [TextButton(
        onPressed: () { Navigator.pop(context); Geolocator.openLocationSettings(); },
        child: const Text("Open Settings"),
      )],
    ));
  }

  void _showPermissionDialog() {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text("Permission Required"),
      content: const Text("Location permission is required to load nearby places."),
      actions: [TextButton(
        onPressed: () { Navigator.pop(context); _initAndLoad(); },
        child: const Text("Retry"),
      )],
    ));
  }

  void _showPermissionForeverDialog() {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text("Permission Permanently Denied"),
      content: const Text("Please enable location permission in app settings."),
      actions: [TextButton(
        onPressed: () { Navigator.pop(context); Geolocator.openAppSettings(); },
        child: const Text("Open App Settings"),
      )],
    ));
  }

  Widget _buildHeader() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
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
                colors: [Colors.black.withOpacity(0.6), Colors.transparent],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                Row(
                  children: [
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
                    const SizedBox(width: 12),
                    Expanded(
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
                            Flexible(
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
                    // Container(
                    //   margin: const EdgeInsets.only(left: 10),
                    //   child: Icon(_getWeatherIcon(_weatherCondition), color: Colors.amber, size: 24),
                    // ),
                  ],
                ),
                const SizedBox(height: 48),
                Text(
                  "Hello ${widget.username.isEmpty ? "" : widget.username} 👋",
                  style: const TextStyle(
                    color: Colors.white, fontSize: 32,
                    fontWeight: FontWeight.w900, letterSpacing: 0.8,
                  ),
                ),
                const Text(
                  "Your next adventure starts here.",
                  style: TextStyle(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.w300, letterSpacing: 0.5),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: -28, left: 20, right: 20,
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 20, offset: const Offset(0, 10),
              )],
            ),
            child: GestureDetector(
            onTap: () => _goToDetect(),
            child: Row(
              children: [
                const SizedBox(width: 15),
                const Icon(Icons.search_rounded, color: Color(0xFF6366F1), size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _goToDetect(),
                    child: const TextField(
                      enabled: false,
                      decoration: InputDecoration(
                        hintText: "Explore new places...",
                        hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                Container(height: 20, width: 1, color: Colors.grey.shade200),
                
              ],
            ),
          ),
        ),
        ),
      ],
    );
  }

  void _goToDetect() {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => RealTimeDetectPage(
        autoFocusSearch: true, 
        onBack: () => Navigator.pop(context),
      ),
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
          final cat       = _categories[index];
          final label     = cat["label"];
          final isSelected = label == _selectedCategory;
          return GestureDetector(
            onTap: () => setState(() {
              _selectedCategory = label;
              _pageController.jumpToPage(0);  
            }),
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 64, height: 64,
                  decoration: BoxDecoration(
                    color: cat["color"],
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(
                      color: isSelected
                          ? Colors.black.withOpacity(0.15)
                          : Colors.black.withOpacity(0.05),
                      blurRadius: isSelected ? 10 : 6,
                      offset: const Offset(0, 4),
                    )],
                  ),
                  child: Icon(cat["icon"], size: 28,
                      color: isSelected
                          ? const Color.fromARGB(255, 194, 194, 199)
                          : Colors.black87),
                ),
                const SizedBox(height: 8),
                Text(label, style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: Colors.grey.shade800,
                )),
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
          Text(title, style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
         
        ],
      ),
    );
  }

  Widget _buildPlaceCard(int index) {
    final places = _placeByCategory[_selectedCategory] ?? [];
    if (index >= places.length) return const SizedBox();
    final place = places[index];
    final route = _routeResults[place.id];
    final dist  = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";


    return GestureDetector(
      onTap: () => _openPlaceDetail(place),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(25),
          boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 15, offset: const Offset(0, 8))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(25),
          child: Stack(
            children: [
              Positioned.fill(
                child: place.photoUrl != null
                    ? Image.network(place.photoUrl!, fit: BoxFit.cover)
                    : Container(color: Colors.indigo.shade50),
              ),
              Positioned.fill(child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent,
                      Colors.black.withOpacity(0.05),
                      Colors.black.withOpacity(0.7)],
                  ),
                ),
              )),
              Positioned(
                top: 12, right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    const Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                    const SizedBox(width: 2),
                    Text((place.rating ?? 0.0).toStringAsFixed(1),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ]),
                ),
              ),
              Positioned(
                bottom: 15, left: 15, right: 15,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name,
                        style: const TextStyle(color: Colors.white, fontSize: 18,
                            fontWeight: FontWeight.bold),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.straighten_rounded, color: Colors.white70, size: 14),
                      const SizedBox(width: 4),
                      Text('~$dist km away',
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpecialAsymmetricCard(PlaceModel place, int index) {
    final route  = _routeResults[place.id];
    final dist   = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";
    final isEven = index % 2 == 0;

    return GestureDetector(
      onTap: () => _openPlaceDetail(place),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (isEven) _buildImage(place.photoUrl ?? "", place.id),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                    left: isEven ? 20 : 0, right: isEven ? 0 : 20, bottom: 10),
                child: Column(
                  crossAxisAlignment: isEven ? CrossAxisAlignment.start : CrossAxisAlignment.end,
                  children: [
                    Text("$dist KM", style: TextStyle(
                        fontFamily: 'Courier', fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF6366F1).withOpacity(0.2))),
                    Text(place.name,
                        textAlign: isEven ? TextAlign.left : TextAlign.right,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B), height: 1.2)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.black, borderRadius: BorderRadius.circular(5)),
                      child: Text('~$dist KM AWAY',
                          style: const TextStyle(color: Colors.white, fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
            if (!isEven) _buildImage(place.photoUrl ?? "", place.id),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(String url, String placeId) {
    return Hero(
      tag: 'place-img-$placeId',
      child: Container(
        width: 140, height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(
            color: const Color(0xFF6366F1).withOpacity(0.15),
            blurRadius: 20, offset: const Offset(5, 10),
          )],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: url.isNotEmpty
              ? Image.network(url, fit: BoxFit.cover)
              : Container(color: Colors.grey[200],
                  child: const Icon(Icons.broken_image)),
        ),
      ),
    );
  }
}