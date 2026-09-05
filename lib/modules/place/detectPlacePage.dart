import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'placeDetailPage.dart';
import '../../services/route_service.dart';
import '../../services/location_service.dart';
import '../../models/placeModel.dart';
import '../../services/nearbyPlace_service.dart';
import 'routePreviewPage.dart';
import '../../services/placesAPI_service.dart';
import 'favouriteButton.dart';
import 'routeOptimizerPage.dart';
import '../../services/userPreference_service.dart';
import '../../services/categoryImage_Helper.dart';
import '../../services/weather_service.dart';
import '../../services/apps_Loading.dart';
import '../../models/itineraryModel.dart'; // ← 新加：ItineraryModel / ItineraryDay / ItineraryPlace
import 'package:intl/intl.dart'; // ← 新加：DateFormat
import '../../services/dialog_helper.dart'; // ← 新加：AppDialogs
import '../../services/category_mapper.dart';
import '../../services/for_you_recommendation_service.dart';

// ── Category-Aware Map Marker Presentation ──────────────────────────────────
class CategoryMarkerVisual {
  final Color color;
  final IconData icon;
  final double hue;

  const CategoryMarkerVisual({
    required this.color,
    required this.icon,
    required this.hue,
  });
}

CategoryMarkerVisual resolveCategoryMarkerVisual(String? category) {
  switch (category) {
    case 'restaurant':
      return const CategoryMarkerVisual(
        color: Colors.orange,
        icon: Icons.restaurant,
        hue: BitmapDescriptor.hueOrange,
      );
    case 'entertainment':
      return const CategoryMarkerVisual(
        color: Colors.deepPurple,
        icon: Icons.local_activity_rounded,
        hue: BitmapDescriptor.hueViolet,
      );
    case 'shopping_mall':
      return const CategoryMarkerVisual(
        color: Colors.teal,
        icon: Icons.shopping_bag,
        hue: BitmapDescriptor.hueCyan,
      );
    case 'park':
      return const CategoryMarkerVisual(
        color: Colors.green,
        icon: Icons.park,
        hue: BitmapDescriptor.hueGreen,
      );
    case 'tourist_attraction':
      return const CategoryMarkerVisual(
        color: Color(0xFF1976D2),
        icon: Icons.museum_rounded,
        hue: BitmapDescriptor.hueBlue,
      );
    case 'transit':
      return const CategoryMarkerVisual(
        color: Colors.indigo,
        icon: Icons.directions_transit,
        hue: BitmapDescriptor.hueMagenta,
      );
    case 'service':
      return const CategoryMarkerVisual(
        color: Color(0xFF0097A7),
        icon: Icons.miscellaneous_services,
        hue: BitmapDescriptor.hueRose,
      );
    default:
      return const CategoryMarkerVisual(
        color: Color(0xFF757575),
        icon: Icons.place,
        hue: 0.0,
      );
  }
}

// ── CHANGE 1: added 'recommended' sort mode ──────────────────────────────────
enum SortMode { distance, rating, recommended }

class RealTimeDetectPage extends StatefulWidget {
  static final Map<String, BitmapDescriptor> categoryMarkerCache = {};

  final double? landmarkLat;
  final double? landmarkLng;
  final VoidCallback onBack;
  final bool autoFocusSearch;
  final NearbyPlacesService? nearbyService;
  final SortMode? initialSortMode;
  final ForYouSnapshot? initialSnapshot;
  final TravelMode? initialTravelMode;

  const RealTimeDetectPage({
    super.key,
    this.landmarkLat,
    this.landmarkLng,
    required this.onBack,
    this.autoFocusSearch = false,
    this.nearbyService,
    this.initialSortMode,
    this.initialSnapshot,
    this.initialTravelMode,
  });

  NearbyPlacesService get effectiveNearbyService =>
      nearbyService ?? NearbyPlacesService.instance;

  /// Combines DISTANCE and POPULARITY candidate pools, deduplicating strictly by place ID.
  static List<PlaceModel> combineForYouPool({
    required List<PlaceModel> distancePlaces,
    required List<PlaceModel> popularityPlaces,
  }) {
    return ForYouRecommendationService.combinePools(
      distancePlaces: distancePlaces,
      popularityPlaces: popularityPlaces,
    );
  }

  /// Sorts candidates for the Nearest tab (DISTANCE only):
  /// - Distance ascending (smallest to largest)
  /// - Missing distance candidates last
  static List<PlaceModel> sortNearestPlaces({
    required List<PlaceModel> places,
    required Map<String, RouteResult> routeResults,
  }) {
    final sorted = List<PlaceModel>.from(places);
    sorted.sort((a, b) {
      final aD = routeResults[a.id]?.distanceMeters;
      final bD = routeResults[b.id]?.distanceMeters;
      if (aD == null && bD == null) return 0;
      if (aD == null) return 1;
      if (bD == null) return -1;
      return aD.compareTo(bD);
    });
    return sorted;
  }

  /// Sorts candidates for the Rank tab (POPULARITY only):
  /// 1. Rated places before unrated places (rating != null before rating == null)
  /// 2. Rating descending (highest to lowest)
  /// 3. Equal rating tie-break 1: Google POPULARITY response order
  /// 4. Equal rating tie-break 2: Distance ascending
  static List<PlaceModel> sortRankPlaces({
    required List<PlaceModel> places,
    required Map<String, int> popularityResponseOrder,
    required Map<String, RouteResult> routeResults,
  }) {
    final sorted = List<PlaceModel>.from(places);
    sorted.sort((a, b) {
      final aRating = a.rating;
      final bRating = b.rating;
      // 1. Rated places highest to lowest; missing rating appears last
      if (aRating == null && bRating == null) {
        // Both null: proceed to tie-break
      } else if (aRating == null) {
        return 1;
      } else if (bRating == null) {
        return -1;
      } else {
        final cmp = bRating.compareTo(aRating);
        if (cmp != 0) return cmp;
      }

      // 2. Tie-break 1: preserve Google POPULARITY response order
      final aOrder = popularityResponseOrder[a.id];
      final bOrder = popularityResponseOrder[b.id];
      if (aOrder != null && bOrder != null) {
        final orderCmp = aOrder.compareTo(bOrder);
        if (orderCmp != 0) return orderCmp;
      } else if (aOrder != null) {
        return -1;
      } else if (bOrder != null) {
        return 1;
      }

      // 3. Fallback tie-break 2: distance ascending
      final aD = routeResults[a.id]?.distanceMeters;
      final bD = routeResults[b.id]?.distanceMeters;
      if (aD == null && bD == null) return 0;
      if (aD == null) return 1;
      if (bD == null) return -1;
      return aD.compareTo(bD);
    });
    return sorted;
  }

  /// Returns active candidate pool for the given mode:
  /// - For You: deduplicated DISTANCE + POPULARITY pool
  /// - Nearest: DISTANCE pool only
  /// - Rank: POPULARITY pool only
  static List<PlaceModel> getCandidatesForTab({
    required SortMode mode,
    required List<PlaceModel> distancePlaces,
    required List<PlaceModel> popularityPlaces,
  }) {
    switch (mode) {
      case SortMode.distance:
        return List<PlaceModel>.from(distancePlaces);
      case SortMode.rating:
        return List<PlaceModel>.from(popularityPlaces);
      case SortMode.recommended:
        return combineForYouPool(
          distancePlaces: distancePlaces,
          popularityPlaces: popularityPlaces,
        );
    }
  }

  /// Calculates available subcategories using the active candidate pool across
  /// normal, search, and landmark modes.
  static List<Map<String, dynamic>> getAvailableSubCategories({
    required String? selectedPrimary,
    required List<PlaceModel> activeCandidatePool,
    required Map<String, List<Map<String, dynamic>>> subCategoriesConfig,
    Map<String, Set<String>>? specificTypesCache,
  }) {
    if (selectedPrimary == null) return [];
    final subs = subCategoriesConfig[selectedPrimary] ?? [];
    if (subs.isEmpty) return [];

    final sourcePlaces = activeCandidatePool
        .where((p) => p.primaryType == selectedPrimary)
        .toList();
    if (sourcePlaces.isEmpty) return [];

    final allSpecificTypes = specificTypesCache?[selectedPrimary] ??
        _extractSpecificTypes(selectedPrimary, subCategoriesConfig);

    return subs.where((sub) {
      if (sub['key'] == 'all') return true;
      final allowTypes = (sub['allowTypes'] as List?)?.cast<String>() ?? [];
      final nameKeywords = (sub['nameKeywords'] as List?)?.cast<String>() ?? [];

      return sourcePlaces.any((place) {
        final hasResolvedSpecificType =
            place.allTypes.any((t) => allSpecificTypes.contains(t));

        if (hasResolvedSpecificType) {
          return allowTypes.isNotEmpty &&
              place.allTypes.any((t) => allowTypes.contains(t));
        }

        final name = place.name.toLowerCase();
        return nameKeywords.isNotEmpty &&
            nameKeywords.any((k) => name.contains(k.toLowerCase()));
      });
    }).toList();
  }

  static Set<String> _extractSpecificTypes(
    String primary,
    Map<String, List<Map<String, dynamic>>> subCategoriesConfig,
  ) {
    final subs = subCategoriesConfig[primary] ?? [];
    final all = <String>{};
    for (final s in subs) {
      final types = (s['allowTypes'] as List?)?.cast<String>() ?? [];
      all.addAll(types);
    }
    return all;
  }

  /// Default sort mode across the application.
  static const SortMode defaultSortMode = SortMode.recommended;

  /// Production seam for validating whether an [initialSnapshot] matches the active
  /// normal user-GPS context (GPS coordinates, travel-mode radius, preference revision, and generation).
  /// Landmark mode and null coordinates always return false.
  @visibleForTesting
  static bool isValidInitialSnapshot({
    required ForYouSnapshot? snapshot,
    required Position? currentPosition,
    required int radiusMeters,
    required int preferenceRevision,
    required int generation,
    bool isLandmark = false,
  }) {
    if (snapshot == null || isLandmark || currentPosition == null) {
      return false;
    }
    return snapshot.matchesContext(
      originType: RecommendationOriginType.gps,
      lat: currentPosition.latitude,
      lng: currentPosition.longitude,
      radiusMeters: radiusMeters,
      preferenceRevision: preferenceRevision,
      generation: generation,
    );
  }

  /// Production seam for resolving the effective initial travel-mode radius.
  /// If [initialTravelMode] is provided, it takes precedence for that page session.
  /// Otherwise, uses the saved user preference.
  @visibleForTesting
  static int resolveInitialTravelModeRadius({
    TravelMode? initialTravelMode,
    UserPreferences? preference,
  }) {
    if (initialTravelMode != null) {
      return radiusForTravelMode(initialTravelMode);
    }
    final raw =
        (preference ?? UserPreferenceService.instance.current).travelMode;
    return radiusForTravelMode(travelModeFromString(raw));
  }

  /// Production seam for resolving the saved travel-mode radius from user preferences.
  @visibleForTesting
  static int resolveSavedTravelModeRadius([UserPreferences? pref]) {
    return resolveInitialTravelModeRadius(
      initialTravelMode: null,
      preference: pref,
    );
  }

  /// Production seam for validating whether an [initialSnapshot] matches the active
  /// normal user-GPS context under the effective travel mode (initial or saved).
  @visibleForTesting
  static bool isValidInitialSnapshotForEffectiveTravelMode({
    required ForYouSnapshot? snapshot,
    required Position? currentPosition,
    required int preferenceRevision,
    required int generation,
    TravelMode? initialTravelMode,
    UserPreferences? preference,
    bool isLandmark = false,
  }) {
    final expectedRadius = resolveInitialTravelModeRadius(
      initialTravelMode: initialTravelMode,
      preference: preference,
    );
    return isValidInitialSnapshot(
      snapshot: snapshot,
      currentPosition: currentPosition,
      radiusMeters: expectedRadius,
      preferenceRevision: preferenceRevision,
      generation: generation,
      isLandmark: isLandmark,
    );
  }

  /// Production seam for validating whether an [initialSnapshot] matches the saved user travel-mode
  /// radius and active context.
  @visibleForTesting
  static bool isValidInitialSnapshotForSavedPreference({
    required ForYouSnapshot? snapshot,
    required Position? currentPosition,
    required int preferenceRevision,
    required int generation,
    UserPreferences? preference,
    bool isLandmark = false,
  }) {
    return isValidInitialSnapshotForEffectiveTravelMode(
      snapshot: snapshot,
      currentPosition: currentPosition,
      preferenceRevision: preferenceRevision,
      generation: generation,
      initialTravelMode: null,
      preference: preference,
      isLandmark: isLandmark,
    );
  }

  /// Production seam for triggering background popularity prefetch at the end of bootstrap
  /// when popularity places are not yet loaded (restoring Landmark and Search popularity acquisition).
  @visibleForTesting
  static bool executeBootstrapEndPopularitySeam({
    required bool isPopularityEmpty,
    required void Function() onTriggerPrefetch,
  }) {
    if (isPopularityEmpty) {
      onTriggerPrefetch();
      return true;
    }
    return false;
  }

