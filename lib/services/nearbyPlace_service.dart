import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../models/placeModel.dart';
import 'placesAPI_service.dart';
import 'geoapify_service.dart';
import 'location_service.dart';
import 'geoapifyEnrichment_service.dart';
import 'route_service.dart';
import 'category_mapper.dart';

class _LruTracker {
  final int capacity;
  final void Function(String key) onEvict;
  final List<String> _order = []; // 最近使用的在末尾

  _LruTracker({required this.capacity, required this.onEvict});

  /// 每次读/写某个 key 时调用，标记为"最近使用"
  void touch(String key) {
    _order.remove(key);
    _order.add(key);
    while (_order.length > capacity) {
      final oldest = _order.removeAt(0);
      onEvict(oldest);
    }
  }

  void remove(String key) => _order.remove(key);
  void clear() => _order.clear();
}


class NearbyPlacesService {

  static final NearbyPlacesService instance = NearbyPlacesService._();
  NearbyPlacesService._();

  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};
  final Map<String, List<PlaceModel>> _searchCache = {};
  final Set<String> _loadingKeys = {};
  final Map<String, List<PlaceModel>> _itineraryRawCache = {};
  final Map<String, int> _itineraryRawCacheRadius = {};

  bool _isLoading = false;
  bool _hasLoadedOnce = false;

  static const int _googleMaxRadius = 15000;

  static const int _maxPrecacheImages = 24;
  static const int _precacheBatchSize = 6;

  final Map<String, List<PlaceModel>> _googleRawCache = {};
  final Map<String, int> _googleRawCacheRadius = {};

  static const int _geoapifyMaxRadius = 15000;
  final Map<String, List<Map<String, dynamic>>> _geoapifyRawCache = {};
  final Map<String, int> _geoapifyRawCacheRadius = {};

  String _locKey(double lat, double lng) =>
      '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';

  int _currentGeneration = 0;

  bool _isBackgroundLoading = false;
  bool get isBackgroundLoading => _isBackgroundLoading;

  List<PlaceModel> get cachedPlaces => _allPlacesCache;
  List<PlaceModel> get allPlaces => List.unmodifiable(_allPlacesCache);
  Map<String, List<PlaceModel>> get placesByType => Map.unmodifiable(_placesByTypeCache);
  bool get hasLoaded => _hasLoadedOnce;

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

  static const int _maxCachedLocations = 20; // 超过 20 个坐标就淘汰最久未用的

  late final _LruTracker _googleLru = _LruTracker(
    capacity: _maxCachedLocations,
    onEvict: (key) {
      _googleRawCache.remove(key);
      _googleRawCacheRadius.remove(key);
      print('♻️ Google raw cache LRU evicted: $key');
    },
  );

  late final _LruTracker _geoapifyLru = _LruTracker(
    capacity: _maxCachedLocations,
    onEvict: (key) {
      _geoapifyRawCache.remove(key);
      _geoapifyRawCacheRadius.remove(key);
      print('♻️ Geoapify raw cache LRU evicted: $key');
    },
  );

  late final _LruTracker _itineraryLru = _LruTracker(
    capacity: _maxCachedLocations,
    onEvict: (key) {
      _itineraryRawCache.remove(key);
      _itineraryRawCacheRadius.remove(key);
      print('♻️ Itinerary raw cache LRU evicted: $key');
    },
  );


  Future<List<PlaceModel>> _fetchGoogleOnce(
    double lat,
    double lng,
    int requestedRadius,
  ) async {
    final key = _locKey(lat, lng);
    final cachedRadius = _googleRawCacheRadius[key];

    if (_googleRawCache.containsKey(key) &&
        cachedRadius != null &&
        cachedRadius >= requestedRadius) {
      _googleLru.touch(key); // 👈 命中也要 touch
      print('🆓 Google raw cache HIT for $key ...');
      return _googleRawCache[key]!;
    }

    if (_googleRawCache.containsKey(key) &&
        cachedRadius != null &&
        cachedRadius >= requestedRadius) {
      print('🆓 Google raw cache HIT for $key '
          '(cached at ${cachedRadius}m, need ${requestedRadius}m) — no API call');
      return _googleRawCache[key]!;
    }

    final fetchRadius = max(_googleMaxRadius, requestedRadius);

    print('💰 Google raw cache MISS for $key — calling Google Places API '
        'ONCE at radius ${fetchRadius}m (requested: ${requestedRadius}m)');

    final googleRaw = await Future.wait([
      PlacesApiService.searchNearby(
        lat: lat,
        lng: lng,
        types: [
          'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
          'fast_food_restaurant', 'food_court', 'dessert_shop',
        ],
        maxResultCount: 20,
        radius: fetchRadius,
      ),
      PlacesApiService.searchNearby(
        lat: lat,
        lng: lng,
        types: [
          'movie_theater', 'amusement_park', 'bowling_alley', 'karaoke',
          'video_arcade', 'night_club', 'amusement_center', 'concert_hall',
          'gym', 'fitness_center', 'spa',
        ],
        maxResultCount: 20,
        radius: fetchRadius,
      ),
      PlacesApiService.searchNearby(
        lat: lat,
        lng: lng,
        types: [
          'subway_station', 'bus_station', 'bus_stop', 'transit_station',
          'light_rail_station', 'taxi_stand', 'train_station',
          'hospital', 'doctor', 'medical_clinic', 'bank', 'atm', 'post_office',
        ],
        maxResultCount: 20,
        radius: fetchRadius,
      ),
      PlacesApiService.searchNearby(
        lat: lat,
        lng: lng,
        types: [
          'park', 'national_park', 'botanical_garden', 'garden', 'hiking_area',
          'beach', 'museum', 'art_gallery', 'tourist_attraction',
          'historical_landmark', 'monument',
          'shopping_mall', 'supermarket', 'grocery_store', 'department_store',
          'clothing_store', 'electronics_store', 'pharmacy', 'book_store',
          'convenience_store', 'market',
        ],
        maxResultCount: 20,
        radius: fetchRadius,
      ),
    ]).then((r) => [...r[0], ...r[1], ...r[2], ...r[3]]);

    print('📦 Google raw response: ${googleRaw.length} results');

    final seenIds = <String>{};
    final places = <PlaceModel>[];

    for (final p in googleRaw) {
      final id = p['id'] as String? ?? '';
      if (id.isEmpty || seenIds.contains(id)) continue;
      seenIds.add(id);

      final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
      final primaryType = CategoryMapper.toPrimaryType(googleTypes);
      if (primaryType == 'other') continue;

      final place = PlaceModel.fromGoogle(p, primary: primaryType);
      if (place.lat == null || place.lng == null) continue;

      places.add(place);
    }

    _googleRawCache[key] = places;
    _googleRawCacheRadius[key] = fetchRadius;
    _googleLru.touch(key);


    print('✅ Google raw cache STORED for $key: ${places.length} places @ ${fetchRadius}m '
        '— will NOT call Google again for this location unless a radius > '
        '${fetchRadius}m is requested.');

    return places;
  }

  Future<List<PlaceModel>> getOrFetchGooglePlaces({
    required double lat,
    required double lng,
    int radius = 12000,
  }) async {
    final all = await _fetchGoogleOnce(lat, lng, radius);
    return all.where((p) {
      if (p.lat == null || p.lng == null) return false;
      return _haversineMetres(lat, lng, p.lat!, p.lng!) <= radius;
    }).toList();
  }

  Future<List<PlaceModel>> fetchCompleteForItinerary({
    required double lat,
    required double lng,
    int radius = 12000,
  }) async {
    final results = <PlaceModel>[];
    final byType  = <String, List<PlaceModel>>{};
    final completer = Completer<void>();

    await _fetchAndStore(
      lat: lat,
      lng: lng,
      targetList: results,
      targetByType: byType,
      radius: radius,
      onGeoapifyDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => print('⚠️ Geoapify 超时 — 只用 Google 结果继续生成行程'),
    );

    print('🏁 fetchCompleteForItinerary: 最终 ${results.length} 个候选地点 (Google+Geoapify 完整)');
    return results;
  }
  
  void clearGoogleRawCache([double? lat, double? lng]) {
    if (lat != null && lng != null) {
      final key = _locKey(lat, lng);
      _googleRawCache.remove(key);
      _googleRawCacheRadius.remove(key);
      _googleLru.remove(key);
      print('♻️ Google raw cache cleared for $key');
    } else {
      _googleRawCache.clear();
      _googleRawCacheRadius.clear();
      _googleLru.clear();
      print('♻️ Google raw cache cleared for ALL locations');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchGeoapifyOnce(
    double lat,
    double lng,
    int requestedRadius,
  ) async {
    final key = _locKey(lat, lng);
    final cachedRadius = _geoapifyRawCacheRadius[key];

    if (_geoapifyRawCache.containsKey(key) &&
        cachedRadius != null &&
        cachedRadius >= requestedRadius) {
      print('🆓 Geoapify raw cache HIT for $key '
          '(cached at ${cachedRadius}m, need ${requestedRadius}m) — no API call');
      return _geoapifyRawCache[key]!;
    }

    final fetchRadius = max(_geoapifyMaxRadius, requestedRadius);

    print('🟣 Geoapify raw cache MISS for $key — calling Geoapify '
        'ONCE at radius ${fetchRadius}m (requested: ${requestedRadius}m)');

    final raw = await GeoapifyService.fetchNearby(
      lat: lat,
      lng: lng,
      radius: fetchRadius,
    );

    _geoapifyRawCache[key] = raw;
    _geoapifyRawCacheRadius[key] = fetchRadius;

    print('✅ Geoapify raw cache STORED for $key: ${raw.length} places @ ${fetchRadius}m '
        '— will NOT call Geoapify again for this location unless a radius > '
        '${fetchRadius}m is requested.');

    return raw;
  }

  void clearGeoapifyRawCache([double? lat, double? lng]) {
    if (lat != null && lng != null) {
      final key = _locKey(lat, lng);
      _geoapifyRawCache.remove(key);
      _geoapifyRawCacheRadius.remove(key);
      print('♻️ Geoapify raw cache cleared for $key');
    } else {
      _geoapifyRawCache.clear();
      _geoapifyRawCacheRadius.clear();
      print('♻️ Geoapify raw cache cleared for ALL locations');
    }
  }

  Future<List<PlaceModel>> _fetchAndStore({
    required double lat,
    required double lng,
    required List<PlaceModel> targetList,
    required Map<String, List<PlaceModel>> targetByType,
    int radius = 5000,
    int? generation,
    bool Function()? isCurrentGeneration,
    Function(List<PlaceModel>)? onGoogleReady,
    Function(List<PlaceModel>)? onGeoapifyBatchAdd,
    Function()? onGeoapifyDone,
  }) async {

    print('🌍 NearbyPlacesService: Phase 1 (Google) — get-or-fetch-once, then filter to ${radius}m...');

    final googleAll = await _fetchGoogleOnce(lat, lng, radius);

    if (isCurrentGeneration != null && !isCurrentGeneration()) {
      print('🚫 Phase 1 result discarded — stale generation ($generation)');
      return [];
    }

    final seenIds = <String>{};
    final seenCoords = <({double lat, double lng})>[];

    final googlePlaces = <PlaceModel>[];

    for (final place in googleAll) {
      if (place.lat == null || place.lng == null) continue;

      final dist = _haversineMetres(lat, lng, place.lat!, place.lng!);
      if (dist > radius) continue;

      final id = place.id;
      if (id.isEmpty || seenIds.contains(id)) continue;
      seenIds.add(id);

      final primaryType = CategoryMapper.toPrimaryType(place.allTypes);
      if (primaryType == 'other') continue;

      googlePlaces.add(place);
      targetList.add(place);
      targetByType.putIfAbsent(primaryType, () => []);
      targetByType[primaryType]!.add(place);

      seenCoords.add((lat: place.lat!, lng: place.lng!));
    }

    print('⚡ Phase 1 done — Google filtered to ${radius}m: ${googlePlaces.length} places '
        '(of ${googleAll.length} cached total)');
    onGoogleReady?.call(List.unmodifiable(googlePlaces));

    unawaited(_runGeoapifyPhase(
      lat: lat,
      lng: lng,
      radius: radius,
      targetList: targetList,
      targetByType: targetByType,
      seenIds: seenIds,
      seenCoords: seenCoords,
      isCurrentGeneration: isCurrentGeneration,
      onGeoapifyBatchAdd: onGeoapifyBatchAdd,
      onGeoapifyDone: onGeoapifyDone,
    ));

    return googlePlaces;
  }

  Future<void> _runGeoapifyPhase({
    required double lat,
    required double lng,
    required int radius,
    required List<PlaceModel> targetList,
    required Map<String, List<PlaceModel>> targetByType,
    required Set<String> seenIds,
    required List<({double lat, double lng})> seenCoords,
    bool Function()? isCurrentGeneration,
    Function(List<PlaceModel>)? onGeoapifyBatchAdd,
    Function()? onGeoapifyDone,
  }) async {
    final pendingBatch = <PlaceModel>[];
    Timer? flushTimer;

    void flush() {
      flushTimer?.cancel();
      flushTimer = null;
      if (pendingBatch.isEmpty) return;
      if (isCurrentGeneration != null && !isCurrentGeneration()) {
        pendingBatch.clear();
        return;
      }
      onGeoapifyBatchAdd?.call(List.unmodifiable(pendingBatch));
      pendingBatch.clear();
    }

    void scheduleFlush() {
      if (pendingBatch.length >= 8) {
        flush();
        return;
      }
      flushTimer ??= Timer(const Duration(milliseconds: 250), flush);
    }

    try {
      print('🟣 Phase 2 (Geoapify): get-or-fetch-once, then filter to ${radius}m...');
      final geoapifyRaw = await _fetchGeoapifyOnce(lat, lng, radius);

      if (isCurrentGeneration != null && !isCurrentGeneration()) {
        print('🚫 Phase 2 result discarded entirely — stale generation');
        return;
      }

      final candidates = <Map<String, dynamic>>[];
      int geoDuped = 0;
      int geoTooFar = 0;

      for (final p in geoapifyRaw) {
        if (isCurrentGeneration != null && !isCurrentGeneration()) {
          print('🚫 Phase 2 aborted mid-filter — stale generation');
          break;
        }

        final id = p['id'] as String? ?? '';
        if (id.isEmpty || seenIds.contains(id)) continue;

        final locMap = p['location'] as Map<String, dynamic>?;
        final pLat = (locMap?['latitude'] as num?)?.toDouble();
        final pLng = (locMap?['longitude'] as num?)?.toDouble();
        if (pLat == null || pLng == null) continue;

        final dist = _haversineMetres(lat, lng, pLat, pLng);
        if (dist > radius) { geoTooFar++; continue; }

        bool tooClose = false;
        for (final c in seenCoords) {
          if (_haversineMetres(c.lat, c.lng, pLat, pLng) < _dedupDistanceMetres) {
            tooClose = true;
            break;
          }
        }
        if (tooClose) { geoDuped++; continue; }

        final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
        final primaryType = CategoryMapper.toPrimaryType(googleTypes);
        if (primaryType == 'other') continue;

        seenIds.add(id);
        seenCoords.add((lat: pLat, lng: pLng));

        candidates.add(p);
      }

      print('🟣 Phase 2 候选（radius+dedup 过滤后）: ${candidates.length} '
          '（重复 $geoDuped，超距 $geoTooFar）');

      if (candidates.isEmpty) {
        print('🟣 Phase 2 done: 无候选地点');
        return;
      }

      final enrichInput = candidates.map((p) {
        final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
        final primaryType = CategoryMapper.toPrimaryType(googleTypes);
        return {
          'placeId':     p['id'] as String? ?? '',
          'primaryType': primaryType,
          'placeName':   (p['displayName']?['text'] as String?) ?? '',
          'address':     (p['formattedAddress'] as String?) ?? '',
        };
      }).toList();

      Map<String, List<String>> enrichedTypes = {};
        final enrichStopwatch = Stopwatch()..start();
        try {
          enrichedTypes = await GeoapifyEnrichmentService
              .enrichPlaces(enrichInput)
              .timeout(const Duration(seconds: 35));
          print('⏱️ enrichPlaces 总耗时: ${enrichStopwatch.elapsedMilliseconds}ms');
        } catch (e) {
          print('⚠️ Geoapify enrichment 失败（耗时 ${enrichStopwatch.elapsedMilliseconds}ms），'
              '本批次 fallback 用名字关键词: $e');
        }

      if (isCurrentGeneration != null && !isCurrentGeneration()) {
        print('🚫 Phase 2 aborted after enrichment — stale generation');
        return;
      }

      int geoAdded = 0;
      for (final p in candidates) {
        if (isCurrentGeneration != null && !isCurrentGeneration()) {
          print('🚫 Phase 2 aborted mid-loop — stale generation');
          break;
        }

        final id = p['id'] as String? ?? '';
        final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
        final primaryType = CategoryMapper.toPrimaryType(googleTypes);

        final extraTypes = enrichedTypes[id] ?? const [];
        if (extraTypes.isNotEmpty) {
          p['types'] = [...googleTypes, ...extraTypes];
        }

        final place = PlaceModel.fromGoogle(p, primary: primaryType);
        if (place.lat == null || place.lng == null) continue;

        targetList.add(place);
        targetByType.putIfAbsent(primaryType, () => []);
        targetByType[primaryType]!.add(place);

        geoAdded++;
        pendingBatch.add(place);
        scheduleFlush();
      }

      flush();

      print('🟣 Phase 2 done: +$geoAdded added（已带具体子分类）');
      print('✅ Final total: ${targetList.length}');
    } catch (e) {
      flush();
      print('⚠️ Geoapify phase failed (Google results unaffected): $e');
    } finally {
      flushTimer?.cancel();
      if (isCurrentGeneration == null || isCurrentGeneration()) {
        onGeoapifyDone?.call();
      }
    }
  }
  
  int _cachedRadius = 0;
  double? _cachedLat;
  double? _cachedLng;

  static const double _cacheLocationToleranceMetres = 500;

Future<List<PlaceModel>> loadNearbyPlacesOnce(
  List<Map<String, dynamic>> categories,
  BuildContext context, {
  double? lat,
  double? lng,
  int radius = 12000,
  Function(PlaceModel)? onGeoapifyAdd,
  Function(List<PlaceModel>)? onGeoapifyBatchAdd,
  Function()? onGeoapifyDone,
}) async {
  if (_isLoading) {
    print('⏳ NearbyPlacesService: already loading');
    return _allPlacesCache;
  }

  final pos = LocationService.instance.currentPosition;

  if (pos == null && lat == null) {
    throw Exception('No location');
  }

  final searchLat = lat ?? pos!.latitude;
  final searchLng = lng ?? pos!.longitude;

  final sameLocation =
      _cachedLat != null &&
      _cachedLng != null &&
      _haversineMetres(
        _cachedLat!,
        _cachedLng!,
        searchLat,
        searchLng,
      ) <= _cacheLocationToleranceMetres;

  if (_hasLoadedOnce &&
      _cachedRadius == radius &&
      sameLocation) {
    print(
      '🧠 NearbyPlacesService: using cache '
      '(radius ${radius}m, same location)',
    );
    return _allPlacesCache;
  }



    final myGeneration = ++_currentGeneration;
    bool isCurrentGeneration() => myGeneration == _currentGeneration;

    _isLoading = true;
    _isBackgroundLoading = true;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();

    final stopwatch = Stopwatch()..start();

    try {
      final googlePlaces = await _fetchAndStore(
        lat:        searchLat,
        lng:        searchLng,
        targetList: _allPlacesCache,
        targetByType: _placesByTypeCache,
        radius:     radius,
        generation: myGeneration,
        isCurrentGeneration: isCurrentGeneration,
        onGeoapifyBatchAdd: (batch) {
          onGeoapifyBatchAdd?.call(batch);
          if (onGeoapifyAdd != null) {
            for (final place in batch) {
              onGeoapifyAdd(place);
            }
          }
        },
        onGeoapifyDone: () {
          print('🏁 Geoapify merge finished (background)');
          _isBackgroundLoading = false;
          onGeoapifyDone?.call();
        },
      );

      stopwatch.stop();

      if (isCurrentGeneration()) {
        _hasLoadedOnce = true;
        _cachedRadius  = radius;
        _cachedLat     = searchLat;
        _cachedLng     = searchLng;
      }

      print('🏁 Phase 1 returned: ${googlePlaces.length} Google places in '
          '${stopwatch.elapsedMilliseconds}ms (radius: ${radius}m)');

      return _allPlacesCache;
    } finally {
      if (isCurrentGeneration()) {
        _isLoading = false;
      }
    }
  }

  Future<List<PlaceModel>> loadNearbyPlacesAt({
    required double lat,
    required double lng,
    required List<Map<String, dynamic>> categories,
    required BuildContext context,
    int radius = 12000,
    Function(PlaceModel)? onGeoapifyAdd,
    Function(List<PlaceModel>)? onGeoapifyBatchAdd,
    Function()? onGeoapifyDone,
  }) async {
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
        radius:       radius,
        onGeoapifyBatchAdd: (batch) {
          onGeoapifyBatchAdd?.call(batch);
          if (onGeoapifyAdd != null) {
            for (final place in batch) {
              onGeoapifyAdd(place);
            }
          }
        },
        onGeoapifyDone: onGeoapifyDone,
      );

      print('✅ loadNearbyPlacesAt: ${results.length} places (Google phase)');
      _searchCache[cacheKey] = results;

      return results;

    } finally {
      _loadingKeys.remove(cacheKey);
    }
  }

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

  void precacheOrderedImages(
    BuildContext context, {
    required List<PlaceModel> orderedPlaces,
    int limit = _maxPrecacheImages,
  }) {
    if (!context.mounted) return;

    final toPrecache = orderedPlaces
        .where((p) => p.photoUrl != null)
        .take(limit)
        .toList();

    print('🖼️ Precaching ${toPrecache.length} images '
        '(ordered by caller — matches whatever is rendered first)');

    _precacheInBatches(context, toPrecache);
  }

  Future<void> _precacheInBatches(
    BuildContext context,
    List<PlaceModel> places, {
    int batchSize = _precacheBatchSize,
  }) async {
    for (int i = 0; i < places.length; i += batchSize) {
      if (!context.mounted) return;
      final batch = places.skip(i).take(batchSize);
      try {
        await Future.wait(
          batch.map((p) => precacheImage(NetworkImage(p.photoUrl!), context)),
        );
      } catch (e) {
        print('⚠️ Precache batch failed (continuing): $e');
      }
      if (i + batchSize < places.length) {
        await Future.delayed(const Duration(milliseconds: 80));
      }
    }
  }

  void clearCache() {
    print('♻️ NearbyPlacesService: cache cleared');
    _currentGeneration++;
    _hasLoadedOnce = false;
    _cachedRadius  = 0;
    _isLoading = false;
    _isBackgroundLoading = false;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();
  }

  void clearSearchCache() {
    print('♻️ NearbyPlacesService: search cache cleared');
    _searchCache.clear();
  }

  static const Map<String, List<String>> _itineraryCategoryTypes = {
    'restaurant':         CategoryMapper.restaurantTypes,
    'tourist_attraction': CategoryMapper.attractionTypes,
    'shopping_mall':      CategoryMapper.shoppingTypes,
    'entertainment':      CategoryMapper.entertainmentTypesForItinerary,
    'park':               CategoryMapper.natureTypes,
  };

