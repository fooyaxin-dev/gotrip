import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../models/placeModel.dart';
import 'placesAPI_service.dart';
import 'geoapify_service.dart';
import 'location_service.dart';
import 'geoapifyEnrichment_service.dart';

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

  // 💰 NEW: Google Places is the expensive API, so it is only ever called
  // ONCE per location, always at `_googleMaxRadius`. Every subsequent
  // radius change for the SAME location is served by filtering this cached
  // list locally (haversine distance check) — zero extra Google calls.
  //
  // ⚠️ Tune `_googleMaxRadius` to match the largest radius option your UI
  // offers (e.g. if your radius slider/chips go up to 8000m, set this to
  // 8000). If a user later requests a radius LARGER than this constant,
  // we transparently fall back to a fresh Google call at that larger
  // radius (see `_fetchGoogleOnce`), so correctness is preserved either way
  // — this constant is a cost/coverage tuning knob, not a hard cap.
  static const int _googleMaxRadius = 15000;

  // location-key ('lat,lng' rounded to 3dp ≈ 111m) → raw Google places
  // (parsed, NOT filtered by radius) fetched at up to `_googleMaxRadius`.
  final Map<String, List<PlaceModel>> _googleRawCache = {};
  // tracks the actual radius each cache entry was fetched at, since we
  // may occasionally need to widen it (see note above).
  final Map<String, int> _googleRawCacheRadius = {};

  // 🆓 NEW: same fetch-once-and-filter-locally pattern, applied to Geoapify.
  // Even though Geoapify is "free", every radius change still meant a real
  // network round-trip and (if the UI debounces radius changes poorly,
  // e.g. a slider) wasted/duplicate in-flight requests. Caching it the same
  // way as Google means shrinking the radius is instant (no network at
  // all), and only widening beyond what's cached triggers a fresh call.
  static const int _geoapifyMaxRadius = 15000; // tune independently of Google's
  final Map<String, List<Map<String, dynamic>>> _geoapifyRawCache = {};
  final Map<String, int> _geoapifyRawCacheRadius = {};

  String _locKey(double lat, double lng) =>
      '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';

  // 🔒 NEW: generation token — guards the shared cache (_allPlacesCache /
  // _placesByTypeCache) against stale background (Geoapify) writes from a
  // previous loadNearbyPlacesOnce() call that hasn't finished yet when a
  // new one starts (e.g. user changes radius / location quickly).
  int _currentGeneration = 0;

  // 🔒 NEW: separate "background still working" flag, since _isLoading only
  // reflects Phase 1 (Google). UI can use this to show a subtle
  // "still finding more places…" indicator if it wants to.
  bool _isBackgroundLoading = false;
  bool get isBackgroundLoading => _isBackgroundLoading;

  List<PlaceModel> get cachedPlaces => _allPlacesCache;
  List<PlaceModel> get allPlaces => List.unmodifiable(_allPlacesCache);
  Map<String, List<PlaceModel>> get placesByType => Map.unmodifiable(_placesByTypeCache);
  bool get hasLoaded => _hasLoadedOnce;

 // ── Primary type mapping ────────────────────────────────────────────────────
  //
  // 🔧 FIX #2: 酒店/住宿类地点会连带一堆附属设施的 Google types（cafe、
  // water_park、spa...），如果不先排除，它们会被这些附属类型"捡漏"
  // 归进 restaurant/entertainment，而不是被识别成"这其实是一间酒店"。
  // 你现在的 6 大分类里没有"住宿"这一类，所以这里直接排除，让它们
  // 落到 'other'（被上层调用方过滤掉），不会再被误判成别的分类。
  //
  // 如果你之后想让酒店也能显示（比如新增一个 accommodation 分类），
  // 把下面这段改成 return 'accommodation' 而不是 return 'other' 即可，
  // 但那样要同步在 UI 那边（categories 列表/图标/子分类）加这个新分类。
  static String _mapToPrimaryType(List<String> googleTypes) {
    if (googleTypes.any((t) => [
      'hotel', 'lodging', 'resort_hotel', 'motel', 'guest_house',
      'hostel', 'bed_and_breakfast', 'extended_stay_hotel', 'inn',
    ].contains(t))) return 'other';

    if (googleTypes.any((t) => [
      'restaurant', 'cafe', 'coffee_shop', 'bakery',
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
      'gym', 'fitness_center', 'spa', 'bar',
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

  // ─────────────────────────────────────────────────────────────────────────
  // 💰 Get-or-fetch Google Places for a location, ONCE.
  //
  // - Cache hit (same location, cached radius already ≥ requested radius):
  //   returns the cached list immediately, NO network call.
  // - Cache miss (first time at this location, OR user requests a radius
  //   bigger than what we originally cached): makes the 4 parallel Google
  //   calls at max(requested radius, _googleMaxRadius) and caches the
  //   result for next time.
  //
  // Returned list is UNFILTERED by radius — the caller (_fetchAndStore)
  // does the cheap local distance filter for whatever radius it needs.
  // ─────────────────────────────────────────────────────────────────────────
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
      print('🆓 Google raw cache HIT for $key '
          '(cached at ${cachedRadius}m, need ${requestedRadius}m) — no API call');
      return _googleRawCache[key]!;
    }

    // Either first time here, or the user asked for a radius wider than
    // what we cached before — fetch at whichever is larger so we don't
    // have to widen again soon.
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
          'park', 'national_park', 'botanical_garden', 'hiking_area',
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
      final primaryType = _mapToPrimaryType(googleTypes);
      if (primaryType == 'other') continue;

      final place = PlaceModel.fromGoogle(p, primary: primaryType);
      if (place.lat == null || place.lng == null) continue;

      places.add(place);
    }

    _googleRawCache[key] = places;
    _googleRawCacheRadius[key] = fetchRadius;

    print('✅ Google raw cache STORED for $key: ${places.length} places @ ${fetchRadius}m '
        '— will NOT call Google again for this location unless a radius > '
        '${fetchRadius}m is requested.');

    return places;
  }

  
  /// 🔗 全 app 共享入口——Home、Nearby、行程生成，现在都从这里拿原始 Google 数据。
  /// 同一个位置只会真正打一次 Google Places API，之后谁来调用都直接吃缓存。
  Future<List<PlaceModel>> getOrFetchGooglePlaces({
    required double lat,
    required double lng,
    int radius = 10000,
  }) async {
    final all = await _fetchGoogleOnce(lat, lng, radius);
    // 🔧 FIX: _fetchGoogleOnce 只负责"抓取"，不做半径过滤——
    // 之前直接透传会导致实际返回的是 _googleMaxRadius(15000m)范围内的
    // 全部结果，而不是调用方要求的 radius。
    return all.where((p) {
      if (p.lat == null || p.lng == null) return false;
      return _haversineMetres(lat, lng, p.lat!, p.lng!) <= radius;
    }).toList();
  }

  // 🆕 给 searched location 场景用 — Google + Geoapify 都跑，而且必须
  // 等 Geoapify 背景 phase 真正跑完才返回。跟 loadNearbyPlacesAt 的差别：
  // 那个是给地图搜索用的，Geoapify 用 unawaited 背景补，UI 可以先看到
  // Google 结果；这里是一次性批量排程，不能让 itinerary 漏掉 Geoapify
  // 才有的候选地点，所以要完整等待。
  Future<List<PlaceModel>> fetchCompleteForItinerary({
    required double lat,
    required double lng,
    int radius = 10000,
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

    // _fetchAndStore 本身 Google phase 跑完就 return 了；
    // 这里额外等 Geoapify 背景 phase 也真正结束（加超时保险，
    // 避免 Geoapify 网络异常时把整个行程生成卡死）。
    await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => print('⚠️ Geoapify 超时 — 只用 Google 结果继续生成行程'),
    );

    print('🏁 fetchCompleteForItinerary: 最终 ${results.length} 个候选地点 (Google+Geoapify 完整)');
    return results;
  }
  
  // Explicit escape hatch — call this if you ever need to force a fresh
  // (paid) Google call for a location, e.g. a manual "refresh" button.
  void clearGoogleRawCache([double? lat, double? lng]) {
    if (lat != null && lng != null) {
      final key = _locKey(lat, lng);
      _googleRawCache.remove(key);
      _googleRawCacheRadius.remove(key);
      print('♻️ Google raw cache cleared for $key');
    } else {
      _googleRawCache.clear();
      _googleRawCacheRadius.clear();
      print('♻️ Google raw cache cleared for ALL locations');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 🆓 Get-or-fetch Geoapify for a location, ONCE per radius-widening step.
  // Same shape as _fetchGoogleOnce: cache hit → zero network calls; cache
  // miss (first time, or requested radius wider than cached) → real fetch.
  //
  // Returns RAW (unfiltered by radius) normalized maps — same shape
  // GeoapifyService.fetchNearby always returned — so the existing
  // radius-filter / dedup / batching logic in _runGeoapifyPhase works
  // completely unchanged.
  // ─────────────────────────────────────────────────────────────────────────
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

  // Explicit escape hatch for Geoapify's cache too.
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

  // ─────────────────────────────────────────────────────────────────────────
  // Core fetch — split into 2 phases:
  //   Phase 1 (Google)    → awaited here, returned immediately to the caller
  //   Phase 2 (Geoapify)  → fired via unawaited(), merges into targetList/
  //                          targetByType in the background and reports
  //                          new places through onGeoapifyBatchAdd (batched,
  //                          throttled) so the UI doesn't rebuild on every
  //                          single place.
  //
  //   `generation`: the token this call belongs to. Every write into the
  //   shared targetList/targetByType is gated on
  //   (generation == checkGeneration()) so a slow, stale Phase 2 from an
  //   older call can never corrupt a newer call's cache.
  // ─────────────────────────────────────────────────────────────────────────
  Future<List<PlaceModel>> _fetchAndStore({
    required double lat,
    required double lng,
    required List<PlaceModel> targetList,
    required Map<String, List<PlaceModel>> targetByType,
    int radius = 5000,

    // 🔒 generation guard (null = no guard needed, e.g. loadNearbyPlacesAt
    // which uses a fresh local list per call instead of a shared cache)
    int? generation,
    bool Function()? isCurrentGeneration,

    // 🔥 streaming callbacks
    Function(List<PlaceModel>)? onGoogleReady,
    Function(List<PlaceModel>)? onGeoapifyBatchAdd, // ← batched, not per-place
    Function()? onGeoapifyDone,
  }) async {

    print('🌍 NearbyPlacesService: Phase 1 (Google) — get-or-fetch-once, then filter to ${radius}m...');

    // ─────────────────────────────────────────────
    // 💰 PHASE 1: GOOGLE — fetched at most ONCE per location (see
    // _fetchGoogleOnce). Only this is awaited by the caller.
    // ─────────────────────────────────────────────
    final googleAll = await _fetchGoogleOnce(lat, lng, radius);

    // 🔒 If a newer call has already superseded this one, bail out before
    // touching the shared cache at all.
    if (isCurrentGeneration != null && !isCurrentGeneration()) {
      print('🚫 Phase 1 result discarded — stale generation ($generation)');
      return [];
    }

    // Shared dedup state — both phases write into the SAME instances,
    // so Phase 2 correctly skips anything Phase 1 already added.
    // Seeded only with places that pass the CURRENT radius filter, since
    // anything beyond `radius` shouldn't count as "already shown" (and
    // Geoapify itself is radius-filtered to the same `radius` below).
    final seenIds = <String>{};
    final seenCoords = <({double lat, double lng})>[];

    final googlePlaces = <PlaceModel>[];

    for (final place in googleAll) {
      if (place.lat == null || place.lng == null) continue;

      // 📏 local filter — no network call, just a distance check
      final dist = _haversineMetres(lat, lng, place.lat!, place.lng!);
      if (dist > radius) continue;

      final id = place.id; // ⚠️ assumes PlaceModel exposes `.id` — if your
      // PlaceModel field is named differently, swap it in here and below.
      if (id.isEmpty || seenIds.contains(id)) continue;
      seenIds.add(id);

      // PlaceModel doesn't expose the primary type it was tagged with, so
      // recompute it from its raw Google types (same helper used elsewhere).
      // Skip 'other' entirely, same as the original code did.
      final primaryType = _mapToPrimaryType(place.allTypes);
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

    // ─────────────────────────────────────────────
    // 🌍 PHASE 2: GEOAPIFY — fired in the background,
    // does NOT block this function from returning.
    // ─────────────────────────────────────────────
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

    // Phase 1 result is what the caller gets synchronously.
    return googlePlaces;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Phase 2 — Geoapify, runs independently after Phase 1 has returned.
  // Any failure here is swallowed so it never affects the Google results
  // that are already showing on screen.
  //
  // 🔒 Every write is gated on isCurrentGeneration() so a slow response
  // from an old (superseded) call can never leak into the current cache.
  //
  // 🔥 Additions are batched and flushed at most every 250ms (or every 8
  // places, whichever comes first) instead of one callback per place, so
  // the UI isn't forced to rebuild dozens of times in quick succession.
  // ─────────────────────────────────────────────────────────────────────────
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

      // ── STEP 1: id / radius / dedup 过滤，先不建 PlaceModel ──────────────
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
        final primaryType = _mapToPrimaryType(googleTypes);
        if (primaryType == 'other') continue;

        // 占位登记，跟原逻辑一致——保证同一轮内后面的地点 dedup 判断正确
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

      // ── STEP 2: 🆕 对候选地点批量做 enrichment，解出具体子分类 ────────────
      // enrichPlaces() 内部会：查 Firestore 缓存 → OSM tag → 
      // 全部剩余的一次性丢给 Gemini → 名字兜底
      // 这里对"这一批候选"只调用一次，不是每个地点单独调
      final enrichInput = candidates.map((p) {
        final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
        final primaryType = _mapToPrimaryType(googleTypes);
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

      // ── STEP 3: 合并具体类型，建 PlaceModel，写入缓存 + 流式推给 UI ──────
      int geoAdded = 0;
      for (final p in candidates) {
        if (isCurrentGeneration != null && !isCurrentGeneration()) {
          print('🚫 Phase 2 aborted mid-loop — stale generation');
          break;
        }

        final id = p['id'] as String? ?? '';
        final googleTypes = (p['types'] as List?)?.cast<String>() ?? [];
        final primaryType = _mapToPrimaryType(googleTypes);

        // 把 enrichment 解出来的具体类型（如 chinese_restaurant）
        // 合并进 Geoapify 原本的通用类型里
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
  
  // ── Public: load once (real-time GPS mode) ─────────────────────────────────
  int _cachedRadius = 0; // track which radius the current cache was loaded with

  Future<List<PlaceModel>> loadNearbyPlacesOnce(
    List<Map<String, dynamic>> categories,
    BuildContext context, {
    double? lat,
    double? lng,
    int radius = 5000,
    Function(PlaceModel)? onGeoapifyAdd,       // kept for backwards-compat (per-place)
    Function(List<PlaceModel>)? onGeoapifyBatchAdd, // ← NEW: preferred, batched
    Function()? onGeoapifyDone,
  }) async {
    // Use cache only if radius matches — otherwise reload
    if (_hasLoadedOnce && _cachedRadius == radius) {
      print('🧠 NearbyPlacesService: using cache (radius ${radius}m)');
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

    // 🔒 mint a new generation token for this call and invalidate any
    // in-flight background phase from a previous call.
    final myGeneration = ++_currentGeneration;
    bool isCurrentGeneration() => myGeneration == _currentGeneration;

    _isLoading = true;
    _isBackgroundLoading = true;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();

    final stopwatch = Stopwatch()..start();

    final googlePlaces = await _fetchAndStore(
      lat:        searchLat,
      lng:        searchLng,
      targetList: _allPlacesCache,
      targetByType: _placesByTypeCache,
      radius:     radius,
      generation: myGeneration,
      isCurrentGeneration: isCurrentGeneration,
      onGeoapifyBatchAdd: (batch) {
        // fan out to both the new batched callback and the legacy
        // per-place callback, if callers still use it.
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

    // 🔒 Only commit "loaded" bookkeeping if we're still the latest call.
    if (isCurrentGeneration()) {
      _hasLoadedOnce = true;
      _cachedRadius  = radius; // ← record which radius this cache was loaded with
      _isLoading = false;
    }

    print('🏁 Phase 1 returned: ${googlePlaces.length} Google places in '
        '${stopwatch.elapsedMilliseconds}ms (radius: ${radius}m)');

    if (isCurrentGeneration()) {
      _precacheImages(context);
    }

    // NOTE: this list is the SAME reference as _allPlacesCache, so it will
    // keep growing as Phase 2 (Geoapify) adds more places in the background
    // — as long as this call is still the current generation.
    return _allPlacesCache;
  }

  // ── Public: load at specific location (landmark / search mode) ─────────────
  // Uses a fresh local `results`/`byType` list per call (keyed by cacheKey),
  // so it does NOT share the generation-guarded singleton cache and doesn't
  // need the same protection — concurrent calls with different cacheKeys
  // simply write into different lists.
  Future<List<PlaceModel>> loadNearbyPlacesAt({
    required double lat,
    required double lng,
    required List<Map<String, dynamic>> categories,
    required BuildContext context,
    int radius = 5000,
    Function(PlaceModel)? onGeoapifyAdd,
    Function(List<PlaceModel>)? onGeoapifyBatchAdd, // ← NEW: preferred, batched
    Function()? onGeoapifyDone,
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
      // Cached under the SAME reference — Phase 2 keeps appending to `results`
      // in the background, so cache hits later will include the merged data.
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
    // 🔒 bump generation so any in-flight background phase from before the
    // clear is treated as stale and won't repopulate the cache we just wiped.
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

  //itinerary生成时，清除所有缓存，避免重复请求
  static const Map<String, List<String>> _itineraryCategoryTypes = {
  'restaurant': [
    'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
    'fast_food_restaurant', 'food_court', 'dessert_shop',
  ],
  'tourist_attraction': [
    'tourist_attraction', 'historical_landmark', 'monument',
    'museum', 'art_gallery',
  ],
  'shopping_mall': [
    'shopping_mall', 'supermarket', 'grocery_store',
    'department_store', 'clothing_store',
  ],
  'amusement_park': [
    'amusement_park', 'movie_theater', 'bowling_alley',
    'karaoke', 'video_arcade', 'amusement_center',
  ],
  'park': [
    'park', 'national_park', 'botanical_garden',
    'garden', 'hiking_area', 'beach',
  ],
};

Future<List<PlaceModel>> fetchForItinerary({
  required double lat,
  required double lng,
  required List<String> categories,
  int radius = 10000,
}) async {

  // 🔍 DEBUG
  print('🎯 [fetchForItinerary] entered with radius=${radius}m (lat=$lat, lng=$lng)');

  final key = _locKey(lat, lng);
  final cacheSubKey = '$key|${categories.join(",")}';   // 🔧 cache key 也要区分类别组合，否则查 park 的 cache 会被误用给查 restaurant+park 的请求
  final cachedRadius = _itineraryRawCacheRadius[key];

  if (_itineraryRawCache.containsKey(key) &&
      cachedRadius != null &&
      cachedRadius >= radius) {
    print('🆓 Itinerary raw cache HIT for $key '
        '(cached at ${cachedRadius}m, need ${radius}m) — no API call');
    return _itineraryRawCache[key]!
        .where((p) =>
            p.lat != null &&
            p.lng != null &&
            _haversineMetres(lat, lng, p.lat!, p.lng!) <= radius)
        .toList();
  }

  final relevantEntries = _itineraryCategoryTypes.entries
      .where((e) => categories.contains(e.key))   // 🆕 只保留用户选中的
      .toList();

  print('🗺️ Itinerary raw cache MISS for $key — firing 5 independent '
      'Google searchNearby calls (radius: ${radius}m)...');

  final entries = await Future.wait(
    relevantEntries.map((entry) async {
      final primary = entry.key;
      final types   = entry.value;
      try {
        final raw = await PlacesApiService.searchNearby(
          lat: lat, lng: lng,
          types: types,
          maxResultCount: 20,
          radius: radius,
        );
        final places = raw
            .map((p) {
              final place = PlaceModel.fromGoogle(p, primary: primary);
              return (place.lat != null && place.lng != null) ? place : null;
            })
            .whereType<PlaceModel>()
            .toList();
        print('  ✅ $primary: ${places.length} fetched (独立 20 名额)');
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

  _itineraryRawCache[key] = places;
  _itineraryRawCacheRadius[key] = radius;

  print('✅ Itinerary raw cache STORED for $key: ${places.length} places @ ${radius}m');
  return places;
}

// Explicit escape hatch，跟其他 cache 一样的用法
void clearItineraryRawCache([double? lat, double? lng]) {
  if (lat != null && lng != null) {
    final key = _locKey(lat, lng);
    _itineraryRawCache.remove(key);
    _itineraryRawCacheRadius.remove(key);
  } else {
    _itineraryRawCache.clear();
    _itineraryRawCacheRadius.clear();
  }
}



}