  /// Production seam for fetching the popularity round in background prefetch.
  @visibleForTesting
  static Future<List<PlaceModel>> executePrefetchPopularitySeam({
    required double lat,
    required double lng,
    required int radius,
    required NearbyPlacesService nearbyService,
  }) {
    return nearbyService.ensurePopularityRound(
      lat: lat,
      lng: lng,
      radius: radius,
    );
  }

  /// Production Rank-loading indicator component used by _buildPlaceListSheet.
  static Widget buildRankLoadingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TravelLoadingIndicator(size: 26),
            const SizedBox(height: 14),
            Text(
              'Loading ranked places...',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Calculates available subcategories for the active tab mode using its Google candidate pool.
  /// - For You: deduplicated DISTANCE + POPULARITY
  /// - Nearest: DISTANCE only
  /// - Rank: POPULARITY only
  static List<Map<String, dynamic>> getAvailableSubCategoriesForMode({
    required SortMode mode,
    required List<PlaceModel> distancePlaces,
    required List<PlaceModel> popularityPlaces,
    required String? selectedPrimary,
    required Map<String, List<Map<String, dynamic>>> subCategoriesConfig,
    Map<String, Set<String>>? specificTypesCache,
  }) {
    final pool = getCandidatesForTab(
      mode: mode,
      distancePlaces: distancePlaces,
      popularityPlaces: popularityPlaces,
    );
    return getAvailableSubCategories(
      selectedPrimary: selectedPrimary,
      activeCandidatePool: pool,
      subCategoriesConfig: subCategoriesConfig,
      specificTypesCache: specificTypesCache,
    );
  }

  /// Production seam for acknowledging a completed place load.
  /// Only normal user-GPS loads update LocationService's movement baseline.
  /// Landmark and search-mode coordinates are strictly excluded from updating
  /// the global user movement baseline.
  @visibleForTesting
  static void acknowledgeLoadedBaseline({
    required double lat,
    required double lng,
    required bool isLandmarkMode,
    required bool isSearchMode,
  }) {
    if (!isLandmarkMode && !isSearchMode) {
      LocationService.instance.updateMovementBaseline(lat, lng);
    }
  }

  /// Production seam for evaluating an incoming location stream movement event.
  /// Returns true if an automatic reload was started; false if the event was ignored.
  /// Search mode, Landmark mode, and sub-3000m movements simply ignore the event
  /// and NEVER release LocationService's shared movement pending state.
  @visibleForTesting
  static bool handleLocationChangedMovementEvent({
    required bool isSearchMode,
    required bool isLandmarkMode,
    required bool isBusy,
    required Position? currentPos,
    required double? lastLoadedLat,
    required double? lastLoadedLng,
    required Future<void> Function() onStartAutoReload,
  }) {
    if (isSearchMode || isLandmarkMode || isBusy) return false;
    if (currentPos == null || lastLoadedLat == null || lastLoadedLng == null) {
      return false;
    }
    final dist = Geolocator.distanceBetween(
      lastLoadedLat,
      lastLoadedLng,
      currentPos.latitude,
      currentPos.longitude,
    );
    if (dist < 3000) return false;
    unawaited(onStartAutoReload());
    return true;
  }

  /// Production seam for search-exit logic.
  /// Checks fresh GPS fix, releases movement pending and shows dialog on failure,
  /// and only clears search state and reloads places on success.
  @visibleForTesting
  static Future<bool> executeClearSearchSeam({
    required bool acquireFreshGps,
    required Future<LocationStatus> Function() refreshLocationFn,
    required Position? Function() getCurrentPositionFn,
    required void Function() onShowServiceDisabledDialog,
    required void Function() onShowUnavailableDialog,
    required void Function(Position? newPos) onClearSearchState,
    required Future<void> Function() onBootstrap,
  }) async {
    if (acquireFreshGps) {
      final status = await refreshLocationFn();
      if (status != LocationStatus.success) {
        if (status == LocationStatus.serviceDisabled) {
          onShowServiceDisabledDialog();
        } else {
          onShowUnavailableDialog();
        }
        return false;
      }
    }

    final realPos = getCurrentPositionFn();
    if (acquireFreshGps && realPos == null) {
      onShowUnavailableDialog();
      return false;
    }

    onClearSearchState(realPos);
    await onBootstrap();
    return true;
  }

  @override
  State<RealTimeDetectPage> createState() => _RealTimeDetectPageState();
}

class _RealTimeDetectPageState extends State<RealTimeDetectPage> {
  GoogleMapController? _mapController;
  bool _mapReady = false;
  Position? _currentPosition;

  NearbyPlacesService get _nearbyService => widget.effectiveNearbyService;

  final Set<Marker> _markers = {};
  Map<String, BitmapDescriptor> get categoryMarkerCache =>
      RealTimeDetectPage.categoryMarkerCache;
  // ── CHANGE 2: default sort = recommended ────────────────────────────────────
  SortMode _sortMode = RealTimeDetectPage.defaultSortMode;
  TravelMode _travelMode = TravelMode.walk; // will be overridden in initState
  bool _isTravelModeExpanded = false;
  bool _travelModeManuallySet = false;

  final List<PlaceModel> _displayedPlaces = [];
  List<PlaceModel> _landmarkPlaces = [];
  Map<String, RouteResult> _routeResults = {};

  // ── Three-Tab Place Retrieval Pools ─────────────────────────────────────────
  List<PlaceModel> _distancePlaces = [];
  List<PlaceModel> _popularityPlaces = [];
  final Map<String, int> _popularityResponseOrder = {};
  bool _isPopularityLoading = false;
  int _detectGeneration = 0;

  // 🆕 单一数据源 — build()/precache/卡片徽章 都读这里，不再各自重算
  List<PlaceModel> _rankedGooglePlaces = [];
  List<PlaceModel> _rankedGeoapifyPlaces = [];
  Map<String, double> _placeScores = {};

  bool _isLoading = false;

  String? _selectedPrimary;
  String _selectedSecondary = 'all';

  void _syncDistance(PlaceModel place, {bool forceRecalculate = false}) {
    if (_currentPosition == null || place.lat == null || place.lng == null)
      return;
    if (!forceRecalculate && _routeResults.containsKey(place.id)) {
      return;
    }
    final dist = Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      place.lat!,
      place.lng!,
    );
    _routeResults[place.id] = RouteResult(
      polylinePoints: const [],
      steps: const [],
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
      distanceMeters: dist,
      durationSeconds: (dist / _getSpeedMeterPerSecond()).round(),
    );
  }

  List<PlaceModel> _getCandidatesForTab(SortMode mode) {
    return RealTimeDetectPage.getCandidatesForTab(
      mode: mode,
      distancePlaces: _distancePlaces,
      popularityPlaces: _popularityPlaces,
    );
  }

  Future<void> _prefetchPopularityRound(
    double lat,
    double lng,
    int radius,
    int generation,
  ) async {
    _isPopularityLoading = true;
    try {
      final popPlaces = await RealTimeDetectPage.executePrefetchPopularitySeam(
        lat: lat,
        lng: lng,
        radius: radius,
        nearbyService: _nearbyService,
      );
      if (!mounted || generation != _detectGeneration) return;

      setState(() {
        _popularityPlaces = popPlaces;
        _popularityResponseOrder.clear();
        for (var i = 0; i < popPlaces.length; i++) {
          _popularityResponseOrder[popPlaces[i].id] = i;
        }
        _isPopularityLoading = false;
      });

      for (final place in popPlaces) {
        _syncDistance(place);
      }

      if (_sortMode == SortMode.recommended || _sortMode == SortMode.rating) {
        _applyFilter(preserveScroll: true);
      }
    } catch (e) {
      print('⚠️ _prefetchPopularityRound error: $e');
      if (mounted && generation == _detectGeneration) {
        setState(() => _isPopularityLoading = false);
      }
    }
  }

  // ── Movement reload tracking ──
  bool _isAutoReloading = false;
  bool _isRefreshingLocation = false;
  double? _lastLoadedLat;
  double? _lastLoadedLng;

  CameraPosition? _initialCameraPosition;

  // Search
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<Map<String, dynamic>> _autocompleteSuggestions = [];
  bool _isSearchMode = false;
  bool _isSearchLoading = false;
  String? _searchLocationName;
  Timer? _debounce;

  // Search history — stores last 5 searched locations
  final List<Map<String, dynamic>> _searchHistory = [];
  static const int _maxSearchHistory = 5;

  final Set<String> _selectedPlaceIds = {};
  final Map<String, PlaceModel> _selectedPlacesMap = {};
  List<PlaceModel> _searchPlaces = [];

  final List<Map<String, dynamic>> categories = [
    {
      'name': 'All',
      'icon': Icons.all_inclusive,
      'type': 'all',
      'color': Colors.black
    },
    {
      'name': 'Food',
      'icon': Icons.restaurant,
      'type': 'restaurant',
      'color': Colors.orange
    },
    {
      'name': 'Nature',
      'icon': Icons.park,
      'type': 'park',
      'color': Colors.green
    },
    {
      'name': 'Attraction',
      'icon': Icons.museum_rounded,
      'type': 'tourist_attraction',
      'color': Colors.brown
    },
    {
      'name': 'Entertain',
      'icon': Icons.local_activity_rounded,
      'type': 'entertainment',
      'color': Colors.deepPurple
    },
    {
      'name': 'Shopping',
      'icon': Icons.shopping_bag,
      'type': 'shopping_mall',
      'color': Colors.pink
    },
    {
      'name': 'Transport',
      'icon': Icons.directions_transit,
      'type': 'transit',
      'color': Colors.blue
    },
    {
      'name': 'Service',
      'icon': Icons.miscellaneous_services,
      'type': 'service',
      'color': Colors.teal
    },
  ];