Future<List<PlaceModel>> fetchForItinerary({
  required double lat,
  required double lng,
  required List<String> categories,
  int radius = 12000,
}) async {

  print('🎯 [fetchForItinerary] entered with radius=${radius}m (lat=$lat, lng=$lng)');

  final locationKey = _locKey(lat, lng);
  final normalizedCategories = categories.toSet().toList()..sort();
  final cacheKey = '$locationKey|${normalizedCategories.join(",")}'
      '|POPULARITY';
  final cachedRadius = _itineraryRawCacheRadius[cacheKey];

  if (_itineraryRawCache.containsKey(cacheKey) &&
      cachedRadius != null &&
      cachedRadius == radius) {
    _itineraryLru.touch(cacheKey);
    print('🆓 Itinerary raw cache HIT for $cacheKey '
        '(cached at ${cachedRadius}m, need ${radius}m) — no API call');
    return _itineraryRawCache[cacheKey]!
        .where((p) =>
            p.lat != null &&
            p.lng != null &&
            _haversineMetres(lat, lng, p.lat!, p.lng!) <= radius)
        .toList();
  }

  final relevantEntries = _itineraryCategoryTypes.entries
      .where((e) => normalizedCategories.contains(e.key))
      .toList();

  print('🗺️ Itinerary cache MISS — preference categories are fetched '
      'independently with POPULARITY ranking (radius: ${radius}m)...');

  final entries = await Future.wait(
    relevantEntries.map((entry) async {
      final primary = entry.key;
      // Keep CategoryMapper as the source of truth, but do not send its
      // legacy app alias `malay_restaurant` to Google. Nearby Search accepts
      // only official Table A request types (`malaysian_restaurant` is the
      // supported Google type).
      final types = entry.value
          .where((type) => type != 'malay_restaurant')
          .toList();
      try {
        final raw = await PlacesApiService.searchNearby(
          lat: lat, lng: lng,
          types: types,
          maxResultCount: 20,
          radius: radius,
          rankPreference: 'POPULARITY',
        );
        final seen = <String>{};
        final places = <PlaceModel>[];

        void addRawPlaces(List<Map<String, dynamic>> rawPlaces) {
          for (final item in rawPlaces) {
            final place = PlaceModel.fromGoogle(item, primary: primary);
            if (place.id.isEmpty ||
                place.lat == null ||
                place.lng == null ||
                CategoryMapper.resolvePrimaryType(
                      place.primaryType,
                      place.allTypes,
                    ) !=
                    primary ||
                !seen.add(place.id)) {
              continue;
            }
            places.add(place);
          }
        }

        addRawPlaces(raw);

        print('  ✅ $primary: ${places.length} popularity-ranked candidates');
        return places;
      } catch (e) {
        print('  ⚠️ $primary failed: $e');
        return <PlaceModel>[];
      }
    }),
  );

  final seenIds = <String>{};
  final places  = <PlaceModel>[];
  for (final list in entries) {
    for (final p in list) {
      if (p.id.isEmpty || seenIds.contains(p.id)) continue;
      seenIds.add(p.id);
      places.add(p);
    }
  }

  _itineraryRawCache[cacheKey] = places;
  _itineraryRawCacheRadius[cacheKey] = radius;
  _itineraryLru.touch(cacheKey);

  print('✅ Itinerary raw cache STORED for $cacheKey: '
      '${places.length} places @ ${radius}m');
  return places;
}

