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
  Map<String, RecommendationExplanation> _forYouExplanations = {};
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

  bool _hasShownLocationRationale = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(viewportFraction: 0.8);
    _initAndLoad(isFirstOpen: true);
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
    
    // Tell the user nearby places are refreshing.
    // Use maybeOf() so this is safe even if the Scaffold is no longer present
    // (e.g. the user navigated away while the location event was in flight).
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
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

  Future<void> _initAndLoad({bool userTriggered = false, bool isFirstOpen = false}) async {
    _travelModeOverride = null;

    final permission = await Geolocator.checkPermission();
    final isGranted = permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;

    if (!isGranted) {
      if (isFirstOpen && !_hasShownLocationRationale) {
        _hasShownLocationRationale = true;
        setState(() {
          _loadingNearby = false;
          _currentLocationText = "Location disabled (tap to enable)";
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showLocationRationaleDialog();
        });
        return;
      } else if (!userTriggered) {
        setState(() {
          _loadingNearby = false;
          _currentLocationText = "Location disabled (tap to enable)";
        });
        return;
      }
    }

    final locationReady = await _initLocation(promptUser: userTriggered);

    if (!mounted) return;

    if (!locationReady) {
      setState(() => _loadingNearby = false);
      return;
    }

    setState(() => _loadingNearby = true);

    final pos = LocationService.instance.currentPosition;

    // Parallelize independent operations: preferences, nearby places, and weather.
    final futures = <Future<dynamic>>[
      UserPreferenceService.instance.load(),
      NearbyPlacesService.instance.loadNearbyPlacesOnce(
        _categories,
        context,
        radius: _distanceLimitMeters.toInt(),
      ),
      if (pos != null)
        WeatherService.instance.getCurrentCondition(
          lat: pos.latitude,
          lng: pos.longitude,
        ),
    ];

    try {
      final results = await Future.wait(futures);
      if (!mounted) return;

      final places = results[1] as List<PlaceModel>;
      WeatherCondition? weather;
      if (pos != null && results.length >= 3 && results[2] is WeatherCondition?) {
        weather = results[2] as WeatherCondition?;
      }

      // Compute routes locally in memory before committing state
      final calculatedRoutes = <String, RouteResult>{};
      if (pos != null) {
        for (final place in places) {
          if (place.lat != null && place.lng != null) {
            calculatedRoutes[place.id] = _calcRoute(pos.latitude, pos.longitude, place);
          }
        }
      }

      // Compute For You ranking locally in memory before committing state
      final openPlaces = places.where((p) => p.isOpenNow ?? true).toList();
      final forYouResult = UserPreferenceService.instance.buildForYouList(
        candidates:          openPlaces,
        routeResults:        calculatedRoutes,
        distanceLimitMeters: _distanceLimitMeters,
        weather:             weather ?? WeatherService.instance.current,
        requirePhoto:        true,
      );

      // Commit all critical and secondary data atomically in one single setState
      setState(() {
        _nearbyPlaces = places;
        _routeResults.clear();
        _routeResults.addAll(calculatedRoutes);
        _forYouPlaces = forYouResult.places;
        _forYouExplanations =
            Map<String, RecommendationExplanation>.from(forYouResult.explanations);
        if (weather != null) _currentWeather = weather;
        _loadingNearby = false;
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

  Future<bool> _initLocation({bool promptUser = false}) async {
    final status = await LocationService.instance.initLocation();

    switch (status) {
      case LocationStatus.serviceDisabled:
        if (promptUser) _showLocationServiceDialog();
        return false;

      case LocationStatus.permissionDenied:
        if (promptUser) _showPermissionDialog();
        return false;

      case LocationStatus.permissionDeniedForever:
        if (promptUser) _showPermissionForeverDialog();
        return false;

      case LocationStatus.success:
        break;
    }

    final pos = LocationService.instance.currentPosition;

    if (pos == null) {
      return false;
    }

    // Fire reverse geocoding in background without blocking places fetch
    _fetchCityNameAsync(pos);

    return true;
  }

  void _fetchCityNameAsync(Position pos) {
    placemarkFromCoordinates(pos.latitude, pos.longitude).then((placemarks) {
      if (placemarks.isNotEmpty && mounted) {
        final p = placemarks.first;
        final city = p.locality ??
            p.subAdministrativeArea ??
            p.administrativeArea ??
            'Unknown';
        final country = p.country ?? '';
        setState(() {
          _currentLocationText =
              country.isNotEmpty ? '$city, $country' : city;
        });
      }
    }).catchError((e) {
      debugPrint('Reverse geocoding failed: $e');
    });
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
      setState(() {
        _forYouPlaces = [];
        _forYouExplanations = {};
      });
      return;
    }

    final result = UserPreferenceService.instance.buildForYouList(
      candidates:           _openNearbyPlaces,
      routeResults:         _routeResults,
      distanceLimitMeters:  _distanceLimitMeters,
      weather:              WeatherService.instance.current, 
      requirePhoto:         true,   // MainPage 的卡片需要图
    );

    setState(() {
      _forYouPlaces = result.places;
      _forYouExplanations =
          Map<String, RecommendationExplanation>.from(result.explanations);
    });
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
        radius: _distanceLimitMeters.toInt(),
      );
      if (!mounted) return;

      final pos = LocationService.instance.currentPosition;
      final calculatedRoutes = <String, RouteResult>{};
      if (pos != null) {
        for (final place in places) {
          if (place.lat != null && place.lng != null) {
            calculatedRoutes[place.id] = _calcRoute(pos.latitude, pos.longitude, place);
          }
        }
      }

      final openPlaces = places.where((p) => p.isOpenNow ?? true).toList();
      final forYouResult = UserPreferenceService.instance.buildForYouList(
        candidates:          openPlaces,
        routeResults:        calculatedRoutes,
        distanceLimitMeters: _distanceLimitMeters,
        weather:             _currentWeather ?? WeatherService.instance.current,
        requirePhoto:        true,
      );

      setState(() {
        _nearbyPlaces = places;
        _routeResults.clear();
        _routeResults.addAll(calculatedRoutes);
        _forYouPlaces = forYouResult.places;
        _forYouExplanations =
            Map<String, RecommendationExplanation>.from(forYouResult.explanations);
        _loadingNearby = false;
      });
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
                child: (_loadingNearby && _nearbyPlaces.isEmpty)
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

              // ── 3. Nearby Trending / Nearby Places ───────────────
              _buildSectionHeader(
                "Nearby Places",
                onSeeAll: _nearbyPlaces.isNotEmpty ? _openNearbySeeAll : null,
              ),  
              const SizedBox(height: 12),
              _buildNearbySection(),

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
      if (_loadingNearby && _forYouPlaces.isEmpty) {
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

    final reason = _forYouExplanations[place.id]?.primaryReason;

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
                        memCacheWidth: 400,
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

  void _showLocationRationaleDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.location_on_rounded, color: Color(0xFF6366F1), size: 24),
                ),
                const SizedBox(width: 14),
                const Text(
                  'Enable Location',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'GoTrip uses your location to recommend nearby places, calculate travel distance and provide personalized routes. You can also search for another location manually.',
              style: TextStyle(fontSize: 14, color: Colors.grey[700], height: 1.45),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _initAndLoad(userTriggered: true);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Enable Location', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RealTimeDetectPage(
                            autoFocusSearch: true,
                            onBack: () => Navigator.pop(context),
                          ),
                        ),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      side: const BorderSide(color: Color(0xFF6366F1)),
                    ),
                    child: const Text('Search Manually', style: TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text('Not Now', style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showPermissionDialog() {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text("Permission Required"),
      content: const Text("Location permission is required to load nearby places. You can retry or search for places manually."),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RealTimeDetectPage(
                  autoFocusSearch: true,
                  onBack: () => Navigator.pop(context),
                ),
              ),
            );
          },
          child: const Text("Search Manually"),
        ),
        TextButton(
          onPressed: () { Navigator.pop(context); _initAndLoad(userTriggered: true); },
          child: const Text("Enable Location"),
        ),
      ],
    ));
  }

  void _showPermissionForeverDialog() {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text("Permission Permanently Denied"),
      content: const Text("Please enable location permission in app settings, or search for places manually."),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RealTimeDetectPage(
                  autoFocusSearch: true,
                  onBack: () => Navigator.pop(context),
                ),
              ),
            );
          },
          child: const Text("Search Manually"),
        ),
        ElevatedButton(
          onPressed: () { Navigator.pop(context); Geolocator.openAppSettings(); },
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
          child: const Text("Open App Settings", style: TextStyle(color: Colors.white)),
        ),
      ],
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
                        memCacheWidth: 500,
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

  void _openNearbySeeAll() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RealTimeDetectPage(
          onBack: () => Navigator.pop(context),
        ),
      ),
    );
  }

  List<PlaceModel> get _nearbyPreviewPlaces {
    if (_nearbyTrending.isNotEmpty) return _nearbyTrending;
    if (_openNearbyPlaces.isNotEmpty) return _openNearbyPlaces.take(6).toList();
    return _nearbyPlaces.take(6).toList();
  }

  Widget _buildNearbySection() {
    if (_loadingNearby && _nearbyPlaces.isEmpty) {
      return _buildNearbySkeleton();
    }

    final previewPlaces = _nearbyPreviewPlaces;
    if (previewPlaces.isEmpty) {
      return _buildNearbyEmptyState();
    }

    return SizedBox(
      height: 205,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 25),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: previewPlaces.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          return _buildCompactNearbyCard(previewPlaces[index]);
        },
      ),
    );
  }

  Widget _buildCompactNearbyCard(PlaceModel place) {
    final route = _routeResults[place.id];
    final distStr = route != null ? '${(route.distanceMeters / 1000).toStringAsFixed(1)} km' : null;
    final rating = place.rating;
    final isOpen = place.isOpenNow;
    final categoryInfo = _getCategoryInfo(place.primaryType);

    return GestureDetector(
      onTap: () => _openPlaceDetail(place),
      child: Container(
        width: 165,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Place Image ──
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: SizedBox(
                height: 105,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    (place.photoUrl != null && place.photoUrl!.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: place.photoUrl!,
                            fit: BoxFit.cover,
                            memCacheWidth: 350,
                            errorWidget: (_, __, ___) => _buildPlaceholderBg(place),
                          )
                        : _buildPlaceholderBg(place),
                    if (isOpen != null)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isOpen
                                ? const Color(0xFF10B981).withOpacity(0.9)
                                : Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isOpen ? 'Open' : 'Closed',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ── Place Details ──
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 34,
                    child: Text(
                      place.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(categoryInfo.icon, size: 12, color: categoryInfo.color),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          categoryInfo.label,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (distStr != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          distStr,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[500],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (rating != null && rating > 0)
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, size: 14, color: Colors.amber),
                        const SizedBox(width: 3),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    )
                  else
                    const SizedBox(height: 14),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNearbySkeleton() {
    return SizedBox(
      height: 205,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 25),
        scrollDirection: Axis.horizontal,
        itemCount: 4,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, __) => Container(
          width: 165,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade100),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 105,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(height: 12, width: 120, color: Colors.grey.shade200),
                    const SizedBox(height: 6),
                    Container(height: 10, width: 80, color: Colors.grey.shade100),
                    const SizedBox(height: 12),
                    Container(height: 10, width: 50, color: Colors.grey.shade100),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNearbyEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off_outlined, size: 28, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              'No nearby places found.',
              style: TextStyle(color: Colors.grey[600], fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              'Try exploring places on the map or refreshing.',
              style: TextStyle(color: Colors.grey[400], fontSize: 11),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openNearbySeeAll,
              icon: const Icon(Icons.map_outlined, size: 14),
              label: const Text('Explore Nearby on Map', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF7C4DFF),
                side: const BorderSide(color: Color(0xFF7C4DFF)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _CategoryBadgeInfo _getCategoryInfo(String? type) {
    switch (type) {
      case 'restaurant':
        return const _CategoryBadgeInfo(label: 'Food', icon: Icons.restaurant_rounded, color: Colors.orange);
      case 'park':
        return const _CategoryBadgeInfo(label: 'Nature', icon: Icons.park_rounded, color: Colors.green);
      case 'entertainment':
        return const _CategoryBadgeInfo(label: 'Entertainment', icon: Icons.local_activity_rounded, color: Colors.deepPurple);
      case 'shopping_mall':
        return const _CategoryBadgeInfo(label: 'Shopping', icon: Icons.shopping_bag_rounded, color: Colors.teal);
      case 'tourist_attraction':
        return const _CategoryBadgeInfo(label: 'Attraction', icon: Icons.museum_rounded, color: Color(0xFF1976D2));
      case 'transit':
        return const _CategoryBadgeInfo(label: 'Transport', icon: Icons.directions_transit, color: Colors.indigo);
      case 'service':
        return const _CategoryBadgeInfo(label: 'Service', icon: Icons.miscellaneous_services, color: Color(0xFF0097A7));
      default:
        return const _CategoryBadgeInfo(label: 'Place', icon: Icons.place_rounded, color: Colors.grey);
    }
  }

}

class _CategoryBadgeInfo {
  final String label;
  final IconData icon;
  final Color color;

  const _CategoryBadgeInfo({
    required this.label,
    required this.icon,
    required this.color,
  });
}