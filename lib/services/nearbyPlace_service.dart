import 'package:flutter/material.dart';
import '../models/placeModal.dart';
import 'placesAPI_service.dart';
import 'location_service.dart';

class NearbyPlacesService {
  
  static final NearbyPlacesService instance = NearbyPlacesService._();
  NearbyPlacesService._();

  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};
  final Map<String, List<PlaceModel>> _searchCache = {};

  bool _isLoading = false;
  bool _hasLoadedOnce = false;

  List<PlaceModel> get cachedPlaces => _allPlacesCache;
  List<PlaceModel> get allPlaces => List.unmodifiable(_allPlacesCache);
  Map<String, List<PlaceModel>> get placesByType => Map.unmodifiable(_placesByTypeCache);
  bool get hasLoaded => _hasLoadedOnce;

 
  // 本地分类：把 Google types 映射到你的主分类
  static String _mapToPrimaryType(List<String> googleTypes) {
    if (googleTypes.any((t) => [
      'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
      'fast_food_restaurant', 'food_court', 'dessert_shop',
      'meal_takeaway', 'meal_delivery',
    ].contains(t))) return 'restaurant';

    if (googleTypes.any((t) => [
      'subway_station', 'bus_station', 'bus_stop', 'transit_station',
      'light_rail_station', 'taxi_stand', 'train_station',
    ].contains(t))) return 'transit';

    if (googleTypes.any((t) => [
      'hospital', 'doctor', 'medical_clinic', 'bank', 'atm', 'post_office',
    ].contains(t))) return 'service';

    if (googleTypes.any((t) => [
      'shopping_mall', 'supermarket', 'grocery_store', 'department_store',
      'clothing_store', 'electronics_store', 'pharmacy', 'book_store',
      'convenience_store', 'market',
    ].contains(t))) return 'shopping_mall';

    if (googleTypes.any((t) => [
      'movie_theater', 'amusement_park', 'bowling_alley', 'karaoke',
      'video_arcade', 'night_club', 'amusement_center', 'concert_hall',
      'gym', 'fitness_center', 'spa',
    ].contains(t))) return 'entertainment';

    if (googleTypes.any((t) => [
      'park', 'national_park', 'botanical_garden', 'garden', 'hiking_area',
      'beach', 'museum', 'art_gallery', 'tourist_attraction',
      'historical_landmark', 'monument',
    ].contains(t))) return 'park';

    return 'other';
  }

  // 核心 + 1st step：4 calls，then seperated the place based on category yourself
  Future<void> _fetchAndStore({
    required double lat,
    required double lng,
    required List<PlaceModel> targetList,
    required Map<String, List<PlaceModel>> targetByType,
  }) async {
    print('🌍 NearbyPlacesService: firing 4 API calls...');

    final results = await Future.wait([
      // Call 1: Food
      PlacesApiService.searchNearby(
        lat: lat, lng: lng,
        types: [
          'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
          'fast_food_restaurant', 'food_court', 'dessert_shop',
        ],
        maxResultCount: 20,
      ),
      // Call 2: Entertainment
      PlacesApiService.searchNearby(
        lat: lat, lng: lng,
        types: [
          'movie_theater', 'amusement_park', 'bowling_alley', 'karaoke',
          'video_arcade', 'night_club', 'amusement_center', 'concert_hall',
          'gym', 'fitness_center', 'spa',
        ],
        maxResultCount: 20,
      ),
      // Call 3: Transit + Service
      PlacesApiService.searchNearby(
        lat: lat, lng: lng,
        types: [
          'subway_station', 'bus_station', 'bus_stop', 'transit_station',
          'light_rail_station', 'taxi_stand', 'train_station',
          'hospital', 'doctor', 'medical_clinic', 'bank', 'atm', 'post_office',
        ],
        maxResultCount: 20,
      ),
      // Call 4: Nature + Shopping
      PlacesApiService.searchNearby(
        lat: lat, lng: lng,
        types: [
          'park', 'national_park', 'botanical_garden', 'hiking_area',
          'beach', 'museum', 'art_gallery', 'tourist_attraction',
          'historical_landmark', 'monument',
          'shopping_mall', 'supermarket', 'grocery_store', 'department_store',
          'clothing_store', 'electronics_store', 'pharmacy', 'book_store',
          'convenience_store', 'market',
        ],
        maxResultCount: 20,
      ),
    ]);

    final allRaw = [
      ...results[0],
      ...results[1],
      ...results[2],
      ...results[3],
    ];

    print('📦 Raw results: ${allRaw.length} (before dedup)');

    final seen = <String>{};

    for (final p in allRaw) {
      final id = p['id'] as String? ?? '';
      if (id.isEmpty || seen.contains(id)) continue;
      seen.add(id);

      final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
      final primaryType = _mapToPrimaryType(googleTypes);
      if (primaryType == 'other') continue;

      try {
        final place = PlaceModel.fromGoogle(p, primary: primaryType);
        if (place.lat == null || place.lng == null) continue;

        targetList.add(place);
        targetByType.putIfAbsent(primaryType, () => []);
        targetByType[primaryType]!.add(place);
      } catch (_) {}
    }

    print('✅ After dedup & classify: ${targetList.length} places');
    targetByType.forEach((type, places) => print('   $type: ${places.length}'));
  }
  

  Future<List<PlaceModel>> loadNearbyPlacesOnce(
    List<Map<String, dynamic>> categories,
    BuildContext context, {
    double? lat,
    double? lng,
  }) async {
    if (_hasLoadedOnce) {
      print('🧠 NearbyPlacesService: using cache');
      return _allPlacesCache;
    }
    if (_isLoading) {
      print('⏳ NearbyPlacesService: already loading');
      return _allPlacesCache;
    }

    final pos = LocationService.instance.currentPosition;
    if (pos == null && lat == null) throw Exception('No location');

    final searchLat = lat ?? pos!.latitude;
    final searchLng = lng ?? pos!.longitude;

    _isLoading = true;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();

    final stopwatch = Stopwatch()..start();

    await _fetchAndStore(
      lat: searchLat,
      lng: searchLng,
      targetList: _allPlacesCache,
      targetByType: _placesByTypeCache,
    );

    stopwatch.stop();
    _hasLoadedOnce = true;
    _isLoading = false;

    print('🏁 Total: ${_allPlacesCache.length} places in ${stopwatch.elapsedMilliseconds}ms');

    _precacheImages(context);
    return _allPlacesCache;
  }


  Future<List<PlaceModel>> loadNearbyPlacesAt({
    required double lat,
    required double lng,
    required List<Map<String, dynamic>> categories,
    required BuildContext context,
  }) async {
    final cacheKey = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    if (_searchCache.containsKey(cacheKey)) {
      print('🧠 loadNearbyPlacesAt: cache hit for $cacheKey');
      return _searchCache[cacheKey]!;
    }

    print('🔍 loadNearbyPlacesAt: ($lat, $lng)');

    final List<PlaceModel> results = [];
    final Map<String, List<PlaceModel>> byType = {};

    await _fetchAndStore(
      lat: lat,
      lng: lng,
      targetList: results,
      targetByType: byType,
    );

    print('✅ loadNearbyPlacesAt: ${results.length} places');
    _searchCache[cacheKey] = results;

    if (context.mounted) _precacheImages(context);
    return results;
  }


  // Getters
  List<PlaceModel> getByPrimary(String? primary) {
    if (primary == null || primary == 'all') {
      return List.unmodifiable(_allPlacesCache);
    }
    return List.unmodifiable(_placesByTypeCache[primary] ?? []);
  }

  List<PlaceModel> getBySecondary({
    required String primary,
    required String secondary, 
    required List<String> allowTypes,
    required List<String> nameKeywords,
  }) {
    if (secondary == 'all') return getByPrimary(primary);

    final base = getByPrimary(primary);
    final results = base.where((place) {
      final name      = place.name.toLowerCase();
      final typeMatch = allowTypes.isNotEmpty &&
          place.allTypes.any((t) => allowTypes.contains(t));
      final nameMatch = nameKeywords.isNotEmpty &&
          nameKeywords.any((k) => name.contains(k.toLowerCase()));
      return typeMatch || nameMatch;
    }).toList();

    print('🔍 getBySecondary[$secondary]: ${base.length} → ${results.length}');
    return results;
  }


  // Utils
  void _precacheImages(BuildContext context) {
    final withPhoto = _allPlacesCache.where((p) => p.photoUrl != null).toList();
    print('🖼️ Precaching ${withPhoto.length} images...');
    for (final place in withPhoto) {
      precacheImage(NetworkImage(place.photoUrl!), context);
    }
  }

  void clearCache() {
    print('♻️ NearbyPlacesService: cache cleared');
    _hasLoadedOnce = false;
    _isLoading = false;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();
  }

  void clearSearchCache() {
    print('♻️ NearbyPlacesService: search cache cleared');
    _searchCache.clear();
  }
}