Future<List<PlaceModel>> fetchAdditionalForItinerary({
  required double lat,
  required double lng,
  required int radius,
  required Map<String, int> additionalNeededByCategory,
  required Set<String> existingPlaceIds,
}) async {
  final requestedEntries = _itineraryCategoryTypes.entries
      .where((entry) =>
          (additionalNeededByCategory[entry.key] ?? 0) > 0)
      .toList();

  if (requestedEntries.isEmpty) return [];

  const typeBatchSize = 4;
  final fetchedByCategory = await Future.wait(
    requestedEntries.map((entry) async {
      final category = entry.key;
      final needed = additionalNeededByCategory[category] ?? 0;
      final queryTypes = entry.value
          .where((type) => type != 'malay_restaurant')
          .toList();
      final localSeen = <String>{...existingPlaceIds};
      final additional = <PlaceModel>[];

      for (int start = 0;
          start < queryTypes.length && additional.length < needed;
          start += typeBatchSize) {
        final end = min(start + typeBatchSize, queryTypes.length);
        try {
          final raw = await PlacesApiService.searchNearby(
            lat: lat,
            lng: lng,
            types: queryTypes.sublist(start, end),
            maxResultCount: 20,
            radius: radius,
            rankPreference: 'POPULARITY',
          );

          for (final item in raw) {
            final place = PlaceModel.fromGoogle(item, primary: category);
            if (place.id.isEmpty ||
                place.lat == null ||
                place.lng == null ||
                CategoryMapper.resolvePrimaryType(
                      place.primaryType,
                      place.allTypes,
                    ) !=
                    category ||
                !localSeen.add(place.id)) {
              continue;
            }
            additional.add(place);
            if (additional.length >= needed) break;
          }
        } catch (e) {
          print('  ⚠️ Additional $category batch failed: $e');
        }
      }

      print('  ➕ $category: ${additional.length}/$needed extra candidates');
      return additional;
    }),
  );

  final merged = <PlaceModel>[];
  final mergedIds = <String>{...existingPlaceIds};
  for (final list in fetchedByCategory) {
    for (final place in list) {
      if (mergedIds.add(place.id)) merged.add(place);
    }
  }
  return merged;
}


void clearItineraryRawCache([double? lat, double? lng]) {
  if (lat != null && lng != null) {
    final prefix = '${_locKey(lat, lng)}|';
    final keys = _itineraryRawCache.keys
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in keys) {
      _itineraryRawCache.remove(key);
      _itineraryRawCacheRadius.remove(key);
      _itineraryLru.remove(key);
    }
  } else {
    _itineraryRawCache.clear();
    _itineraryRawCacheRadius.clear();
    _itineraryLru.clear();
  }
}

}

