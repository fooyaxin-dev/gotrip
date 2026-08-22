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
import '../../models/placeModel.dart';
import '../../services/nearbyPlace_service.dart';
import '../../services/userPreference_service.dart';
import '../../services/achievement_service.dart';
import '../dashboard/dashboard_page.dart';
import '../../services/categoryImage_Helper.dart';
import '../../services/apps_Loading.dart';
import 'allRecommendedPlacesPage.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/error_handler.dart';
import '../../services/weather_service.dart';
import '../../services/dialog_helper.dart';

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
    List<PlaceModel> get _openNearbyPlaces =>
      _nearbyPlaces.where((p) => p.isOpenNow != false).toList();

  // ── Achievement banner ──
  AchievementTier? _latestBadge;

  WeatherCondition? _currentWeather;
  String _currentLocationText       = "Detecting your location...";

  Map<String, RouteResult> _routeResults = {};
  String? _travelModeOverride;   // 🆕 仅本次 session 有效的临时覆盖，不写回 Firestore

  String get _effectiveTravelMode =>
      _travelModeOverride ?? UserPreferenceService.instance.current.travelMode;

  // 🆕 travel-mode tier order for progressive widening (walk → motor → drive)
  static const List<String> _travelModeOrder = ['walk', 'motor', 'drive'];

  // 🆕 next wider tier than current effective mode, or null if already at max
  String? get _nextWiderTravelMode {
    final current = _effectiveTravelMode;
    if (current == 'both') return null; // 'both' 已按最大范围处理
    final idx = _travelModeOrder.indexOf(current);
    if (idx == -1 || idx == _travelModeOrder.length - 1) return null;
    return _travelModeOrder[idx + 1];
  }

  // 🆕 button label for a given target mode
  String _labelForMode(String mode) {
    switch (mode) {
      case 'motor': return '8 km (Motor)';
      case 'drive': return '12 km (Drive)';
      default:      return mode;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(viewportFraction: 0.8);
    _initAndLoad();
    LocationService.instance.addListener(_onLocationChanged);
    UserPreferenceService.instance.preferencesChanged.addListener(_onPreferencesChanged); 
    WeatherService.instance.weatherChanged.addListener(_onWeatherChanged); 
    _loadTopBadge();
  }
  
  void _onWeatherChanged() {
    if (!mounted) return;
    setState(() => _currentWeather = WeatherService.instance.current); // 🆕 天气缓存更新时同步刷新显示
    _buildForYou();
  }

  Future<void> _loadTopBadge() async {
    final tier = await AchievementService.instance.fetchTopBadge();
    if (mounted && tier != null) {
      setState(() => _latestBadge = tier);
    }
    // Fallback sync: ensure users/{uid}.topBadge* in Firestore always
    // matches the current fetchTopBadge() result. This covers accounts
    // whose thresholds were already crossed before the check-in write
    // existed, or where a previous check-in's write was missed — those
    // cases never trigger via checkForNewUnlocks(), since nothing "new"
    // is detected on the next check-in either.
    AchievementService.instance.saveTopBadgeToFirestore();
  }

  void _onLocationChanged() {
    if (!mounted) return;
    NearbyPlacesService.instance.clearCache();
    
    // telling user we're updating nearby places
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(children: [
          Icon(Icons.location_on_rounded, color: Colors.white, size: 16),
          SizedBox(width: 8),
          Text('Updating nearby places...'),
        ]),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF6366F1),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    
    _initAndLoad();
  }

  void _onPreferencesChanged() {
    if (mounted) _buildForYou();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    LocationService.instance.removeListener(_onLocationChanged);
    UserPreferenceService.instance.preferencesChanged.removeListener(_onPreferencesChanged);
    WeatherService.instance.weatherChanged.removeListener(_onWeatherChanged); 
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!NearbyPlacesService.instance.hasLoaded) {
        _initAndLoad();
      } else {
        _buildForYou(); 
      }
    }
  }

  Future<void> _initAndLoad() async {
    _travelModeOverride = null;
    NearbyPlacesService.instance.clearCache(); 
    await _initLocation();
    await UserPreferenceService.instance.load();   // 🆕 提前到这里，确保 radius 计算时用的是真实数据
    await _loadNearby();
    _calculateRoutes();
    _buildForYou();   // 内部的 load() 调用变成幂等的重复调用，不影响正确性，但可以顺手拿掉
    final pos = LocationService.instance.currentPosition;
    if (pos != null) {
      final w = await WeatherService.instance.getCurrentCondition(lat: pos.latitude, lng: pos.longitude); // 🔧 加 await + 接收返回值
      if (mounted) setState(() => _currentWeather = w);
    }

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

  double get _distanceLimitMeters =>
      radiusForTravelModeString(_effectiveTravelMode).toDouble();

  String get _distanceLimitLabel {
    switch (_effectiveTravelMode) {
      case 'walk':  return 'within 2 km (walking)';
      case 'motor': return 'within 8 km (motor)';     // 🆕
      case 'drive': return 'within 12 km (driving)';  // 🔧 20 km → 12 km
      default:      return 'within 12 km';            // 'both' 落在这，跟 drive 一致
    }
  }

  IconData get _travelModeIcon {
    switch (UserPreferenceService.instance.current.travelMode) {
      case 'drive': return Icons.directions_car_rounded;
      case 'motor': return Icons.motorcycle;          // 🆕
      case 'walk':  return Icons.directions_walk_rounded;
      default:      return Icons.near_me_rounded;     // 'both' 落在这
    }
  }

  Future<void> _refreshWeather() async {
    final pos = LocationService.instance.currentPosition;
    if (pos == null) return;
    final w = await WeatherService.instance.getCurrentCondition(
      lat: pos.latitude,
      lng: pos.longitude,
    );
    if (mounted) {
      setState(() => _currentWeather = w);
      _buildForYou(); // 拿到天气后重新算一次分数排序
    }
  }

  // ─────────────────────────────────────────────
  // For You — 根据 preferences 评分排序
  // ─────────────────────────────────────────────

  Future<void> _buildForYou() async {
    // 🔧 FIX: 去掉了 load() —— current 已经是内存里最新的偏好数据了。
    // 之前每次调用 _buildForYou 都会重新 load()，而 load() 结尾会
    // preferencesChanged.value++，这会触发 _onPreferencesChanged()
    // 再次调用 _buildForYou() → 又 load() → 又 +1 → 又触发...
    // 形成死循环，这就是你之前看到 log 无限刷屏、根本停不下来的原因。
    // 首次进页面时 _initAndLoad() 已经显式 load() 过一次，够用了。
    if (_nearbyPlaces.isEmpty) {
      setState(() => _forYouPlaces = []);
      return;
    }

    final result = UserPreferenceService.instance.buildForYouList(
      candidates:           _openNearbyPlaces,
      routeResults:         _routeResults,
      distanceLimitMeters:  _distanceLimitMeters,
      weather:              WeatherService.instance.current, 
      requirePhoto:         true,   // MainPage 的卡片需要图
    );

    setState(() => _forYouPlaces = result.places);
  }
    
  // ─────────────────────────────────────────────
  // Load nearby
  // ─────────────────────────────────────────────

  Future<void> _loadNearby() async {
    setState(() => _loadingNearby = true);
    try {
      final places = await NearbyPlacesService.instance
          .loadNearbyPlacesOnce(_categories, context, radius: _distanceLimitMeters.toInt(),);
      if (!mounted) return;
      setState(() {
        _nearbyPlaces    = places; 
        _loadingNearby   = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingNearby = false);
      ErrorHandler.showError(
        context,
        message: 'Failed to load nearby places. Pull down to refresh.',
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
    final mode = _effectiveTravelMode;

    final driveRoad = dist * 1.4; 
    final walkRoad  = dist * 1.2;  

    final driveSecs = (driveRoad / 8.3).round();  // 8.3 m/s ≈ 30 km/h 
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
    final mode = _effectiveTravelMode;
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
    final openPlaces = _openNearbyPlaces;   // 🔧 CHANGED
    final Map<String, List<PlaceModel>> result = {"All": openPlaces};
    for (final category in _categories) {
      final type = category['type'] as String;
      if (type == 'all') continue;
      result[category['label']] = openPlaces   // 🔧 CHANGED
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

      final sorted = List<PlaceModel>.from(_openNearbyPlaces)   // 🔧 CHANGED
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
    
    
  void _openAllForYou() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AllRecommendedPlacesPage(
          places:       _forYouPlaces,
          routeResults: _routeResults,
        ),
      ),
    );
  }

  // 🔧 CHANGED — 现在按 tier 递进 (walk → motor → drive)，接收目标 mode，
  // 而不是每次都硬编码跳到 'drive'。只在本次 session 生效，不覆盖用户在
  // Settings 里保存的真正偏好。
  Future<void> _tryWiderTravelMode(String targetMode) async {
    setState(() {
      _travelModeOverride = targetMode;
      _loadingNearby = true;
    });

    NearbyPlacesService.instance.clearCache();
    try {
      final places = await NearbyPlacesService.instance.loadNearbyPlacesOnce(
        _categories, context,
        radius: _distanceLimitMeters.toInt(),   // 🆕 按新 targetMode 对应的半径去拉数据
      );
      if (!mounted) return;
      setState(() {
        _nearbyPlaces  = places;
        _loadingNearby = false;
      });
      _calculateRoutes();
      await _buildForYou();
    } catch (e) {
      if (mounted) setState(() => _loadingNearby = false);
    }
  }



  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return BasePage(
      child: RefreshIndicator(
        onRefresh: _initAndLoad,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 50),

              // ── Achievement pill (lightweight, gamification cue) ──
              // Sits right under the search bar with extra horizontal
              // indent so it doesn't line up flush with the search bar's
              // own edges — reads as a secondary, tucked-in element.
              if (_latestBadge != null)
                _buildAchievementBanner(_latestBadge!),

              const SizedBox(height: 20),

              // ── 1. For You ──────────────────────
              _buildSectionHeader(
                "✨ For You",
                onSeeAll: _forYouPlaces.isNotEmpty ? _openAllForYou : null,
              ),
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
              _buildSectionHeader("Recommended Places"), 
              const SizedBox(height: 10),
              _buildCategorySection(),

              SizedBox(
                height: 320,
                child: _loadingNearby
                    ? const Center(child: TravelLoadingIndicator())
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
              _buildSectionHeader("Nearby Trending"),  
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 25),
                child: _loadingNearby
                    ? const Center(child: TravelLoadingIndicator())
                    : Column(
                        children: List.generate(_nearbyTrending.length, (i) =>
                            _buildSpecialAsymmetricCard(_nearbyTrending[i], i)),
                      ),
              ),

              SizedBox(height: 10 + MediaQuery.of(context).padding.bottom + kBottomNavigationBarHeight),
            ],
          ),
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
          child: Center(child: TravelLoadingIndicator()),
        );
      }

      if (_forYouPlaces.isEmpty) {
        final nextMode = _nextWiderTravelMode;   // 🔧 CHANGED — 计算下一级 tier 而不是写死 drive
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 25),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),   // 🔧 CHANGED — 固定 height 改成 padding，给按钮留空间
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,   // 🔧 CHANGED
                children: [
                  Icon(Icons.explore_outlined, size: 32, color: Colors.grey[400]),
                  const SizedBox(height: 8),
                  Text('No matching places $_distanceLimitLabel',
                      style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Try updating your preferences in Settings',
                      style: TextStyle(color: Colors.grey[400], fontSize: 11)),
                  if (nextMode != null) ...[   // 🔧 CHANGED
                    const SizedBox(height: 14),
                    ElevatedButton.icon(
                      onPressed: _loadingNearby
                          ? null
                          : () => _tryWiderTravelMode(nextMode),
                      icon: const Icon(Icons.directions_car_filled_rounded, size: 16),
                      label: Text('Try ${_labelForMode(nextMode)}'),   // 🔧 CHANGED
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7C4DFF),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }

      final preview = _forYouPlaces.take(7).toList();

      return SizedBox(
        height: 220,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 25),
          itemCount: preview.length,   // 🔧 CHANGED
          itemBuilder: (context, index) {
            return _buildForYouCard(preview[index]);   // 🔧 CHANGED
          },
        ),
      );
    }

  
  
  Widget _buildForYouCard(PlaceModel place) {
    final route = _routeResults[place.id];
    final dist  = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : "--";

    final reason = UserPreferenceService.instance.getRecommendReason(
      primaryType: place.primaryType,
      allTypes:    place.allTypes,
    );

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
                    ? CachedNetworkImage(
                        imageUrl: place.photoUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _buildPlaceholderBg(place),
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

              // Match badge — 能进 _forYouPlaces 就已经是 preference match 了，常显
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
    return Image.asset(
      CategoryImageHelper.getAssetPath(place.primaryType, place.allTypes),
      fit: BoxFit.cover,
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
    if (!mounted) return;
      AppDialogs.showLocationServiceDisabled(context);
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

  // ─────────────────────────────────────────────
  // Achievement pill — compact, gamification cue
  //
  // Kept lightweight on purpose: no full-width card, no multi-line text.
  // Just emoji + tier label + level chip + short desc, left-aligned so it
  // doesn't compete with For You / Recommended Places for attention.
  // Tapping still goes to the full Dashboard, where the real progress
  // (tiers, percentages, next-tier thresholds) lives.
  // ─────────────────────────────────────────────

  Widget _buildAchievementBanner(AchievementTier tier) {
    const tierColors = {
      'bronze': Color(0xFFCD7F32),
      'silver': Color(0xFFA8A9AD),
      'gold':   Color(0xFFFFD700),
    };
    final color = tierColors[tier.level] ?? const Color(0xFF6366F1);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => const DashboardPage(),
          )),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: color.withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withOpacity(0.35), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tier.emoji, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                Text(tier.label,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(tier.level.toUpperCase(),
                      style: TextStyle(
                          fontSize: 8, fontWeight: FontWeight.bold, color: color)),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text('• ${tier.desc}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 14, color: Colors.grey[500]),
              ],
            ),
          ),
        ),
      ),
    );
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
                    if (_currentWeather != null) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withOpacity(0.2)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_currentWeather!.emoji, style: const TextStyle(fontSize: 13)),
                              const SizedBox(width: 4),
                              Text(
                                WeatherService.instance.currentTemperature != null
                                    ? '${WeatherService.instance.currentTemperature!.round()}°C'
                                    : _currentWeather!.label,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      ],
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

  Widget _buildSectionHeader(String title, {VoidCallback? onSeeAll}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
          if (onSeeAll != null)
            GestureDetector(
              onTap: onSeeAll,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('See All',
                      style: TextStyle(fontSize: 13, color: Colors.grey[500],
                          fontWeight: FontWeight.w600)),
                  Icon(Icons.arrow_forward_ios_rounded,
                      size: 12, color: Colors.grey[500]),
                ]),
              ),
            ),
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
                child: (place.photoUrl != null && place.photoUrl!.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: place.photoUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _buildPlaceholderBg(place),
                      )
                    : _buildPlaceholderBg(place),
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
            if (isEven) _buildImage(place),
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
            if (!isEven) _buildImage(place),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(PlaceModel place) {
    return Hero(
      tag: 'place-img-${place.id}',
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
              child: (place.photoUrl != null && place.photoUrl!.isNotEmpty)
        ? CachedNetworkImage(
            imageUrl: place.photoUrl!,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => _buildPlaceholderBg(place),
          )
        : _buildPlaceholderBg(place),
        ),
      ),
    );
  }

}