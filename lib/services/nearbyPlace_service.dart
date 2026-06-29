import 'dart:math';
import 'package:flutter/material.dart';
import '../models/placeModal.dart';
import 'placesAPI_service.dart';
import 'geoapify_service.dart';
import 'location_service.dart';
import 'overpass_service.dart';

class NearbyPlacesService {
  
  static final NearbyPlacesService instance = NearbyPlacesService._();
  NearbyPlacesService._();

  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};
  final Map<String, List<PlaceModel>> _searchCache = {};
  final Set<String> _loadingKeys = {};
  
  bool _isLoading = false;
  bool _hasLoadedOnce = false;

  List<PlaceModel> get cachedPlaces => _allPlacesCache;
  List<PlaceModel> get allPlaces => List.unmodifiable(_allPlacesCache);
  Map<String, List<PlaceModel>> get placesByType => Map.unmodifiable(_placesByTypeCache);
  bool get hasLoaded => _hasLoadedOnce;

  // ── Primary type mapping ────────────────────────────────────────────────────
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

  static const double _dedupDistanceMetres = 50.0;

  static double _haversineMetres(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
        sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  // ── Core fetch: Google + Geoapify, both using the same radius ──────────────
  Future<void> _fetchAndStore({
    required double lat,
    required double lng,
    required List<PlaceModel> targetList,
    required Map<String, List<PlaceModel>> targetByType,
    int radius = 5000, // ← NEW
  }) async {
    print('🌍 NearbyPlacesService: fetching with radius ${radius}m...');

    final futures = await Future.wait([
      // ── Google: 4 parallel calls, all using the same radius ──────────────
      Future.wait([
        PlacesApiService.searchNearby(
          lat: lat, lng: lng,
          types: [
            'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
            'fast_food_restaurant', 'food_court', 'dessert_shop',
          ],
          maxResultCount: 20,
          radius: radius, // ← pass through
        ),
        PlacesApiService.searchNearby(
          lat: lat, lng: lng,
          types: [
            'movie_theater', 'amusement_park', 'bowling_alley', 'karaoke',
            'video_arcade', 'night_club', 'amusement_center', 'concert_hall',
            'gym', 'fitness_center', 'spa',
          ],
          maxResultCount: 20,
          radius: radius,
        ),
        PlacesApiService.searchNearby(
          lat: lat, lng: lng,
          types: [
            'subway_station', 'bus_station', 'bus_stop', 'transit_station',
            'light_rail_station', 'taxi_stand', 'train_station',
            'hospital', 'doctor', 'medical_clinic', 'bank', 'atm', 'post_office',
          ],
          maxResultCount: 20,
          radius: radius,
        ),
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
          radius: radius,
        ),
      ]).then((r) => [...r[0], ...r[1], ...r[2], ...r[3]]),

      // ── Geoapify: all categories in parallel, same radius ─────────────────
      GeoapifyService.fetchNearby(
        lat: lat,
        lng: lng,
        radius: radius, // ← pass through
      ),
    ]);

    final googleRaw   = futures[0] as List<Map<String, dynamic>>;
    final geoapifyRaw = futures[1] as List<Map<String, dynamic>>;

    print('📦 Google raw: ${googleRaw.length} | Geoapify raw: ${geoapifyRaw.length} (before dedup)');

    // ── Step 1: Process Google results ────────────────────────────────────────
    final seenIds    = <String>{};
    final seenCoords = <({double lat, double lng})>[];

    for (final p in googleRaw) {
      final id = p['id'] as String? ?? '';
      if (id.isEmpty || seenIds.contains(id)) continue;
      seenIds.add(id);

      final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
      final primaryType = _mapToPrimaryType(googleTypes);
      if (primaryType == 'other') continue;

      try {
        final place = PlaceModel.fromGoogle(p, primary: primaryType);
        if (place.lat == null || place.lng == null) continue;

        targetList.add(place);
        targetByType.putIfAbsent(primaryType, () => []);
        targetByType[primaryType]!.add(place);
        seenCoords.add((lat: place.lat!, lng: place.lng!));
      } catch (_) {}
    }

    print('✅ After Google: ${targetList.length} places');

    // ── Step 2: Process Geoapify results (supplementary) ─────────────────────
    int geoAdded = 0;
    int geoDuped = 0;
    int geoTooFar = 0; // ← NEW

    for (final p in geoapifyRaw) {
      final id = p['id'] as String? ?? '';
      if (id.isEmpty || seenIds.contains(id)) continue;

      final locMap = p['location'] as Map<String, dynamic>?;
      final pLat   = (locMap?['latitude']  as num?)?.toDouble();
      final pLng   = (locMap?['longitude'] as num?)?.toDouble();
      if (pLat == null || pLng == null) continue;

      // ── Strict distance filter — reject anything outside the radius ────────
      final distToOrigin = _haversineMetres(lat, lng, pLat, pLng);
      if (distToOrigin > radius) {
        geoTooFar++;
        continue;
      }

      bool tooClose = false;
      for (final coord in seenCoords) {
        if (_haversineMetres(coord.lat, coord.lng, pLat, pLng) < _dedupDistanceMetres) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) { geoDuped++; continue; }

      final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
      final primaryType = _mapToPrimaryType(googleTypes);
      if (primaryType == 'other') continue;

      seenIds.add(id);
      seenCoords.add((lat: pLat, lng: pLng));

      try {
        final place = PlaceModel.fromGoogle(p, primary: primaryType);
        if (place.lat == null || place.lng == null) continue;

        targetList.add(place);
        targetByType.putIfAbsent(primaryType, () => []);
        targetByType[primaryType]!.add(place);
        geoAdded++;
      } catch (_) {}
    }

    print('🟣 Geoapify: +$geoAdded added, $geoDuped duplicates, $geoTooFar outside ${radius}m radius');
    print('✅ Final total: ${targetList.length} places');
    targetByType.forEach((type, places) => print('   $type: ${places.length}'));

    // ── Step 3: Enrich Geoapify restaurants with OSM cuisine tags ────────────
    final geoRestaurants = targetList
        .where((p) => p.isGeoapify && p.primaryType == 'restaurant')
        .toList();

    if (geoRestaurants.isNotEmpty) {
      print('🗺️ Enriching ${geoRestaurants.length} Geoapify restaurants with Overpass cuisine...');

      final osmEntries   = <Map<String, String>>[];
      final osmIdToIndex = <String, int>{};

      for (final place in geoRestaurants) {
        final osmId   = place.osmId   ?? '';
        final osmType = place.osmType ?? 'node';

        if (osmId.isNotEmpty) {
          osmEntries.add({'osmId': osmId, 'osmType': osmType});
          osmIdToIndex[osmId] = targetList.indexOf(place);
        }
      }

      if (osmEntries.isNotEmpty) {
        final cuisineMap = await OverpassService.fetchCuisineTags(osmEntries);

        for (final entry in cuisineMap.entries) {
          final osmId       = entry.key;
          final cuisineType = entry.value;
          final idx         = osmIdToIndex[osmId];

          if (idx != null && idx != -1) {
            final oldPlace     = targetList[idx];
            final updatedTypes = [...oldPlace.allTypes, cuisineType];

            targetList[idx] = oldPlace.copyWith(allTypes: updatedTypes);

            final primary  = oldPlace.primaryType ?? 'restaurant';
            final typeList = targetByType[primary];
            if (typeList != null) {
              final typeIdx = typeList.indexWhere((p) => p.id == oldPlace.id);
              if (typeIdx != -1) {
                typeList[typeIdx] = targetList[idx];
              }
            }

            print('✅ Enriched: ${oldPlace.name} → allTypes: $updatedTypes');
          }
        }
      }
    }
  }
  
  // ── Public: load once (real-time GPS mode) ─────────────────────────────────
  Future<List<PlaceModel>> loadNearbyPlacesOnce(
    List<Map<String, dynamic>> categories,
    BuildContext context, {
    double? lat,
    double? lng,
    int radius = 5000, // ← NEW
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
      lat:        searchLat,
      lng:        searchLng,
      targetList: _allPlacesCache,
      targetByType: _placesByTypeCache,
      radius:     radius, // ← pass through
    );

    stopwatch.stop();
    _hasLoadedOnce = true;
    _isLoading = false;

    print('🏁 Total: ${_allPlacesCache.length} places in ${stopwatch.elapsedMilliseconds}ms');

    _precacheImages(context);
    return _allPlacesCache;
  }

  // ── Public: load at specific location (landmark / search mode) ─────────────
  Future<List<PlaceModel>> loadNearbyPlacesAt({
    required double lat,
    required double lng,
    required List<Map<String, dynamic>> categories,
    required BuildContext context,
    int radius = 5000, // ← NEW
  }) async {
    // Include radius in cache key so different radii don't share cache
    final cacheKey = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)},r$radius';

    if (_searchCache.containsKey(cacheKey)) {
      print('🧠 loadNearbyPlacesAt: cache hit for $cacheKey');
      return _searchCache[cacheKey]!;
    }

    if (_loadingKeys.contains(cacheKey)) {
      print('⏳ loadNearbyPlacesAt: already loading $cacheKey, waiting...');
      while (_loadingKeys.contains(cacheKey)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _searchCache[cacheKey] ?? [];
    }

    _loadingKeys.add(cacheKey);
    print('🔍 loadNearbyPlacesAt: ($lat, $lng) radius=${radius}m');

    try {
      final List<PlaceModel> results = [];
      final Map<String, List<PlaceModel>> byType = {};

      await _fetchAndStore(
        lat:          lat,
        lng:          lng,
        targetList:   results,
        targetByType: byType,
        radius:       radius, // ← pass through
      );

      print('✅ loadNearbyPlacesAt: ${results.length} places');
      _searchCache[cacheKey] = results;

      if (context.mounted) _precacheImages(context);
      return results;

    } finally {
      _loadingKeys.remove(cacheKey);
    }
  }

  // ── Getters ─────────────────────────────────────────────────────────────────
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

  // ── Utils ───────────────────────────────────────────────────────────────────
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