  final Map<String, List<Map<String, dynamic>>> subCategories = {
    'restaurant': [
      {
        'key': 'all',
        'label': 'All',
        'allowTypes': <String>[],
        'nameKeywords': <String>[]
      },
      {
        'key': 'korean',
        'label': 'Korean',
        'allowTypes': <String>['korean_restaurant'],
        'nameKeywords': <String>[
          'korea',
          'korean',
          '한국',
          'kimchi',
          'bbq korean'
        ]
      },
      {
        'key': 'chinese',
        'label': 'Chinese',
        'allowTypes': <String>['chinese_restaurant'],
        'nameKeywords': <String>[
          'chinese',
          'canton',
          'dim sum',
          'claypot',
          'clay pot',
          '中',
          '华',
          '粤',
          '龙',
          '金',
          '福',
          '记',
          'seafood',
          'wonton',
          'bak kut'
        ]
      },
      {
        'key': 'japanese',
        'label': 'Japanese',
        'allowTypes': <String>['japanese_restaurant'],
        'nameKeywords': <String>[
          'japanese',
          'japan',
          'sushi',
          'ramen',
          'mentai',
          'yakitori',
          'tempura',
          'udon',
          'tonkatsu',
          'izakaya'
        ]
      },
      {
        'key': 'malay',
        'label': 'Malay',
        'allowTypes': <String>['malaysian_restaurant'],
        'nameKeywords': <String>[
          'nasi',
          'mee',
          'laksa',
          'satay',
          'rendang',
          'malay',
          'warung',
          'lemak',
          'kampung',
          'sup',
          'ayam',
          'ikan bakar'
        ]
      },
      {
        'key': 'indian',
        'label': 'Indian',
        'allowTypes': <String>['indian_restaurant'],
        'nameKeywords': <String>[
          'indian',
          'india',
          'naan',
          'curry',
          'briyani',
          'biryani',
          'tandoor',
          'mamak',
          'kandar',
          'roti canai',
          'banana leaf',
          'thali'
        ]
      },
      {
        'key': 'western',
        'label': 'Western',
        'allowTypes': <String>[
          'western_restaurant',
          'american_restaurant',
          'steak_house'
        ],
        'nameKeywords': <String>[
          'western',
          'steak',
          'burger',
          'pizza',
          'pasta',
          'grill',
          'bistro',
          'secret recipe',
          'mcdonalds',
          'kfc',
          'subway'
        ]
      },
      {
        'key': 'dessert',
        'label': 'Dessert',
        'allowTypes': <String>['dessert_shop', 'ice_cream_shop', 'bakery'],
        'nameKeywords': <String>[
          'dessert',
          'ice cream',
          'gelato',
          'cake',
          'bakery',
          'pastry',
          'sweet',
          'bubble tea',
          'boba',
          'cendol',
          'waffle',
          'crepe'
        ]
      },
      {
        'key': 'cafe',
        'label': 'Cafe',
        'allowTypes': <String>['cafe', 'coffee_shop'],
        'nameKeywords': <String>[
          'cafe',
          'coffee',
          'kopitiam',
          'kopi',
          'espresso',
          'latte',
          'brew',
          'roast'
        ]
      },
    ],
    'park': [
      {
        'key': 'all',
        'label': 'All',
        'allowTypes': <String>[],
        'nameKeywords': <String>[]
      },
      {
        'key': 'park',
        'label': 'Park',
        'allowTypes': <String>['park', 'national_park'],
        'nameKeywords': <String>['park', 'taman', 'recreational']
      },
      {
        'key': 'garden',
        'label': 'Garden',
        'allowTypes': <String>['botanical_garden'],
        'nameKeywords': <String>['garden', 'botanical', 'bunga']
      },
      {
        'key': 'beach',
        'label': 'Beach',
        'allowTypes': <String>['beach'],
        'nameKeywords': <String>['beach', 'pantai']
      },
      {
        'key': 'trail',
        'label': 'Hiking',
        'allowTypes': <String>['hiking_area'],
        'nameKeywords': <String>[
          'trail',
          'hiking',
          'bukit',
          'hill',
          'forest',
          'hutan'
        ]
      },
      {
        'key': 'landmark',
        'label': 'Landmark',
        'allowTypes': <String>[
          'tourist_attraction',
          'historical_landmark',
          'cultural_landmark',
          'monument'
        ],
        'nameKeywords': <String>[
          'heritage',
          'historic',
          'monument',
          'memorial',
          'fort',
          'landmark'
        ]
      },
      {
        'key': 'museum',
        'label': 'Museum',
        'allowTypes': <String>['museum', 'art_gallery'],
        'nameKeywords': <String>['museum', 'gallery', 'muzium']
      },
      {
        'key': 'temple',
        'label': 'Temple',
        'allowTypes': <String>['hindu_temple', 'buddhist_temple', 'shrine'],
        'nameKeywords': <String>['temple', 'tokong', 'kuil', 'shrine', '庙', '寺']
      },
      {
        'key': 'mosque',
        'label': 'Mosque',
        'allowTypes': <String>['mosque'],
        'nameKeywords': <String>['mosque', 'masjid', 'surau']
      },
      {
        'key': 'church',
        'label': 'Church',
        'allowTypes': <String>['church'],
        'nameKeywords': <String>['church', 'gereja', 'cathedral', 'chapel']
      },
    ],
    'tourist_attraction': [
      {
        'key': 'all',
        'label': 'All',
        'allowTypes': <String>[],
        'nameKeywords': <String>[]
      },
      {
        'key': 'landmark',
        'label': 'Landmark',
        'allowTypes': <String>[
          'tourist_attraction',
          'historical_landmark',
          'cultural_landmark',
          'monument'
        ],
        'nameKeywords': <String>[
          'heritage',
          'historic',
          'monument',
          'memorial',
          'fort',
          'landmark'
        ]
      },
      {
        'key': 'museum',
        'label': 'Museum',
        'allowTypes': <String>['museum', 'art_gallery'],
        'nameKeywords': <String>['museum', 'gallery', 'muzium']
      },
    ],
    'entertainment': [
      {
        'key': 'all',
        'label': 'All',
        'allowTypes': <String>[],
        'nameKeywords': <String>[]
      },
      {
        'key': 'cinema',
        'label': 'Cinema',
        'allowTypes': <String>['movie_theater'],
        'nameKeywords': <String>[
          'cinema',
          'gsc',
          'tgv',
          'mbo',
          'movie',
          'theatre'
        ]
      },
      {
        'key': 'karaoke',
        'label': 'Karaoke',
        'allowTypes': <String>['karaoke'],
        'nameKeywords': <String>['karaoke', 'neway', 'redsun', 'red box']
      },
      {
        'key': 'bowling',
        'label': 'Bowling',
        'allowTypes': <String>['bowling_alley'],
        'nameKeywords': <String>['bowling']
      },
      {
        'key': 'gaming',
        'label': 'Gaming',
        'allowTypes': <String>['amusement_center', 'video_arcade'],
        'nameKeywords': <String>[
          'arcade',
          'esport',
          'gaming',
          'lan',
          'timezone'
        ]
      },
      {
        'key': 'theme',
        'label': 'Theme Park',
        'allowTypes': <String>['amusement_park', 'theme_park'],
        'nameKeywords': <String>[
          'theme park',
          'sunway',
          'genting',
          'waterpark',
          'legoland'
        ]
      },
      {
        'key': 'sport',
        'label': 'Sports',
        'allowTypes': <String>[
          'sports_complex',
          'stadium',
          'gym',
          'fitness_center'
        ],
        'nameKeywords': <String>[
          'stadium',
          'sport',
          'badminton',
          'futsal',
          'swimming',
          'gym',
          'fitness'
        ]
      },
      {
        'key': 'spa',
        'label': 'Spa',
        'allowTypes': <String>['spa', 'beauty_salon'],
        'nameKeywords': <String>[
          'spa',
          'massage',
          'wellness',
          'relax',
          'beauty'
        ]
      },
    ],
    'shopping_mall': [
      {
        'key': 'all',
        'label': 'All',
        'allowTypes': <String>[],
        'nameKeywords': <String>[]
      },
      {
        'key': 'mall',
        'label': 'Mall',
        'allowTypes': <String>['shopping_mall'],
        'nameKeywords': <String>[
          'mall',
          'plaza',
          'square',
          'kompleks',
          'pavilion',
          'mid valley'
        ]
      },
      {
        'key': 'supermarket',
        'label': 'Supermarket',
        'allowTypes': <String>['supermarket', 'grocery_store'],
        'nameKeywords': <String>[
          'supermarket',
          'grocery',
          'mydin',
          'aeon',
          'tesco',
          'giant',
          'econsave',
          'jaya grocer'
        ]
      },
      {
        'key': 'fashion',
        'label': 'Fashion',
        'allowTypes': <String>['clothing_store', 'shoe_store'],
        'nameKeywords': <String>[
          'fashion',
          'clothing',
          'apparel',
          'boutique',
          'shoe',
          'zara',
          'h&m',
          'uniqlo'
        ]
      },
      {
        'key': 'electronics',
        'label': 'Electronics',
        'allowTypes': <String>['electronics_store', 'cell_phone_store'],
        'nameKeywords': <String>[
          'electronics',
          'phone',
          'computer',
          'digital',
          'harvey',
          'senheng',
          'courts'
        ]
      },
      {
        'key': 'pharmacy',
        'label': 'Pharmacy',
        'allowTypes': <String>['pharmacy', 'drugstore'],
        'nameKeywords': <String>[
          'pharmacy',
          'farmasi',
          'guardian',
          'watsons',
          'caring',
          'alpro'
        ]
      },
      {
        'key': 'market',
        'label': 'Market',
        'allowTypes': <String>['market', 'flea_market'],
        'nameKeywords': <String>[
          'market',
          'bazaar',
          'pasar',
          'night market',
          'ramadan',
          'flea'
        ]
      },
    ],
    'transit': [
      {
        'key': 'all',
        'label': 'All',
        'allowTypes': <String>[],
        'nameKeywords': <String>[]
      },
      {
        'key': 'lrt_mrt',
        'label': 'LRT / MRT',
        'allowTypes': <String>[
          'subway_station',
          'light_rail_station',
          'transit_station'
        ],
        'nameKeywords': <String>[
          'lrt',
          'mrt',
          'ktm',
          'monorail',
          'rapidkl',
          'station',
          'stesen'
        ]
      },
      {
        'key': 'bus',
        'label': 'Bus',
        'allowTypes': <String>['bus_station', 'bus_stop'],
        'nameKeywords': <String>[
          'bus',
          'rapid',
          'terminal',
          'hentian',
          'express'
        ]
      },
      {
        'key': 'taxi',
        'label': 'Taxi / Grab',
        'allowTypes': <String>['taxi_stand'],
        'nameKeywords': <String>['taxi', 'grab', 'cab', 'teksi']
      },
    ],
    'service': [
      {
        'key': 'all',
        'label': 'All',
        'allowTypes': <String>[],
        'nameKeywords': <String>[]
      },
      {
        'key': 'hospital',
        'label': 'Hospital',
        'allowTypes': <String>['hospital', 'medical_clinic', 'doctor'],
        'nameKeywords': <String>[
          'hospital',
          'clinic',
          'klinik',
          'medical',
          'health',
          'healthcare'
        ]
      },
      {
        'key': 'bank',
        'label': 'Bank / ATM',
        'allowTypes': <String>['bank', 'atm'],
        'nameKeywords': <String>[
          'bank',
          'maybank',
          'cimb',
          'public bank',
          'rhb',
          'hong leong',
          'ambank',
          'atm'
        ]
      },
      {
        'key': 'post',
        'label': 'Post Office',
        'allowTypes': <String>['post_office'],
        'nameKeywords': <String>[
          'post office',
          'pos malaysia',
          'poslaju',
          'pos laju'
        ]
      },
    ],
  };

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // 🆕 立刻给一个初始相机位置，不等 _bootstrap() —— 让 GoogleMap
    // 的原生初始化尽早开始，跟后面拿定位/landmark数据的时间重叠，
    // 而不是叠加在一起。
    final fallback = widget.landmarkLat != null && widget.landmarkLng != null
        ? LatLng(widget.landmarkLat!, widget.landmarkLng!)
        : (LocationService.instance.currentPosition != null
            ? LatLng(
                LocationService.instance.currentPosition!.latitude,
                LocationService.instance.currentPosition!.longitude,
              )
            : const LatLng(3.1390, 101.6869)); // 再兜底一个默认城市坐标

    _initialCameraPosition = CameraPosition(target: fallback, zoom: 14);

    // ... 原本其它 initState 逻辑不变
    if (widget.initialSortMode != null) {
      _sortMode = widget.initialSortMode!;
    }
    _initCategoryMarkers();
    _syncTravelModeFromPreference();

    final pos = LocationService.instance.currentPosition;
    final prefRev = UserPreferenceService.instance.preferenceRevision;
    final gen = ForYouRecommendationService.instance.currentGeneration;
    final hasValidSnapshot = _sortMode == SortMode.recommended &&
        RealTimeDetectPage.isValidInitialSnapshot(
          snapshot: widget.initialSnapshot,
          currentPosition: pos,
          radiusMeters: _radiusFromTravelMode,
          preferenceRevision: prefRev,
          generation: gen,
          isLandmark: widget.landmarkLat != null,
        );

    if (hasValidSnapshot) {
      _rankedGooglePlaces = List.from(widget.initialSnapshot!.places);
      _placeScores = Map.from(widget.initialSnapshot!.scores);
      _routeResults.addAll(widget.initialSnapshot!.routeResults);
      _displayedPlaces.clear();
      _displayedPlaces.addAll(widget.initialSnapshot!.places);
      for (final p in _displayedPlaces) {
        _addMarkerAndPlace(p);
      }
      _isLoading = false;
    }

    UserPreferenceService.instance.preferencesChanged
        .addListener(_onPreferencesChanged);
    WeatherService.instance.weatherChanged.addListener(_onWeatherChanged);
    _bootstrap();

    _searchFocus.addListener(() {
      setState(() {});
    });

    if (widget.autoFocusSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _searchFocus.requestFocus();
        });
      });
    }

    if (widget.landmarkLat == null) {
      LocationService.instance.startTracking();
    }
    LocationService.instance.addListener(_onLocationChanged);
  }

  void _onWeatherChanged() {
    if (mounted) _recomputeRanking();
  }

  void _syncTravelModeFromPreference() {
    if (widget.initialTravelMode != null) {
      _travelMode = widget.initialTravelMode!;
      print(
          '🔍 _syncTravelModeFromPreference: using initialTravelMode=$_travelMode');
      return;
    }
    final raw = UserPreferenceService.instance.current.travelMode;
    print(
        '🔍 _syncTravelModeFromPreference: raw="$raw" → ${travelModeFromString(raw)}');
    _travelMode = travelModeFromString(raw);
  }

  Future<void> _onPreferencesChanged() async {
    if (!mounted) return;

    ForYouRecommendationService.instance.invalidateUserGpsSnapshot();

    final savedMode = UserPreferenceService.instance.current.travelMode;
    final newMode = savedMode == 'drive'
        ? TravelMode.drive
        : savedMode == 'motor'
            ? TravelMode.motor
            : TravelMode.walk;

    if (!_travelModeManuallySet && newMode != _travelMode) {
      setState(() => _travelMode = newMode);
      _nearbyService.clearCache();
      _nearbyService.clearSearchCache();
      await _bootstrap();
      return;
    }

    // Category/cuisine/budget preferences might have changed even if travel mode didn't
    if (_sortMode == SortMode.recommended) {
      if (widget.landmarkLat == null &&
          _searchLocationName == null &&
          _currentPosition != null) {
        setState(() => _isLoading = true);
        try {
          final snapshot =
              await ForYouRecommendationService.instance.ensureForYouSnapshot(
            lat: _currentPosition!.latitude,
            lng: _currentPosition!.longitude,
            radiusMeters: _radiusFromTravelMode,
            weather: WeatherService.instance.current,
            nearbyService: _nearbyService,
          );
          if (mounted) {
            setState(() {
              _rankedGooglePlaces = List.from(snapshot.places);
              _placeScores = Map.from(snapshot.scores);
              _routeResults.addAll(snapshot.routeResults);
              _isLoading = false;
            });
          }
        } catch (e) {
          if (mounted) {
            _recomputeRanking();
            setState(() => _isLoading = false);
          }
        }
      } else {
        _recomputeRanking();
      }
    } else {
      _recomputeRanking();
    }
  }

  Future<void> _onLocationChanged() async {
    if (!mounted) return;
    RealTimeDetectPage.handleLocationChangedMovementEvent(
      isSearchMode: _searchLocationName != null,
      isLandmarkMode: widget.landmarkLat != null,
      isBusy: _isAutoReloading || _isLoading || _isRefreshingLocation,
      currentPos: LocationService.instance.currentPosition,
      lastLoadedLat: _lastLoadedLat,
      lastLoadedLng: _lastLoadedLng,
      onStartAutoReload: () async {
        _isAutoReloading = true;
        try {
          final pos = LocationService.instance.currentPosition;
          if (pos == null) return;
          _currentPosition = pos;
          _routeResults.clear();
          _markers.removeWhere((m) => m.markerId.value == 'me');
          _markers.add(Marker(
            markerId: const MarkerId('me'),
            position: LatLng(pos.latitude, pos.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure),
            infoWindow: const InfoWindow(title: 'My Location'),
          ));

          _nearbyService.clearCache();
          _nearbyService.clearSearchCache();
          _nearbyService.clearGoogleRawCache();

          await _bootstrap();

          if (_currentPosition != null) {
            _mapController?.animateCamera(CameraUpdate.newLatLngZoom(
              LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
              14,
            ));
          }
        } catch (e) {
          debugPrint('📍 Auto reload on location move failed: $e');
          LocationService.instance.releaseMovementPending();
        } finally {
          _isAutoReloading = false;
        }
      },
    );
  }

  @override
  void dispose() {
    LocationService.instance.removeListener(_onLocationChanged);
    if (widget.landmarkLat == null) {
      LocationService.instance.stopTracking();
    }
    UserPreferenceService.instance.preferencesChanged
        .removeListener(_onPreferencesChanged); // 🆕
    WeatherService.instance.weatherChanged.removeListener(_onWeatherChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Bootstrap
  // ─────────────────────────────────────────────

  Future<void> _bootstrap() async {
    final generation = ++_detectGeneration;
    final posForInit = LocationService.instance.currentPosition;
    final prefRevForInit = UserPreferenceService.instance.preferenceRevision;
    final genForInit = ForYouRecommendationService.instance.currentGeneration;
    final isInitialSnapshotValid = _sortMode == SortMode.recommended &&
        RealTimeDetectPage.isValidInitialSnapshot(
          snapshot: widget.initialSnapshot,
          currentPosition: posForInit,
          radiusMeters: _radiusFromTravelMode,
          preferenceRevision: prefRevForInit,
          generation: genForInit,
          isLandmark: widget.landmarkLat != null,
        );

    setState(() {
      _isLoading = !isInitialSnapshotValid;
      if (!isInitialSnapshotValid) {
        _distancePlaces.clear();
        _popularityPlaces.clear();
        _popularityResponseOrder.clear();
        _routeResults.clear();
      }
    });

    final double centerLat;
    final double centerLng;

    if (widget.landmarkLat != null && widget.landmarkLng != null) {
      centerLat = widget.landmarkLat!;
      centerLng = widget.landmarkLng!;
      _currentPosition = Position(
        latitude: centerLat,
        longitude: centerLng,
        timestamp: DateTime.now(),
        accuracy: 1,
        altitude: 0,
        heading: 0,
        speed: 0,
        speedAccuracy: 0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );

      _initialCameraPosition = CameraPosition(
        target: LatLng(centerLat, centerLng),
        zoom: 14,
      );

      _markers.removeWhere((m) => m.markerId.value == 'me');
      _markers.add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(centerLat, centerLng),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'Landmark Location'),
      ));

      setState(() {});

      try {
        final distPlaces = await _nearbyService.ensureDistanceRound(
          lat: centerLat,
          lng: centerLng,
          radius: _radiusFromTravelMode,
        );
        if (!mounted || generation != _detectGeneration) return;

        _landmarkPlaces = distPlaces;
        _distancePlaces = distPlaces;
        for (final p in distPlaces) {
          _syncDistance(p);
        }

        // Trigger Geoapify enrichment in background for landmark
        unawaited(_nearbyService.loadNearbyPlacesAt(
          lat: centerLat,
          lng: centerLng,
          categories: categories,
          context: context,
          radius: _radiusFromTravelMode,
          onGeoapifyBatchAdd: (batch) {
            if (mounted && generation == _detectGeneration) {
              for (final p in batch) {
                _syncDistance(p);
              }
              _landmarkPlaces.addAll(batch);
              _applyFilter(preserveScroll: true);
            }
          },
          onGeoapifyDone: () {
            if (mounted && generation == _detectGeneration) {
              _applyFilter(preserveScroll: true);
            }
          },
        ));
      } catch (e) {
        if (mounted && generation == _detectGeneration) {
          setState(() => _isLoading = false);
        }
        return;
      }
    } else {
      final pos = LocationService.instance.currentPosition;
      if (pos == null) {
        setState(() => _isLoading = false);
        if (_isAutoReloading) {
          LocationService.instance.releaseMovementPending();
        }
        AppDialogs.showLocationUnavailable(context);
        return;
      }
      _currentPosition = pos;
      centerLat = pos.latitude;
      centerLng = pos.longitude;

      _initialCameraPosition = CameraPosition(
        target: LatLng(pos.latitude, pos.longitude),
        zoom: 14,
      );

      _markers.removeWhere((m) => m.markerId.value == 'me');
      _markers.add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(pos.latitude, pos.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'My Location'),
      ));

      setState(() {});

      try {
        if (_sortMode == SortMode.recommended) {
          final prefRev =
              UserPreferenceService.instance.preferencesChanged.value;
          final gen = ForYouRecommendationService.instance.currentGeneration;
          final snapMatches = widget.initialSnapshot?.matchesContext(
                originType: RecommendationOriginType.gps,
                lat: centerLat,
                lng: centerLng,
                radiusMeters: _radiusFromTravelMode,
                preferenceRevision: prefRev,
                generation: gen,
              ) ==
              true;

          final ForYouSnapshot snapshot;
          if (snapMatches) {
            snapshot = widget.initialSnapshot!;
          } else {
            snapshot =
                await ForYouRecommendationService.instance.ensureForYouSnapshot(
              lat: centerLat,
              lng: centerLng,
              radiusMeters: _radiusFromTravelMode,
              weather: WeatherService.instance.current,
              nearbyService: _nearbyService,
            );
          }

          final distPlaces = await _nearbyService.ensureDistanceRound(
            lat: centerLat,
            lng: centerLng,
            radius: _radiusFromTravelMode,
          );
          final popPlaces = await _nearbyService.ensurePopularityRound(
            lat: centerLat,
            lng: centerLng,
            radius: _radiusFromTravelMode,
          );

          if (!mounted || generation != _detectGeneration) return;

          _distancePlaces = distPlaces;
          _popularityPlaces = popPlaces;
          _popularityResponseOrder.clear();
          for (var i = 0; i < popPlaces.length; i++) {
            _popularityResponseOrder[popPlaces[i].id] = i;
          }
          for (final p in distPlaces) {
            _syncDistance(p);
          }
          for (final p in popPlaces) {
            _syncDistance(p);
          }

          _rankedGooglePlaces = List.from(snapshot.places);
          _placeScores = Map.from(snapshot.scores);
          _routeResults.addAll(snapshot.routeResults);
          _isLoading = false;
        } else {
          final distPlaces = await _nearbyService.ensureDistanceRound(
            lat: centerLat,
            lng: centerLng,
            radius: _radiusFromTravelMode,
          );
          if (!mounted || generation != _detectGeneration) return;

          _distancePlaces = distPlaces;
          for (final p in distPlaces) {
            _syncDistance(p);
          }
        }

        // Trigger Geoapify enrichment in background
        unawaited(_nearbyService.loadNearbyPlacesOnce(
          categories,
          context,
          lat: centerLat,
          lng: centerLng,
          radius: _radiusFromTravelMode,
          onGeoapifyBatchAdd: (batch) {
            if (mounted && generation == _detectGeneration) {
              for (final p in batch) {
                _syncDistance(p);
              }
              _applyFilter(preserveScroll: true);
            }
          },
          onGeoapifyDone: () {
            if (mounted && generation == _detectGeneration) {
              _applyFilter(preserveScroll: true);
            }
          },
        ));
      } catch (e) {
        if (mounted && generation == _detectGeneration) {
          setState(() => _isLoading = false);
        }
        if (_isAutoReloading) {
          LocationService.instance.releaseMovementPending();
        }
        return;
      }
    }

    _applyFilter();
    if (_currentPosition != null) {
      WeatherService.instance.getCurrentCondition(
        lat: _currentPosition!.latitude,
        lng: _currentPosition!.longitude,
      );
    }

    // Record where we loaded from so _onLocationChanged can detect 3km+ moves
    _lastLoadedLat = _currentPosition?.latitude;
    _lastLoadedLng = _currentPosition?.longitude;
    RealTimeDetectPage.acknowledgeLoadedBaseline(
      lat: centerLat,
      lng: centerLng,
      isLandmarkMode: widget.landmarkLat != null,
      isSearchMode: _searchLocationName != null,
    );

    // Start POPULARITY retrieval automatically in the background if popularity places are not yet loaded
    // (Restores Landmark and Search candidate behaviour to obtain both DISTANCE and POPULARITY)
    RealTimeDetectPage.executeBootstrapEndPopularitySeam(
      isPopularityEmpty: _popularityPlaces.isEmpty,
      onTriggerPrefetch: () {
        unawaited(_prefetchPopularityRound(
          centerLat,
          centerLng,
          _radiusFromTravelMode,
          generation,
        ));
      },
    );
  }

  // ─────────────────────────────────────────────
  // Search
  // ─────────────────────────────────────────────

  int _autocompleteRequestId = 0;

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();

    if (query.isEmpty) {
      _autocompleteRequestId++;
      setState(() => _autocompleteSuggestions = []);
      return;
    }

    final reqId = ++_autocompleteRequestId;

    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final suggestions = await PlacesApiService.autocomplete(
        input: query,
        lat: _currentPosition?.latitude,
        lng: _currentPosition?.longitude,
      );

      if (mounted && reqId == _autocompleteRequestId) {
        setState(() => _autocompleteSuggestions = suggestions);
      }
    });
  }

  Future<void> _onSuggestionSelected(Map<String, dynamic> suggestion) async {
    final generation = ++_detectGeneration;
    _searchFocus.unfocus();
    setState(() {
      _isSearchMode = false;
      _isSearchLoading = true;
      _autocompleteSuggestions = [];
      _searchController.text = suggestion['mainText'] ?? '';
      _distancePlaces.clear();
      _popularityPlaces.clear();
      _popularityResponseOrder.clear();
    });

    final detail = await PlacesApiService.getPlaceLatLng(suggestion['placeId']);
    if (detail == null || detail['lat'] == null) {
      if (mounted && generation == _detectGeneration) {
        setState(() => _isSearchLoading = false);
      }
      return;
    }

    final lat = detail['lat'] as double;
    final lng = detail['lng'] as double;
    final name = detail['name'] as String;

    _currentPosition = Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 1,
      altitude: 0,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
      altitudeAccuracy: 0.0,
      headingAccuracy: 0.0,
    );

    try {
      final distPlaces = await _nearbyService.ensureDistanceRound(
        lat: lat,
        lng: lng,
        radius: _radiusFromTravelMode,
      );

      if (!mounted || generation != _detectGeneration) return;

      _searchPlaces = distPlaces;
      _distancePlaces = distPlaces;
      for (final p in distPlaces) {
        _syncDistance(p);
      }

      // Save to search history
      final historyEntry = {
        'placeId': suggestion['placeId'],
        'mainText': suggestion['mainText'] ?? name,
        'secondaryText': suggestion['secondaryText'] ?? '',
        'lat': lat,
        'lng': lng,
        'name': name,
      };
      setState(() {
        _searchHistory
            .removeWhere((h) => h['placeId'] == suggestion['placeId']);
        _searchHistory.insert(0, historyEntry);
        if (_searchHistory.length > _maxSearchHistory) {
          _searchHistory.removeLast();
        }
      });

      setState(() {
        _isSearchLoading = false;
        _searchLocationName = name;
        _selectedPlaceIds.clear();
        _markers.removeWhere((m) => m.markerId.value == 'search_location');
        _markers.add(Marker(
          markerId: const MarkerId('search_location'),
          position: LatLng(lat, lng),
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          infoWindow: InfoWindow(title: name),
        ));
      });

      _applyFilter();
      if (_currentPosition != null) {
        WeatherService.instance.getCurrentCondition(
          lat: _currentPosition!.latitude,
          lng: _currentPosition!.longitude,
        );
      }
      _animateToFitMarkers(keepZoom: false);

      // Trigger Geoapify enrichment in background for search location
      unawaited(_nearbyService.loadNearbyPlacesAt(
        lat: lat,
        lng: lng,
        categories: categories,
        context: context,
        radius: _radiusFromTravelMode,
        onGeoapifyBatchAdd: (batch) {
          if (mounted && generation == _detectGeneration) {
            for (final p in batch) {
              _syncDistance(p);
            }
            _searchPlaces.addAll(batch);
            _applyFilter(preserveScroll: true);
          }
        },
        onGeoapifyDone: () {
          if (mounted && generation == _detectGeneration) {
            _applyFilter(preserveScroll: true);
          }
        },
      ));

      // Trigger background POPULARITY retrieval for search location
      unawaited(_prefetchPopularityRound(
        lat,
        lng,
        _radiusFromTravelMode,
        generation,
      ));
    } catch (e) {
      if (mounted && generation == _detectGeneration) {
        setState(() => _isSearchLoading = false);
      }
    }
  }

  Future<void> _clearSearch({bool acquireFreshGps = true}) async {
    await RealTimeDetectPage.executeClearSearchSeam(
      acquireFreshGps: acquireFreshGps,
      refreshLocationFn: () =>
          LocationService.instance.refreshCurrentLocation(),
      getCurrentPositionFn: () => LocationService.instance.currentPosition,
      onShowServiceDisabledDialog: () {
        if (mounted) _showLocationDisabledDialog();
      },
      onShowUnavailableDialog: () {
        if (mounted) AppDialogs.showLocationUnavailable(context);
      },
      onClearSearchState: (realPos) {
        _searchController.clear();
        _selectedPlacesMap.clear();
        _searchFocus.unfocus();

        setState(() {
          if (realPos != null) _currentPosition = realPos;
          _isSearchMode = false;
          _isSearchLoading = false;
          _searchLocationName = null;
          _searchPlaces = [];
          _autocompleteSuggestions = [];
          _selectedPlaceIds.clear();
          _routeResults.clear();
          if (realPos != null) {
            _markers.removeWhere((m) => m.markerId.value == 'me');
            _markers.removeWhere((m) => m.markerId.value == 'search_location');
            _markers.add(Marker(
              markerId: const MarkerId('me'),
              position: LatLng(realPos.latitude, realPos.longitude),
              icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueAzure),
              infoWindow: const InfoWindow(title: 'My Location'),
            ));
          }
        });
      },
      onBootstrap: () async {
        await _bootstrap();
      },
    );

    if (_currentPosition != null) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        14,
      ));
    }
  }

  // 收集某个 primary 分类下,所有子分类"具体类型"的并集
  // 用来判断一个地点是否已经有明确的具体类型(不管来自 Google 原生 types
  // 还是 GeoapifyEnrichmentService 打的标签)
  final Map<String, Set<String>> _specificTypesCache = {};

  Set<String> _allSpecificTypesFor(String primary) {
    return _specificTypesCache.putIfAbsent(primary, () {
      final subs = subCategories[primary] ?? [];
      final all = <String>{};
      for (final s in subs) {
        final types = (s['allowTypes'] as List?)?.cast<String>() ?? [];
        all.addAll(types);
      }
      return all;
    });
  }

  // ─────────────────────────────────────────────
  // Filter
  // ─────────────────────────────────────────────

  void _applyFilter({bool preserveScroll = false}) {
    final tabCandidates = _getCandidatesForTab(_sortMode);
    final geoapifyCandidates = (_searchLocationName != null
            ? _searchPlaces
            : (widget.landmarkLat != null
                ? _landmarkPlaces
                : _nearbyService.getByPrimary(null)))
        .where((p) => p.isGeoapify)
        .toList();

    final List<PlaceModel> sourcePlaces = [
      ...tabCandidates,
      ...geoapifyCandidates
    ];

    List<PlaceModel> places;
    if (_selectedPrimary == null ||
        (_selectedSecondary == 'all' && _selectedPrimary == null)) {
      places = sourcePlaces;
    } else if (_selectedSecondary == 'all') {
      places =
          sourcePlaces.where((p) => p.primaryType == _selectedPrimary).toList();
    } else {
      final subs = subCategories[_selectedPrimary] ?? [];
      final cfg = subs.firstWhere(
        (e) => e['key'] == _selectedSecondary,
        orElse: () => {'allowTypes': <String>[], 'nameKeywords': <String>[]},
      );
      final allowTypes = (cfg['allowTypes'] as List?)?.cast<String>() ?? [];
      final nameKeywords = (cfg['nameKeywords'] as List?)?.cast<String>() ?? [];
      final allSpecificTypes = _allSpecificTypesFor(_selectedPrimary!);

      places = sourcePlaces.where((place) {
        if (_selectedPrimary != null && place.primaryType != _selectedPrimary)
          return false;
        if (allowTypes.isEmpty && nameKeywords.isEmpty) return true;

        // 该地点是否已经有明确的具体类型(来自 Google types 或 enrichment)？
        final hasResolvedSpecificType =
            place.allTypes.any((t) => allSpecificTypes.contains(t));

        if (hasResolvedSpecificType) {
          // 已经有权威类型 → 只信 typeMatch,不用名字关键词猜测
          return allowTypes.isNotEmpty &&
              place.allTypes.any((t) => allowTypes.contains(t));
        }

        // 还没有具体类型（未 enrich 的原始数据）→ 才 fallback 用名字关键词
        final name = place.name.toLowerCase();
        return nameKeywords.isNotEmpty &&
            nameKeywords.any((k) => name.contains(k.toLowerCase()));
      }).toList();
    }

    // 🆕 地图 marker 和列表用同一份 "开着的" 数据源
    places = places.where((p) => p.isOpenNow != false).toList();

    setState(() {
      _isLoading = false;
      _displayedPlaces.clear();
      _markers.removeWhere((m) =>
          m.markerId.value != 'me' && m.markerId.value != 'search_location');
      for (final place in places) {
        _addMarkerAndPlace(place);
      }
    });

    if (!preserveScroll) {
      _animateToFitMarkers(keepZoom: false);
    }
    _recomputeRanking();
  }

  void _onPrimaryTap(String type) {
    setState(() {
      _selectedPrimary = type == 'all' ? null : type;
      _selectedSecondary = 'all';
    });
    _applyFilter();
  }

  void _onSecondaryTap(String key) {
    setState(() => _selectedSecondary = key);
    _applyFilter();
  }

  Future<void> _onRefresh() async {
    if (_isRefreshingLocation || _isLoading) return;
    _isRefreshingLocation = true;

    try {
      if (_searchLocationName != null) {
        await _clearSearch(acquireFreshGps: true);
        return;
      }

      // Landmark mode: retain landmark center coordinates, do not fetch user GPS
      if (widget.landmarkLat != null && widget.landmarkLng != null) {
        setState(() {
          _selectedPrimary = null;
          _selectedSecondary = 'all';
          _isLoading = true;
          _distancePlaces.clear();
          _popularityPlaces.clear();
          _popularityResponseOrder.clear();
          _routeResults.clear();
        });

        _nearbyService.clearCache();
        _nearbyService.clearSearchCache();
        _nearbyService.clearGoogleRawCache();
        await _bootstrap();
        return;
      }

      // Normal GPS mode: acquire fresh GPS fix
      setState(() => _isLoading = true);
      final status = await LocationService.instance.refreshCurrentLocation();
      if (!mounted) return;

      if (status != LocationStatus.success) {
        setState(() => _isLoading = false);
        if (status == LocationStatus.serviceDisabled) {
          _showLocationDisabledDialog();
        } else {
          AppDialogs.showLocationUnavailable(context);
        }
        return;
      }

      final freshPos = LocationService.instance.currentPosition;
      if (freshPos == null) {
        setState(() => _isLoading = false);
        AppDialogs.showLocationUnavailable(context);
        return;
      }

      setState(() {
        _currentPosition = freshPos;
        _selectedPrimary = null;
        _selectedSecondary = 'all';
        _distancePlaces.clear();
        _popularityPlaces.clear();
        _popularityResponseOrder.clear();
        _routeResults.clear();
        _markers.removeWhere((m) => m.markerId.value == 'me');
        _markers.add(Marker(
          markerId: const MarkerId('me'),
          position: LatLng(freshPos.latitude, freshPos.longitude),
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'My Location'),
        ));
      });

      _nearbyService.clearCache();
      _nearbyService.clearSearchCache();
      _nearbyService.clearGoogleRawCache();
      ForYouRecommendationService.instance.invalidateUserGpsSnapshot();
      await _bootstrap();

      if (_currentPosition != null) {
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          14,
        ));
      }
    } finally {
      _isRefreshingLocation = false;
    }
  }

  // ─────────────────────────────────────────────
  // Selection
  // ─────────────────────────────────────────────

  void _togglePlaceSelection(PlaceModel place) {
    setState(() {
      final willBeSelected = !_selectedPlaceIds.contains(place.id);
      if (willBeSelected) {
        _selectedPlaceIds.add(place.id);
        _selectedPlacesMap[place.id] = place;
      } else {
        _selectedPlaceIds.remove(place.id);
        _selectedPlacesMap.remove(place.id);
      }
      _updateSinglePlaceMarker(place, isSelected: willBeSelected);
    });
  }

  void _viewSelectedItinerary() {
    if (_selectedPlaceIds.isEmpty || _currentPosition == null) return;

    final selectedPlaces = _selectedPlacesMap.values.toList();

    final now = DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd').format(now);

    var curHour = 9;
    var curMin = 0;
    final itineraryPlaces = <ItineraryPlace>[];
    for (final p in selectedPlaces) {
      final timeStr =
          '${curHour.toString().padLeft(2, '0')}:${curMin.toString().padLeft(2, '0')}';
      final duration = p.primaryType == 'restaurant' ? 60 : 90;
      itineraryPlaces.add(ItineraryPlace(
        placeId: p.id,
        name: p.name,
        address: p.address ?? '',
        photoUrl: p.photoUrl,
        lat: p.lat,
        lng: p.lng,
        primaryType: p.primaryType,
        suggestedTime: timeStr,
        durationMinutes: duration,
        notes: 'Added by you',
      ));
      curMin += duration;
      curHour += curMin ~/ 60;
      curMin = curMin % 60;
      if (curHour >= 21) {
        curHour = 21;
        curMin = 0;
      }
    }

    // 🆕 判断这次的 origin 到底来自哪里：
    // - landmark 模式（从别的页面带着固定坐标跳进来）→ 固定地点，不是实时定位
    // - 搜索模式（用户搜了别的地方）→ 固定地点，不是实时定位
    // - 都不是 → 用的就是设备的实时 GPS 定位
    final bool isLandmarkMode =
        widget.landmarkLat != null && widget.landmarkLng != null;
    final bool useCurrentLocation =
        !isLandmarkMode && _searchLocationName == null;
    final String? originName = useCurrentLocation
        ? null
        : (_searchLocationName ?? 'Landmark Location');

    final draftItinerary = ItineraryModel(
      id: '',
      title: 'My Custom Trip',
      startDate: dateStr,
      totalDays: 1,
      days: [
        ItineraryDay(dayNumber: 1, date: dateStr, places: itineraryPlaces)
      ],
      createdAt: now,
      isOriginCurrentLocation: useCurrentLocation, // 🆕
      originLat: _currentPosition!.latitude, // 🆕 _currentPosition 已经对应正确来源的坐标
      originLng: _currentPosition!.longitude, // 🆕
      originName: originName,
      travelMode: travelModeToString(_travelMode), // 🆕
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RouteOptimizerPage(
          itinerary: draftItinerary,
          startLat: _currentPosition!.latitude,
          startLng: _currentPosition!.longitude,
          startLocationName: _searchLocationName,
          travelMode: _travelMode,
        ),
      ),
    ).then((_) {
      if (mounted) {
        setState(() {
          _selectedPlaceIds.clear();
          _selectedPlacesMap.clear();
          _refreshAllPlaceMarkers();
        });
      }
    });
  }

  // ─────────────────────────────────────────────
  // Markers & Routes
  // ─────────────────────────────────────────────

  Future<void> _initCategoryMarkers() async {
    const categories = [
      'restaurant',
      'entertainment',
      'shopping_mall',
      'park',
      'tourist_attraction',
      'transit',
      'service',
      'other',
    ];
    for (final cat in categories) {
      for (final isSel in [false, true]) {
        final key = '${cat}_${isSel ? "1" : "0"}';
        if (!categoryMarkerCache.containsKey(key)) {
          try {
            final desc =
                await _createCategoryMarkerBitmap(cat, isSelected: isSel);
            categoryMarkerCache[key] = desc;
          } catch (_) {
            categoryMarkerCache[key] = BitmapDescriptor.defaultMarkerWithHue(
                resolveCategoryMarkerVisual(cat).hue);
          }
        }
      }
    }
    if (mounted) {
      _refreshAllPlaceMarkers();
    }
  }

  static Future<BitmapDescriptor> _createCategoryMarkerBitmap(
    String category, {
    required bool isSelected,
  }) async {
    final visual = resolveCategoryMarkerVisual(category);
    const dpr = 2.5;
    const baseW = 38.0;
    const baseH = 48.0;
    final scale = isSelected ? 1.15 : 1.0;

    final w = baseW * scale * dpr;
    final h = baseH * scale * dpr;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    final pinPath = Path();
    final center = Offset(w / 2, (w / 2) * 0.95);
    final radius = (w / 2) - (isSelected ? 5 * dpr : 4 * dpr);

    pinPath.addArc(
      Rect.fromCircle(center: center, radius: radius),
      pi * 0.75,
      pi * 1.5,
    );
    pinPath.lineTo(w / 2, h - (3 * dpr));
    pinPath.close();

    // Shadow
    canvas.drawPath(
      pinPath.shift(const Offset(0, 2 * dpr)),
      Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2 * dpr),
    );

    // Selected highlight ring
    if (isSelected) {
      canvas.drawPath(
        pinPath,
        Paint()
          ..color = const Color(0xFFFFD700)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5 * dpr,
      );
    }

    // Main fill
    canvas.drawPath(
      pinPath,
      Paint()
        ..color = visual.color
        ..style = PaintingStyle.fill,
    );

    // White inner border
    canvas.drawPath(
      pinPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = (isSelected ? 2.5 : 2.0) * dpr,
    );

    // Inner icon
    final iconPainter = TextPainter(
      textDirection: ui.TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(visual.icon.codePoint),
        style: TextStyle(
          fontSize: radius * 1.05,
          fontFamily: visual.icon.fontFamily,
          package: visual.icon.fontPackage,
          color: Colors.white,
        ),
      ),
    );
    iconPainter.layout();
    iconPainter.paint(
      canvas,
      Offset(
        center.dx - (iconPainter.width / 2),
        center.dy - (iconPainter.height / 2),
      ),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(w.toInt(), h.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData == null) {
      return BitmapDescriptor.defaultMarkerWithHue(visual.hue);
    }
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  BitmapDescriptor _getMarkerIcon(PlaceModel place,
      {required bool isSelected}) {
    final cat =
        CategoryMapper.resolvePrimaryType(place.primaryType, place.allTypes);
    final key = '${cat}_${isSelected ? "1" : "0"}';
    final cached = categoryMarkerCache[key];
    if (cached != null) return cached;
    return BitmapDescriptor.defaultMarkerWithHue(
        resolveCategoryMarkerVisual(cat).hue);
  }

  void _updateSinglePlaceMarker(PlaceModel place, {required bool isSelected}) {
    if (place.lat == null || place.lng == null) return;
    final markerId = MarkerId(place.id);
    _markers.removeWhere((m) => m.markerId == markerId);
    _markers.add(Marker(
      markerId: markerId,
      position: LatLng(place.lat!, place.lng!),
      icon: _getMarkerIcon(place, isSelected: isSelected),
      anchor: const Offset(0.5, 0.95),
      infoWindow: InfoWindow(
        title: place.name,
        snippet: place.address,
        onTap: () => _showPlaceDetails(place),
      ),
      onTap: () => _showPlaceDetails(place),
    ));
  }

  void _refreshAllPlaceMarkers() {
    if (!mounted || _displayedPlaces.isEmpty) return;
    setState(() {
      final existingPlaceMarkers = Map<String, PlaceModel>.fromEntries(
        _displayedPlaces
            .where((p) => p.lat != null && p.lng != null)
            .map((p) => MapEntry(p.id, p)),
      );
      _markers.removeWhere((m) =>
          m.markerId.value != 'me' && m.markerId.value != 'search_location');
      for (final place in existingPlaceMarkers.values) {
        final isSelected = _selectedPlaceIds.contains(place.id);
        _markers.add(Marker(
          markerId: MarkerId(place.id),
          position: LatLng(place.lat!, place.lng!),
          icon: _getMarkerIcon(place, isSelected: isSelected),
          anchor: const Offset(0.5, 0.95),
          infoWindow: InfoWindow(
            title: place.name,
            snippet: place.address,
            onTap: () => _showPlaceDetails(place),
          ),
          onTap: () => _showPlaceDetails(place),
        ));
      }
    });
  }

  void _addMarkerAndPlace(PlaceModel place) {
    if (place.lat == null || place.lng == null) return;

    final markerId = MarkerId(place.id);
    if (!_markers.any((m) => m.markerId == markerId)) {
      final isSelected = _selectedPlaceIds.contains(place.id);
      _markers.add(Marker(
        markerId: markerId,
        position: LatLng(place.lat!, place.lng!),
        icon: _getMarkerIcon(place, isSelected: isSelected),
        anchor: const Offset(0.5, 0.95),
        infoWindow: InfoWindow(
          title: place.name,
          snippet: place.address,
          onTap: () => _showPlaceDetails(place),
        ),
        onTap: () => _showPlaceDetails(place),
      ));
    }

    if (!_displayedPlaces.any((p) => p.id == place.id))
      _displayedPlaces.add(place);

    if (_currentPosition != null) {
      final dist = Geolocator.distanceBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        place.lat!,
        place.lng!,
      );
      _routeResults[place.id] = RouteResult(
        polylinePoints: [],
        steps: const [],
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
        distanceMeters: dist,
        durationSeconds: (dist / _getSpeedMeterPerSecond()).round(),
      );
    }
  }

  double _getSpeedMeterPerSecond() {
    switch (_travelMode) {
      case TravelMode.walk:
        return 1.4;
      case TravelMode.motor:
        return 6.0;
      case TravelMode.drive:
        return 12.0;
    }
  }

  // ── Radius is derived from travel mode — no separate picker needed ──────────
  int get _radiusFromTravelMode => radiusForTravelMode(_travelMode);

  void _updateRouteTimesForTravelMode() {
    if (_currentPosition == null) return;
    for (final place in _displayedPlaces) {
      final route = _routeResults[place.id];
      if (route == null) continue;
      _routeResults[place.id] = RouteResult(
        polylinePoints: route.polylinePoints,
        steps: route.steps,
        bounds: route.bounds,
        distanceMeters: route.distanceMeters,
        durationSeconds:
            (route.distanceMeters / _getSpeedMeterPerSecond()).round(),
      );
    }
  }

  void _animateToFitMarkers({bool keepZoom = false}) {
    if (_mapController == null || _markers.isEmpty) return;

    final relevantMarkers = _searchLocationName != null
        ? _markers.where((m) => m.markerId.value != 'me').toSet()
        : _markers;

    if (relevantMarkers.isEmpty) return;
    if (relevantMarkers.length == 1) {
      _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(relevantMarkers.first.position, 15));
      return;
    }

    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final m in relevantMarkers) {
      if (m.position.latitude < minLat) minLat = m.position.latitude;
      if (m.position.latitude > maxLat) maxLat = m.position.latitude;
      if (m.position.longitude < minLng) minLng = m.position.longitude;
      if (m.position.longitude > maxLng) maxLng = m.position.longitude;
    }
    final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    if (keepZoom) {
      _mapController!.animateCamera(CameraUpdate.newLatLng(center));
    } else {
      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        80,
      ));
    }
  }

  // ─────────────────────────────────────────────
  // Navigation
  // ─────────────────────────────────────────────

  Future<void> _navigateTo(PlaceModel place) async {
    if (place.lat == null || place.lng == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Destination location is unavailable'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // Navigation must always start from the user's REAL current GPS,
    // not from the landmark/search location used as the exploration centre.
    final realPosition = LocationService.instance.currentPosition;

    if (realPosition == null) {
      if (mounted) {
        AppDialogs.showLocationUnavailable(context);
      }
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePreviewPage(
          startLat: realPosition.latitude,
          startLng: realPosition.longitude,
          endLat: place.lat!,
          endLng: place.lng!,
          destinationName: place.name,
          startLocationName: 'My Location',
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // UI Helpers
  // ─────────────────────────────────────────────

  void _showErrorDialog(String title, String message) {
    showDialog(
        context: context,
        builder: (_) => AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                )
              ],
            ));
  }

  Future<void> _showLocationDisabledDialog() async {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.location_off_rounded,
                    color: Color(0xFF7C4DFF)),
              ),
              const SizedBox(height: 16),
              const Text('Location Disabled',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Please enable location services to see nearby places.',
                style: TextStyle(
                    fontSize: 14, color: Colors.grey[600], height: 1.4),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel',
                        style: TextStyle(color: Colors.grey[500])),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      // 系统定位服务关了 → 去系统定位设置
                      // 服务开着但 App 没权限 → 去 App 权限设置
                      final serviceEnabled =
                          await Geolocator.isLocationServiceEnabled();
                      if (!serviceEnabled) {
                        await Geolocator.openLocationSettings();
                      } else {
                        await Geolocator.openAppSettings();
                      }
                    },
                    child: const Text('Open Settings',
                        style: TextStyle(
                            color: Color(0xFF7C4DFF),
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── CHANGE 3: FavouriteButton shows immediately, resolves Google ID in background
  void _showPlaceDetails(PlaceModel place) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.42,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
          ),
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              // Show FavouriteButton immediately with geo_ id.
              // If it's a Geoapify place, resolve to Google ID in the background
              // and update silently — no loading spinner shown to the user.
              String resolvedFavId = place.id;

              if (place.isGeoapify) {
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  if (!context.mounted) return;
                  final googleId = await PlacesApiService.findGooglePlaceId(
                    geoInternalId: place.id,
                    placeName: place.name,
                    lat: place.lat!,
                    lng: place.lng!,
                  );
                  if (googleId != null && context.mounted) {
                    setModalState(() => resolvedFavId = googleId);
                  }
                });
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                      child: Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(10),
                    ),
                  )),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                          child: Text(
                        place.name,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      )),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        if (place.rating != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(children: [
                              const Icon(Icons.star_rounded,
                                  color: Colors.orange, size: 20),
                              const SizedBox(width: 2),
                              Text(place.rating.toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.orange)),
                            ]),
                          ),
                        const SizedBox(width: 4),
                        // Always show immediately — no spinner, no isResolvingId check
                        FavouriteButton(
                          placeId: resolvedFavId,
                          name: place.name,
                          address: place.address ?? '',
                          rating: place.rating?.toDouble(),
                          photoUrl: place.photoUrl,
                          lat: place.lat,
                          lng: place.lng,
                          types: place.allTypes,
                          showBackground: false,
                          iconSize: 24,
                          activeColor: Colors.red,
                          inactiveColor: Colors.grey,
                        ),
                      ]),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Icon(Icons.location_on_rounded,
                        size: 18, color: Theme.of(context).primaryColor),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(
                      place.address ?? 'Unknown address',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    )),
                  ]),
                  const SizedBox(height: 16),
                  if (_routeResults[place.id] != null)
                    Wrap(spacing: 12, children: [
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
                    ]),
                  const Spacer(),
                  Row(children: [
                    Expanded(
                        flex: 2,
                        child: OutlinedButton(
                          onPressed: () async {
                            Navigator.of(context).pop();
                            await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => PlaceDetailPage(
                                    placeId: place.id,
                                    placeName: place.name,
                                    source: place.source,
                                    lat: place.lat,
                                    lng: place.lng,
                                    userLat: _currentPosition?.latitude,
                                    userLng: _currentPosition?.longitude,
                                  ),
                                ));
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            side: BorderSide(color: Colors.grey[300]!),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                          child: const Text('Details',
                              style: TextStyle(
                                  color: Colors.black87,
                                  fontWeight: FontWeight.w600)),
                        )),
                    const SizedBox(width: 12),
                    Expanded(
                        flex: 3,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _navigateTo(place);
                          },
                          icon: const Icon(Icons.near_me_rounded,
                              color: Colors.white),
                          label: const Text('Navigate',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).primaryColor,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                        )),
                  ]),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildInfoChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  final ValueNotifier<double> _bottomPaddingNotifier = ValueNotifier(0.4);
  double _lastAppliedExtent = 0.4;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    final List<PlaceModel> sortedPlaces = _rankedGooglePlaces;
    final List<PlaceModel> sortedGeoapifyPlaces = _rankedGeoapifyPlaces;

    if (_initialCameraPosition == null) {
      return const Scaffold(
          body: Center(child: TravelLoadingIndicator(size: 22)));
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: true,
      body: GestureDetector(
        onTap: () {
          _searchFocus.unfocus();
          setState(() {
            _isSearchMode = false;
            _autocompleteSuggestions = [];
          });
        },
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            // ── Map ──
            ValueListenableBuilder<double>(
              valueListenable: _bottomPaddingNotifier,
              builder: (context, extent, _) {
                return GoogleMap(
                  initialCameraPosition: _initialCameraPosition!,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  markers: _markers,
                  onMapCreated: (c) {
                    _mapController = c;
                    if (mounted && !_mapReady) {
                      // 给第一帧瓦片一点时间绘制，避免遮罩一撤
                      // 就露出还没铺好的灰底图
                      Future.delayed(const Duration(milliseconds: 200), () {
                        if (mounted) setState(() => _mapReady = true);
                      });
                    }
                  },
                  padding:
                      EdgeInsets.only(bottom: screenHeight * extent, top: 60),
                );
              },
            ),

            // ── Map loading overlay: 半透明遮罩，地图初始化完成前显示 ──
            IgnorePointer(
              ignoring: _mapReady,
              child: AnimatedOpacity(
                opacity: _mapReady ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                child: Container(
                  color: Colors.white.withOpacity(0.6),
                  child: const Center(
                    child: TravelLoadingIndicator(size: 200),
                  ),
                ),
              ),
            ),

            // ── Search bar + Back button ──
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(
                    children: [
                      Row(children: [
                        Material(
                          elevation: 4,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          color: Colors.white,
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new,
                                size: 18, color: Colors.black87),
                            onPressed: _isSearchMode
                                ? () {
                                    setState(() {
                                      _isSearchMode = false;
                                      _autocompleteSuggestions = [];
                                    });
                                    _searchFocus.unfocus();
                                  }
                                : widget.onBack,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Material(
                            elevation: 4,
                            borderRadius: BorderRadius.circular(28),
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocus,
                              onChanged: _onSearchChanged,
                              onTap: () => setState(() => _isSearchMode = true),
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: _searchLocationName != null
                                    ? 'Near: $_searchLocationName'
                                    : 'Search a place...',
                                hintStyle: TextStyle(
                                  color: _searchLocationName != null
                                      ? const Color(0xFF1A73E8)
                                      : Colors.grey[400],
                                  fontSize: 14,
                                ),
                                prefixIcon: const Icon(Icons.search_rounded,
                                    color: Colors.grey, size: 20),
                                suffixIcon: _searchController.text.isNotEmpty ||
                                        _searchLocationName != null
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded,
                                            size: 18, color: Colors.grey),
                                        onPressed: _clearSearch,
                                      )
                                    : null,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(28),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Colors.white,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Material(
                          elevation: 4,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          color: Colors.white,
                          child: IconButton(
                            icon: const Icon(Icons.refresh_rounded,
                                size: 18, color: Colors.black87),
                            onPressed: _isLoading ? null : _onRefresh,
                          ),
                        ),
                      ]),

                      // Search history (shown when search bar focused + no query yet)
                      // OR autocomplete results (shown when user is typing)
                      if (_isSearchMode &&
                          (_autocompleteSuggestions.isNotEmpty ||
                              (_searchController.text.isEmpty &&
                                  _searchHistory.isNotEmpty)))
                        Container(
                          margin: const EdgeInsets.only(
                              top: 4, left: 44, right: 44),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              )
                            ],
                          ),
                          child: _autocompleteSuggestions.isNotEmpty
                              // ── Autocomplete results ──────────────────────
                              ? ListView.separated(
                                  shrinkWrap: true,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _autocompleteSuggestions.length
                                      .clamp(0, 5),
                                  separatorBuilder: (_, __) => const Divider(
                                      height: 1, indent: 16, endIndent: 16),
                                  itemBuilder: (context, index) {
                                    final s = _autocompleteSuggestions[index];
                                    return ListTile(
                                      dense: true,
                                      leading: const Icon(
                                          Icons.location_on_outlined,
                                          color: Color(0xFF1A73E8),
                                          size: 20),
                                      title: Text(s['mainText'] ?? '',
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500)),
                                      subtitle: Text(s['secondaryText'] ?? '',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[500]),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      onTap: () => _onSuggestionSelected(s),
                                    );
                                  },
                                )
                              // ── Search history ────────────────────────────
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 12, 16, 4),
                                      child: Row(children: [
                                        Icon(Icons.history_rounded,
                                            size: 14, color: Colors.grey[500]),
                                        const SizedBox(width: 6),
                                        Text('Recent searches',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey[500],
                                                fontWeight: FontWeight.w500)),
                                        const Spacer(),
                                        GestureDetector(
                                          onTap: () => setState(
                                              () => _searchHistory.clear()),
                                          child: Text('Clear',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey[400])),
                                        ),
                                      ]),
                                    ),
                                    ListView.separated(
                                      shrinkWrap: true,
                                      padding: const EdgeInsets.only(bottom: 8),
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      itemCount: _searchHistory.length,
                                      separatorBuilder: (_, __) =>
                                          const Divider(
                                              height: 1,
                                              indent: 16,
                                              endIndent: 16),
                                      itemBuilder: (context, index) {
                                        final h = _searchHistory[index];
                                        return ListTile(
                                          dense: true,
                                          leading: const Icon(
                                              Icons.history_rounded,
                                              color: Colors.grey,
                                              size: 20),
                                          title: Text(h['mainText'] ?? '',
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500)),
                                          subtitle: Text(
                                              h['secondaryText'] ?? '',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey[500]),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                          trailing: Icon(
                                              Icons.north_west_rounded,
                                              size: 14,
                                              color: Colors.grey[400]),
                                          onTap: () => _onSuggestionSelected(h),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                        ),

                      // Loading indicator
                      if (_isSearchLoading)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withOpacity(0.08),
                                  blurRadius: 8)
                            ],
                          ),
                          child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: TravelLoadingIndicator(size: 22),
                                ),
                                SizedBox(width: 10),
                                Text('Searching nearby...',
                                    style: TextStyle(
                                        fontSize: 13, color: Colors.black54)),
                              ]),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Bottom sheet ──
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                // 只有变化超过阈值才真正更新地图 padding，
                // 避免拖拽时每帧都触发 GoogleMap 的原生 method channel 调用
                if ((n.extent - _lastAppliedExtent).abs() > 0.02) {
                  _lastAppliedExtent = n.extent;
                  _bottomPaddingNotifier.value = n.extent;
                }
                return false;
              },
              child: DraggableScrollableSheet(
                key: ValueKey(_searchLocationName),
                initialChildSize: 0.4,
                minChildSize: 0.2,
                maxChildSize: 0.85,
                snap: false,
                builder: (context, scrollController) {
                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(28)),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 15)
                      ],
                    ),
                    child: _buildPlaceListSheet(
                        scrollController, sortedPlaces, sortedGeoapifyPlaces),
                  );
                },
              ),
            ),

            if (_isLoading) const Center(child: TravelLoadingIndicator()),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Place List Sheet
  // ─────────────────────────────────────────────
  //
  // Rebuilt on top of CustomScrollView + SliverList.builder so that place
  // cards are only built when they actually scroll into view. Everything
  // above the place list (drag handle, search-location banner, category
  // row, travel-mode picker, sort chips, secondary bar) is one static
  // header sliver — it's built once per rebuild of this method, same as
  // before, but the (potentially long) place list is no longer built
  // eagerly in one go.

  Widget _buildPlaceListSheet(ScrollController scrollController,
      List<PlaceModel> sortedPlaces, List<PlaceModel> sortedGeoapifyPlaces) {
    return Stack(
      children: [
        CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverToBoxAdapter(child: _buildSheetHeader()),

            // ── 主列表 + Other nearby places 区块 ──────────────────────────
            if (_sortMode == SortMode.rating && _isPopularityLoading) ...[
              SliverToBoxAdapter(
                child: RealTimeDetectPage.buildRankLoadingIndicator(),
              ),
            ] else if (sortedPlaces.isEmpty &&
                sortedGeoapifyPlaces.isEmpty &&
                !_isLoading)
              SliverToBoxAdapter(
                child: SizedBox(height: 300, child: _buildEmptyState()),
              )
            else ...[
              // ── Google 地点：主推荐列表（懒加载） ─────────────────────────
              if (sortedPlaces.isEmpty && !_isLoading)
                SliverToBoxAdapter(
                  child: _sortMode == SortMode.recommended
                      ? _buildForYouEmptyState()
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              'No main results — check "Other nearby places" below',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey[400]),
                            ),
                          ),
                        ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: _buildPlaceCard(sortedPlaces[index]),
                    ),
                    childCount: sortedPlaces.length,
                  ),
                ),

              // ── Geoapify 地点：单独区块，信息不全，仅作补充（懒加载） ────────
              if (!(_sortMode == SortMode.rating && _isPopularityLoading) &&
                  sortedGeoapifyPlaces.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      const Divider(height: 1, thickness: 0.5),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Row(children: [
                          Icon(Icons.info_outline_rounded,
                              size: 14, color: Colors.grey[500]),
                          const SizedBox(width: 6),
                          Text('Other nearby places',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[500],
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                          Text('(limited info)',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[400])),
                        ]),
                      ),
                    ],
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: _buildPlaceCard(
                        sortedGeoapifyPlaces[index],
                        allowForYouBadge: false,
                      ),
                    ),
                    childCount: sortedGeoapifyPlaces.length,
                  ),
                ),
              ],
            ],

            SliverToBoxAdapter(
              child: SizedBox(
                height: 24 +
                    MediaQuery.of(context).padding.bottom +
                    kBottomNavigationBarHeight,
              ),
            ),
          ],
        ),

        // ── 悬浮的 Plan Route 按钮 ──────────────────────────────
        if (_selectedPlaceIds.isNotEmpty && !_searchFocus.hasFocus)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            child: GestureDetector(
              onTap: _viewSelectedItinerary,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF7C4DFF).withOpacity(0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    )
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.map_rounded,
                        color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      'Plan Route (${_selectedPlaceIds.length})',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 10),
                    const Icon(Icons.arrow_forward_rounded,
                        color: Colors.white70, size: 18),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Everything above the place list: drag handle, search banner,
  //    category row, travel-mode picker, sort chips, secondary bar.
  //    Extracted so it can sit in a single SliverToBoxAdapter.
  Widget _buildSheetHeader() {
    return Column(
      children: [
        Center(
            child: Column(children: [
          const SizedBox(height: 8),
          Container(
            width: 45,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 4),
        ])),

        if (_searchLocationName != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              const Icon(Icons.location_on_rounded,
                  size: 14, color: Color(0xFF1A73E8)),
              const SizedBox(width: 4),
              Text(
                'Showing results near: $_searchLocationName',
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF1A73E8),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _clearSearch,
                child: const Icon(Icons.close_rounded,
                    size: 16, color: Color(0xFF1A73E8)),
              ),
            ]),
          ),

        // Primary categories
        SizedBox(
          height: 95,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final cat = categories[index];
              final isSelected = cat['type'] == 'all'
                  ? _selectedPrimary == null
                  : _selectedPrimary == cat['type'];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => _onPrimaryTap(cat['type']),
                  child: Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected ? cat['color'] : Colors.grey[100],
                        shape: BoxShape.circle,
                      ),
                      child: Icon(cat['icon'],
                          color: isSelected ? Colors.white : Colors.grey[600],
                          size: 26),
                    ),
                    const SizedBox(height: 6),
                    Text(cat['name'],
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? cat['color'] : Colors.grey[700],
                        )),
                  ]),
                ),
              );
            },
          ),
        ),

        const Divider(height: 1, thickness: 0.5),

        // Travel mode + radius picker on same row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Text('Travel By:',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
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
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                GestureDetector(
                  onTap: () => setState(
                      () => _isTravelModeExpanded = !_isTravelModeExpanded),
                  child: Row(children: [
                    Icon(_getTravelIcon(_travelMode),
                        color: Colors.blue[800], size: 20),
                    const SizedBox(width: 4),
                    Text(
                      _radiusFromTravelMode >= 1000
                          ? '${_radiusFromTravelMode ~/ 1000} km'
                          : '${_radiusFromTravelMode} m',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.blue[700],
                          fontWeight: FontWeight.w600),
                    ),
                    Icon(
                      _isTravelModeExpanded
                          ? Icons.arrow_left
                          : Icons.arrow_drop_down,
                      color: Colors.blue[800],
                    ),
                  ]),
                ),
                if (_isTravelModeExpanded)
                  Row(children: [
                    const VerticalDivider(width: 16),
                    _buildMiniIconWithReload(
                        TravelMode.walk, Icons.directions_walk),
                    _buildMiniIconWithReload(
                        TravelMode.motor, Icons.motorcycle),
                    _buildMiniIconWithReload(
                        TravelMode.drive, Icons.directions_car),
                  ]),
              ]),
            ),
          ]),
        ),

        // Sort + selected count
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              _buildStyledFilterChip(
                label: 'For You',
                isSelected: _sortMode == SortMode.recommended,
                onTap: () {
                  setState(() => _sortMode = SortMode.recommended);
                  _applyFilter(preserveScroll: true);
                },
                icon: Icons.auto_awesome_rounded,
              ),
              const SizedBox(width: 5),
              _buildStyledFilterChip(
                label: 'Nearest',
                isSelected: _sortMode == SortMode.distance,
                onTap: () {
                  setState(() => _sortMode = SortMode.distance);
                  _applyFilter(preserveScroll: true);
                },
                icon: Icons.near_me_outlined,
              ),
              const SizedBox(width: 5),
              _buildStyledFilterChip(
                label: 'Rank',
                isSelected: _sortMode == SortMode.rating,
                onTap: () {
                  setState(() => _sortMode = SortMode.rating);
                  _applyFilter(preserveScroll: true);
                },
                icon: Icons.star_outline_rounded,
              ),
              if (_selectedPlaceIds.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C4DFF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: const Color(0xFF7C4DFF).withOpacity(0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.check_circle_rounded,
                        size: 14, color: Color(0xFF7C4DFF)),
                    const SizedBox(width: 4),
                    Text('${_selectedPlaceIds.length}',
                        style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF7C4DFF),
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ],
            ]),
          ),
        ),

        if (_selectedPrimary != null &&
            subCategories.containsKey(_selectedPrimary))
          _buildSecondaryBar(),

        const Divider(height: 1, thickness: 0.5),
      ],
    );
  }

  void _recomputeRanking() {
    if (!mounted) return;

    final openPlaces =
        _displayedPlaces.where((p) => p.isOpenNow != false).toList();
    final googleAll = openPlaces.where((p) => !p.isGeoapify).toList();
    final geoapify = openPlaces.where((p) => p.isGeoapify).toList();

    List<PlaceModel> google;
    Map<String, double> scores = {};

    if (_sortMode == SortMode.recommended) {
      final isNormalGps =
          widget.landmarkLat == null && _searchLocationName == null;
      final cachedSnap = ForYouRecommendationService.instance.userGpsSnapshot;
      if (isNormalGps &&
          _selectedPrimary == null &&
          _currentPosition != null &&
          cachedSnap != null &&
          cachedSnap.matchesContext(
            originType: RecommendationOriginType.gps,
            lat: _currentPosition!.latitude,
            lng: _currentPosition!.longitude,
            radiusMeters: _radiusFromTravelMode,
            preferenceRevision:
                UserPreferenceService.instance.preferencesChanged.value,
            generation: ForYouRecommendationService.instance.currentGeneration,
          )) {
        google = cachedSnap.places;
        scores = cachedSnap.scores;
        _routeResults.addAll(cachedSnap.routeResults);
      } else {
        final result = UserPreferenceService.instance.buildForYouList(
          candidates: googleAll,
          routeResults: _routeResults,
          distanceLimitMeters: _radiusFromTravelMode.toDouble(),
          weather: WeatherService.instance.current,
          requirePhoto:
              true, // Authoritative photo requirement on both surfaces
          originType: widget.landmarkLat != null
              ? RecommendationOriginType.landmark
              : _searchLocationName != null
                  ? RecommendationOriginType.searched
                  : RecommendationOriginType.gps,
          originName:
              widget.landmarkLat != null ? 'Landmark' : _searchLocationName,
        );
        google = result.places;
        scores = result.scores;
      }
    } else if (_sortMode == SortMode.distance) {
      google = RealTimeDetectPage.sortNearestPlaces(
        places: googleAll,
        routeResults: _routeResults,
      );
    } else {
      google = RealTimeDetectPage.sortRankPlaces(
        places: googleAll,
        popularityResponseOrder: _popularityResponseOrder,
        routeResults: _routeResults,
      );
    }

    geoapify.sort((a, b) {
      final aD = _routeResults[a.id]?.distanceMeters ?? double.infinity;
      final bD = _routeResults[b.id]?.distanceMeters ?? double.infinity;
      return aD.compareTo(bD);
    });

    setState(() {
      _rankedGooglePlaces = google;
      _rankedGeoapifyPlaces = geoapify;
      _placeScores = scores;
    });

    _nearbyService.precacheOrderedImages(
      context,
      orderedPlaces: google,
    );
  }

  // ─────────────────────────────────────────────
  // Place Card
  // ─────────────────────────────────────────────

  Widget _buildPlaceCard(PlaceModel place, {bool allowForYouBadge = true}) {
    final routeInfo = _routeResults[place.id];
    final isSelected = _selectedPlaceIds.contains(place.id);

    // Compute score + reason for "For You" badge
    final isForYouMode = allowForYouBadge && _sortMode == SortMode.recommended;

    final reason = isForYouMode
        ? UserPreferenceService.instance.getRecommendReason(
            primaryType: place.primaryType,
            allTypes: place.allTypes,
            distanceMeters: routeInfo?.distanceMeters,
            rating: place.rating,
            priceLevel: place.priceLevel,
            originType: RecommendationOriginType.gps,
          )
        : null;
    final showForYouBadge = isForYouMode; // 能进列表就已经是 match 了

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          onTap: () => _showPlaceDetails(place),
          borderRadius: BorderRadius.circular(15),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF7C4DFF).withOpacity(0.05)
                  : Colors.white,
              borderRadius: BorderRadius.circular(15),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4))
              ],
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF7C4DFF).withOpacity(0.4)
                    : Colors.grey[100]!,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.blue[50],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: place.photoUrl != null
                        ? CachedNetworkImage(
                            imageUrl: place.photoUrl!,
                            fit: BoxFit.cover,
                            // 卡片头像只有 56x56 —— 限制解码尺寸，避免每张
                            // 滚入视口的卡片都去解码一张原始分辨率的网络图。
                            memCacheWidth: 112,
                            memCacheHeight: 112,
                            errorWidget: (c, e, s) => Image.asset(
                              CategoryImageHelper.getAssetPath(
                                place.primaryType,
                                place.allTypes,
                              ),
                              fit: BoxFit.cover,
                            ),
                          )
                        : Image.asset(
                            CategoryImageHelper.getAssetPath(
                              place.primaryType,
                              place.allTypes,
                            ),
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(place.name,
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Row(children: [
                        if (place.rating != null) ...[
                          const Icon(Icons.star_rounded,
                              color: Colors.orange, size: 16),
                          const SizedBox(width: 2),
                          Text(place.rating.toString(),
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange)),
                          _buildDotSeparator(),
                        ],
                        if (routeInfo != null) ...[
                          Icon(Icons.near_me_rounded,
                              size: 13, color: Colors.blue[400]),
                          const SizedBox(width: 3),
                          Text(
                            '${(routeInfo.distanceMeters / 1000).toStringAsFixed(1)} km',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[700]),
                          ),
                          _buildDotSeparator(),
                          Icon(Icons.access_time_filled_rounded,
                              size: 13, color: Colors.grey[400]),
                          const SizedBox(width: 3),
                          Text(
                            '${routeInfo.durationSeconds ~/ 60} min',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[700]),
                          ),
                        ],
                      ]),
                      // ── For You badge + reason ──────────────────────────
                      if (showForYouBadge) ...[
                        const SizedBox(height: 5),
                        Row(children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7C4DFF).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.auto_awesome_rounded,
                                      size: 10, color: Color(0xFF7C4DFF)),
                                  SizedBox(width: 3),
                                  Text('For You',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF7C4DFF),
                                          fontWeight: FontWeight.bold)),
                                ]),
                          ),
                          if (reason != null) ...[
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(reason,
                                  style: TextStyle(
                                      fontSize: 10, color: Colors.grey[500]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ]),
                      ],
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => _togglePlaceSelection(place),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF7C4DFF)
                          : Colors.grey[100],
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isSelected ? Icons.check_rounded : Icons.add_rounded,
                      color: isSelected ? Colors.white : Colors.grey[600],
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDotSeparator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text('•',
          style: TextStyle(
              color: Colors.grey[300],
              fontWeight: FontWeight.bold,
              fontSize: 14)),
    );
  }

  // ── Switching travel mode clears cache + reloads with new radius ────────────
  Widget _buildMiniIconWithReload(TravelMode mode, IconData icon) {
    final isSelected = _travelMode == mode;
    return GestureDetector(
      onTap: () async {
        if (_travelMode == mode) {
          setState(() => _isTravelModeExpanded = false);
          return;
        }
        setState(() {
          _travelMode = mode;
          _isTravelModeExpanded = false;
          _travelModeManuallySet = true;
        });
        // Radius changed with travel mode — clear cache and reload
        _nearbyService.clearCache();
        _nearbyService.clearSearchCache();
        await _bootstrap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        margin: const EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[200] : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon,
            size: 18, color: isSelected ? Colors.blue[900] : Colors.blue[400]),
      ),
    );
  }

  IconData _getTravelIcon(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk:
        return Icons.directions_walk;
      case TravelMode.motor:
        return Icons.motorcycle;
      case TravelMode.drive:
        return Icons.directions_car;
    }
  }

  List<Map<String, dynamic>> _getAvailableSubCategories() {
    return RealTimeDetectPage.getAvailableSubCategoriesForMode(
      mode: _sortMode,
      distancePlaces: _distancePlaces,
      popularityPlaces: _popularityPlaces,
      selectedPrimary: _selectedPrimary,
      subCategoriesConfig: subCategories,
      specificTypesCache: _specificTypesCache,
    );
  }

  Widget _buildSecondaryBar() {
    final subs = _getAvailableSubCategories();
    return Container(
      height: 40,
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: subs.length,
        itemBuilder: (context, index) {
          final item = subs[index];
          final key = item['key'] as String;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildStyledFilterChip(
              label: item['label'] as String,
              isSelected: _selectedSecondary == key,
              onTap: () => _onSecondaryTap(key),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[600] : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.blue[600]! : Colors.grey[200]!,
            width: 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon,
                size: 16, color: isSelected ? Colors.white : Colors.grey[600]),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? Colors.white : Colors.grey[700],
              )),
        ]),
      ),
    );
  }

  Widget _buildEmptyState() {
    // Suggest next travel mode with wider radius
    final nextMode = _travelMode == TravelMode.walk
        ? TravelMode.motor
        : _travelMode == TravelMode.motor
            ? TravelMode.drive
            : null;

    final nextRadius =
        nextMode != null ? (nextMode == TravelMode.motor ? 8000 : 12000) : null;

    final nextLabel = nextRadius != null ? '${nextRadius ~/ 1000} km' : null;

    final bool isForYouMode = _sortMode == SortMode.recommended; // 🆕

    return Center(
        child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.search_off, size: 48, color: Colors.grey),
        const SizedBox(height: 12),
        const Text('No places found nearby',
            style: TextStyle(fontSize: 16, color: Colors.grey)),
        const SizedBox(height: 6),
        Text(
          'Currently searching within ${_radiusFromTravelMode >= 1000 ? "${_radiusFromTravelMode ~/ 1000} km" : "${_radiusFromTravelMode} m"}',
          style: TextStyle(fontSize: 12, color: Colors.grey[400]),
        ),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          OutlinedButton(
            onPressed: () {
              if (isForYouMode) {
                // 🔧 CHANGED
                setState(() => _sortMode = SortMode.distance);
                _recomputeRanking();
              } else {
                setState(() {
                  _selectedPrimary = null;
                  _selectedSecondary = 'all';
                  _travelModeManuallySet = true;
                });
                _applyFilter();
              }
            },
            child: Text(isForYouMode
                ? 'Show Nearest instead'
                : 'Show All'), // 🔧 CHANGED
          ),
          if (nextMode != null) ...[
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () async {
                setState(() {
                  _travelMode = nextMode;
                  _isTravelModeExpanded = false;
                  _travelModeManuallySet = true;
                });
                _nearbyService.clearCache();
                _nearbyService.clearSearchCache();
                await _bootstrap();
              },
              icon: const Icon(Icons.radar_rounded, size: 16),
              label: Text('Try $nextLabel'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C4DFF),
                foregroundColor: Colors.white,
                elevation: 0,
              ),
            ),
          ],
        ]),
      ],
    ));
  }

  Widget _buildForYouEmptyState() {
    final nextMode = _travelMode == TravelMode.walk
        ? TravelMode.motor
        : _travelMode == TravelMode.motor
            ? TravelMode.drive
            : null;
    final nextRadius =
        nextMode != null ? (nextMode == TravelMode.motor ? 8000 : 12000) : null;
    final nextLabel = nextRadius != null ? '${nextRadius ~/ 1000} km' : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_rounded, size: 32, color: Colors.grey[400]),
            const SizedBox(height: 10),
            Text(
              'No places nearby match your preferences',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              'Try widening your search, or browse all nearby places instead',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                if (nextMode != null)
                  ElevatedButton.icon(
                    onPressed: () async {
                      setState(() {
                        _travelMode = nextMode;
                        _travelModeManuallySet = true;
                      });
                      _nearbyService.clearCache();
                      _nearbyService.clearSearchCache();
                      await _bootstrap();
                    },
                    icon: const Icon(Icons.radar_rounded, size: 16),
                    label: Text('Try $nextLabel'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C4DFF),
                      foregroundColor: Colors.white,
                      elevation: 0,
                    ),
                  ),
                OutlinedButton(
                  onPressed: () {
                    setState(() => _sortMode = SortMode.distance);
                    _recomputeRanking();
                  },
                  child: const Text('Show Nearest instead'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
