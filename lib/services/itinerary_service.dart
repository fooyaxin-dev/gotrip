// services/itinerary_service.dart
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/itineraryModel.dart';
import '../models/placeModel.dart';
import '../services/location_service.dart';
import '../services/userPreference_service.dart';
import '../services/nearbyPlace_service.dart'; 
import 'storage_service.dart';
import '../services/route_service.dart';
import 'category_mapper.dart';
import 'history_service.dart';
import 'userActivity_service.dart';


class ItineraryService {
  static final ItineraryService instance = ItineraryService._();
  ItineraryService._();

  final _db = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  final ValueNotifier<int> itinerariesChanged = ValueNotifier(0);

  CollectionReference? get _col => _uid == null
      ? null
      : _db.collection('users').doc(_uid).collection('itineraries');

  // ─────────────────────────────────────────────
  // Default categories (fallback when user selects none)
  //
  // 🔧 CHANGED: 'amusement_park' → 'entertainment'，跟 Nearby 页面 /
  // CategoryMapper 统一命名。行程生成不需要 Transit / Service，
  // 所以这里仍然只有 5 个，不是 Nearby 的 7 个。
  // ─────────────────────────────────────────────

  static const _defaultCategories = [
    'restaurant',
    'tourist_attraction',
    'shopping_mall',
    'entertainment',
    'park',
  ];

  // ─────────────────────────────────────────────
  // Blocked types
  // ─────────────────────────────────────────────

  static const _blockedTypes = {
    'lodging', 'hotel', 'motel', 'guest_house', 'hostel',
    'campground', 'rv_park', 'hospital', 'doctor', 'dentist',
    'pharmacy', 'bank', 'atm', 'finance', 'insurance_agency',
    'gas_station', 'car_repair', 'car_wash', 'car_dealer',
    'laundry', 'storage', 'funeral_home', 'cemetery',
    'police', 'courthouse', 'embassy', 'real_estate_agency',
    'electrician', 'plumber', 'roofing_contractor',
  };

  static const _blockedNameKeywords = [
    'sdn bhd', 'sdn. bhd', 'sdnbhd',
    'network', 'solution', 'solutions',
    'enterprise', 'enterprises',
    'management', 'services', 'trading',
    'holdings', 'group berhad', 'berhad',
    'consultant', 'consultancy',
    'insurance', 'agency', 'agencies',
    'clinic', 'hospital', 'pharmacy',
    'hardware', 'spare part',
  ];

  // 🔧 CHANGED: 'amusement_park' → 'entertainment'
  static const _defaultDurationByType = {
    'restaurant':         75,
    'tourist_attraction': 120,
    'shopping_mall':      90,
    'entertainment':      150,
    'park':               60,
  };

  // Keep candidate retrieval and final scheduling on the same meal policy.
  // A one-stop day should follow the user's attraction preferences instead
  // of always becoming a restaurant-only itinerary.
  int _requiredRestaurantsPerDay(int placesPerDay) {
    if (placesPerDay <= 1) return 0;
    if (placesPerDay <= 3) return 1;
    return 2;
  }

  bool _isBlocked(PlaceModel p) {
    if (p.allTypes.any((t) => _blockedTypes.contains(t))) return true;
    final nameLower = p.name.toLowerCase();
    if (_blockedNameKeywords.any((k) => nameLower.contains(k))) return true;
    return false;
  }

  bool _isSuitableForTravel(PlaceModel p) {
    if (_isBlocked(p)) return false;
    final r = p.rating;
    // A 5.0 rating can be legitimate. PlaceModel currently does not retain
    // userRatingCount for nearby candidates, so rejecting all ratings above
    // 4.95 would also remove genuine highly-rated places.
    if (r != null && r < 3.5)  return false;
    return true;
  }

  double _score(
    PlaceModel p, {
    required double originLat,
    required double originLng,
    required String travelMode,
  }) {
    final prefs = UserPreferenceService.instance;

    double? approximateDistance;

    if (p.lat != null && p.lng != null) {
      approximateDistance = _haversineMeters(
        originLat,
        originLng,
        p.lat!,
        p.lng!,
      );
    }

    return prefs.recommendationScore(
      primaryType: p.primaryType,
      allTypes: p.allTypes,
      rating: p.rating,
      distanceMeters: approximateDistance,
      priceLevel: p.priceLevel,
      // Itineraries may be generated for another location or a future date.
      // Current cached weather would therefore be misleading. A null value
      // gives every candidate the same neutral weather score (0.8), so weather
      // does not distort itinerary ranking.
      weather: null,
      travelMode: travelMode,
      useCurrentTime: false,
    ).total;
  }

  double _haversineMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthRadiusMeters = 6371000.0;

    final lat1Rad = lat1 * math.pi / 180.0;
    final lat2Rad = lat2 * math.pi / 180.0;
    final deltaLat = (lat2 - lat1) * math.pi / 180.0;
    final deltaLng = (lng2 - lng1) * math.pi / 180.0;

    final a =
        math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1Rad) *
            math.cos(lat2Rad) *
            math.sin(deltaLng / 2) *
            math.sin(deltaLng / 2);

    final c = 2 * math.atan2(
      math.sqrt(a),
      math.sqrt(1 - a),
    );

    return earthRadiusMeters * c;
  }


  // ─────────────────────────────────────────────
  // Radius from travel mode
  // ─────────────────────────────────────────────

  int _radiusFromTravelMode(String travelMode) =>
    radiusForTravelModeString(travelMode);

  // ─────────────────────────────────────────────
  // Firestore CRUD
  // ─────────────────────────────────────────────

  Future<List<ItineraryModel>> fetchAll() async {
    if (_col == null) return [];
    try {
      final snap = await _col!.orderBy('createdAt', descending: true).get();
      return snap.docs
          .map((d) => ItineraryModel.fromMap(d.id, d.data() as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('❌ fetchAll: $e');
      return [];
    }
  }

    Future<String?> save(
  ItineraryModel item,
) async {
  final uid = _uid;

  if (uid == null) {
    print(
      '❌ save: user not logged in',
    );
    return null;
  }

  // Bind this entire operation to the account
  // that started the save.
  final collection = _db
      .collection('users')
      .doc(uid)
      .collection('itineraries');

  try {
    // Session may already have changed before
    // the Firestore write starts.
    if (_uid != uid) {
      print(
        '🚫 save cancelled: account changed',
      );
      return null;
    }

    String savedId;

    if (item.id.isEmpty) {
      final ref = await collection.add(
        item.toMap(),
      );

      savedId = ref.id;
    } else {
      await collection
          .doc(item.id)
          .set(
        item.toMap(),
      );

      savedId = item.id;
    }

    // The write belonged to A.
    //
    // If the app has switched to B while the write
    // was running, do not invalidate B's cache or
    // continue treating the result as B's operation.
    if (_uid != uid) {
      print(
        '⚠️ save completed for old session $uid '
        'after account switch',
      );

      return null;
    }

    UserActivityDataService.instance
        .invalidate();

    return savedId;
  } catch (e) {
    print(
      '❌ save: $e',
    );

    return null;
  }
}

  Future<void> update(
  ItineraryModel item,
) async {
  final uid = _uid;

  if (uid == null ||
      item.id.isEmpty) {
    throw Exception(
      'Unable to update itinerary',
    );
  }

  // Bind the update to the user who started it.
  final collection = _db
      .collection('users')
      .doc(uid)
      .collection('itineraries');

  try {
    if (_uid != uid) {
      throw Exception(
        'Account changed during itinerary update',
      );
    }

    final itineraryDoc =
        collection.doc(item.id);

    await itineraryDoc.update(
      item.toMap(),
    );

    // Account could have changed while Firestore
    // was processing the request.
    if (_uid != uid) {
      throw Exception(
        'Account changed during itinerary update',
      );
    }

    UserActivityDataService.instance
        .invalidate();
  } catch (e) {
    print(
      '❌ update itinerary failed: $e',
    );

    if (e
        .toString()
        .contains('Account changed')) {
      throw Exception(
        'Your account changed. '
        'Please try saving the itinerary again.',
      );
    }

    rethrow;
  }
}

  /// Atomically marks an itinerary place as visited and creates its matching
  /// history entry. Firestore commits both writes together, so Dashboard and
  /// Achievement data cannot be left behind when the itinerary update succeeds.
  Future<void> commitCheckIn({
    required ItineraryModel itinerary,
    required ItineraryPlace visitedPlace,
  }) async {
    final uid = _uid;

    if (uid == null) {
      throw Exception('You need to be logged in to check in.');
    }
    if (itinerary.id.isEmpty) {
      throw Exception('This itinerary has not been saved yet.');
    }
    if (!visitedPlace.isVisited || visitedPlace.visitedAt == null) {
      throw Exception('Invalid check-in data.');
    }

    final userDoc = _db.collection('users').doc(uid);
    final itineraryDoc =
        userDoc.collection('itineraries').doc(itinerary.id);

    // A deterministic document id makes a retried check-in idempotent instead
    // of creating duplicate history cards.
    final safePlaceId = visitedPlace.placeId.replaceAll('/', '_');
    final historyDoc = userDoc
        .collection('history')
        .doc('${itinerary.id}_$safePlaceId');

    try {
      if (_uid != uid) {
        throw Exception('Account changed during check-in');
      }

      final historyData = HistoryService.instance.buildEntryData(
        placeName: visitedPlace.name,
        address: visitedPlace.address,
        photoUrl: visitedPlace.photoUrl,
        visitedAt: visitedPlace.visitedAt!,
        itineraryId: itinerary.id,
        itineraryTitle: itinerary.title,
        placeId: visitedPlace.placeId,
        primaryType: visitedPlace.primaryType,
        lat: visitedPlace.lat,
        lng: visitedPlace.lng,
      );

      final batch = _db.batch();
      batch.update(itineraryDoc, itinerary.toMap());
      batch.set(historyDoc, historyData);

      await batch.commit();

      // The batch is already safely committed to the initiating account. Only
      // touch shared in-memory state if that account is still active.
      if (_uid == uid) {
        UserActivityDataService.instance.invalidate();
      }
    } catch (e) {
      print('❌ atomic check-in failed: $e');

      if (e.toString().contains('Account changed')) {
        throw Exception(
          'Your account changed. Please try the check-in again.',
        );
      }

      rethrow;
    }
  }

  Future<bool> delete(String id) async {
    final uid = _uid;

    if (uid == null) {
      return false;
    }

    // Bind the whole delete operation to the user
    // who initiated it.
    final collection = _db
        .collection('users')
        .doc(uid)
        .collection('itineraries');

    final itineraryDoc = collection.doc(id);

    try {
      final doc = await itineraryDoc.get();

      // Account may have changed while Firestore was reading.
      if (_uid != uid) {
        print(
          '🚫 delete cancelled: account changed during operation',
        );
        return false;
      }

      if (!doc.exists) {
        return false;
      }

      final itinerary = ItineraryModel.fromMap(
        doc.id,
        doc.data() as Map<String, dynamic>,
      );

      // Started itineraries must remain as travel records.
      if (itinerary.isStarted) {
        print(
          '🚫 delete blocked: '
          '"${itinerary.title}" has been started, cannot delete',
        );
        return false;
      }

      // Final session check before destructive write.
      if (_uid != uid) {
        return false;
      }

      await itineraryDoc.delete();

      // Only invalidate the cache belonging to
      // the same active session.
      if (_uid == uid) {
        UserActivityDataService.instance.invalidate();
      }

      return true;
    } catch (e) {
      print('❌ delete: $e');
      return false;
    }
  }
  

  // ─────────────────────────────────────────────
  // Fetch places for itinerary generation
  //
  // 🔧 CHANGED: categoryTypeMap 不再手写一份，改成引用 CategoryMapper
  // 的常量——跟 NearbyPlacesService._itineraryCategoryTypes 是同一个
  // 定义来源，不会再出现两边分类范围不一致的情况。
  // 'amusement_park' → 'entertainment'。
  // ─────────────────────────────────────────────

  Future<Map<String, List<PlaceModel>>> _fetchPlacesForItinerary({
    required double lat,
    required double lng,
    required List<String> categories,
    required bool isCurrentLocation,
    required int radius,
  }) async {

    print('🎯 [_fetchPlacesForItinerary] received radius=${radius}m');

    final types = categories.isNotEmpty
        ? {...categories, 'restaurant'}.toList()
        : _defaultCategories;

    print('🗺️ Fetching itinerary candidates — dedicated 5-category fetch '
        '(${isCurrentLocation ? "current location" : "searched location"})');
    final stopwatch = Stopwatch()..start();

    print('🎯 [_fetchPlacesForItinerary] about to call fetchForItinerary with radius=${radius}m');

    final allPlaces = await NearbyPlacesService.instance.fetchForItinerary(
      lat: lat, lng: lng, categories: types, radius: radius,
    );

    stopwatch.stop();
    print('🗺️ Got ${allPlaces.length} candidate places in ${stopwatch.elapsedMilliseconds}ms');

    final categoryTypeMap = <String, List<String>>{
      'restaurant':         CategoryMapper.restaurantTypes,
      'tourist_attraction': CategoryMapper.attractionTypes,
      'shopping_mall':      CategoryMapper.shoppingTypes,
      'entertainment':      CategoryMapper.entertainmentTypesForItinerary,
      'park':               CategoryMapper.natureTypes,
    };

    final Map<String, List<PlaceModel>> byType = {};
    for (final type in types) {
      final matchTypes = categoryTypeMap[type] ?? [type];
      byType[type] = allPlaces
          .where((p) => p.allTypes.any((t) => matchTypes.contains(t)))
          .toList();
      print('  ✅ $type: ${byType[type]!.length} candidates');
    }

    return byType;
  }
    
  TravelMode _resolveOptimizerTravelModeFromGenMode(String genMode) {
    switch (genMode) {
      case 'walk':  return TravelMode.walk;
      case 'drive':
      case 'both':  return TravelMode.drive;
      default:      return TravelMode.walk;
    }
  }
  
  // ─────────────────────────────────────────────
  // Build balanced places with recommendation score
  // ─────────────────────────────────────────────

  Future<({List<PlaceModel> places, List<PlaceModel> leftovers})> _buildBalancedPlaces(
    int totalDays, {
    required int placesPerDay, 
    required double lat,
    required double lng,
    required List<String> categories,
    required bool isCurrentLocation,
    required int radius,
    required String travelMode,
  }) async {
    print('🎯 [_buildBalancedPlaces] received radius=${radius}m');

    final minRestaurantsPerDay =
        _requiredRestaurantsPerDay(placesPerDay);
    final targetAttractionsPerDay = placesPerDay - minRestaurantsPerDay;
    final totalAttractionsNeeded = totalDays * targetAttractionsPerDay;
    final perCategory = totalAttractionsNeeded.clamp(4, 20);

    final totalRestaurantsNeeded = totalDays * minRestaurantsPerDay;
    final restaurantCount = totalRestaurantsNeeded == 0
        ? 0
        : totalRestaurantsNeeded.clamp(4, 30);

    final byType = await _fetchPlacesForItinerary(
      lat: lat, lng: lng, categories: categories,
      isCurrentLocation: isCurrentLocation, radius: radius, 
    );

    double score(PlaceModel p) => _score(
      p,
      originLat: lat,
      originLng: lng,
      travelMode: travelMode,
    );

    bool wants(String type) => categories.isEmpty || categories.contains(type);

    final leftoverPool = <PlaceModel>[];

    List<PlaceModel> topByType(String type, int count, {bool forceInclude = false}) {
      if (!forceInclude && !wants(type)) return [];

      final list = (byType[type] ?? [])
          .where(_isSuitableForTravel)
          .toList()
        ..sort((a, b) => score(b).compareTo(score(a)));

      List<PlaceModel> selected;
      List<PlaceModel> rest;

      if (list.length < count) {
        final fallback = (byType[type] ?? [])
            .where((p) => !_isBlocked(p) && (p.rating == null || p.rating! >= 3.5))
            .toList()
          ..sort((a, b) => score(b).compareTo(score(a)));
        selected = fallback.take(count).toList();
        rest = fallback.skip(count).toList();
      } else {
        selected = list.take(count).toList();
        rest = list.skip(count).toList();
      }

      leftoverPool.addAll(rest);
      return selected;
    }

    final restaurants   = topByType('restaurant', restaurantCount, forceInclude: true);
    final attractions   = topByType('tourist_attraction', perCategory);
    final malls         = topByType('shopping_mall',      perCategory);
    final entertainment = topByType('entertainment',      perCategory);
    final parks         = topByType('park',               perCategory);

    print('📋 Per category:');
    print('  🍽️  Restaurants: ${restaurants.length}');
    print('  🏛️  Attractions: ${attractions.length}');
    print('  🛍️  Malls: ${malls.length}');
    print('  🎭  Entertainment: ${entertainment.length}');
    print('  🌿  Parks: ${parks.length}');

    final seen   = <String>{};
    final result = <PlaceModel>[];
    void addAll(List<PlaceModel> list) {
      for (final p in list) if (seen.add(p.id)) result.add(p);
    }
    addAll(restaurants);
    addAll(attractions);
    addAll(malls);
    addAll(entertainment);
    addAll(parks);

    print('📍 Total candidates: ${result.length}');

    final leftoverSeen = <String>{};
    final leftovers = <PlaceModel>[];
    for (final p in leftoverPool) {
      if (seen.contains(p.id)) continue;
      if (leftoverSeen.add(p.id)) leftovers.add(p);
    }
    print('🔄 Leftover candidates (for swap): ${leftovers.length}');

    return (places: result, leftovers: leftovers);
  }
  
  // ─────────────────────────────────────────────
  // Generate — no Gemini, pure algorithm
  // ─────────────────────────────────────────────

  Future<ItineraryGenerationResult> generate({
    required String startDate,
    required int    totalDays,
    required int    placesPerDay,
    required String tripTitle,
    List<String>?   overrideCategories,
    List<String>?   overrideCuisines,
    double?         overrideLat,
    double?         overrideLng,
    bool            isCurrentLocation = true, 
    String?         overrideTravelMode,
    int?            overrideRadius,
  }) async {

    final requestedTotal = totalDays * placesPerDay;

    try {
      final cuisines = overrideCuisines
          ?? UserPreferenceService.instance.current.cuisines;
      final categories = overrideCategories
          ?? UserPreferenceService.instance.current.categories;

      final travelMode = overrideTravelMode
        ?? UserPreferenceService.instance.current.travelMode;
      final radius = (overrideRadius ?? _radiusFromTravelMode(travelMode))
          .clamp(500, 20000)
          .toInt();

      print('🎯 [generate] overrideTravelMode=$overrideTravelMode → '
          'travelMode=$travelMode → overrideRadius=$overrideRadius '
          '→ radius=${radius}m');

      double? lat = overrideLat;
      double? lng = overrideLng;

      if (lat == null || lng == null) {
        final pos = LocationService.instance.currentPosition;
        if (pos == null) {
          print('❌ generate: no location available');
          return ItineraryGenerationResult(
            itinerary: null,
            requestedTotal: requestedTotal,
            actualTotal: 0,
            leftoverCandidates: [],
          );
        }
        lat = pos.latitude;
        lng = pos.longitude;
      }

      final buildResult = await _buildBalancedPlaces(
        totalDays,
        placesPerDay: placesPerDay,
        lat: lat,
        lng: lng,
        categories: categories,
        isCurrentLocation: isCurrentLocation,
        radius: radius,
        travelMode: travelMode,
      );
      final validPlaces = buildResult.places;
      final leftoverCandidates = buildResult.leftovers;

      if (validPlaces.isEmpty) {
        print('❌ No valid places found');
        return ItineraryGenerationResult(
          itinerary: null,
          requestedTotal: requestedTotal,
          actualTotal: 0,
          leftoverCandidates: leftoverCandidates,
        );
      }

      final startDt  = DateTime.parse(startDate);
      final dayDates = List.generate(totalDays, (i) {
        final d = startDt.add(Duration(days: i));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      });

      final scheduleResult = _scheduleItinerary(
        places:       validPlaces,
        totalDays:    totalDays,
        placesPerDay: placesPerDay,
        startDates:   dayDates,
        cuisines:     cuisines,
        userLat:      lat,
        userLng:      lng,
        travelMode:   travelMode,
        leftoverPool: leftoverCandidates,
      );
      final days = scheduleResult.days;

      if (days == null || days.isEmpty) {
        print('❌ Scheduling failed');
        return ItineraryGenerationResult(
          itinerary: null,
          requestedTotal: requestedTotal,
          actualTotal: 0,
          leftoverCandidates: leftoverCandidates,
        );
      }

      final leftoverIds = <String>{for (final p in leftoverCandidates) p.id};
      final finalLeftovers = [...leftoverCandidates];
      for (final p in scheduleResult.unused) {
        if (leftoverIds.add(p.id)) finalLeftovers.add(p);
      }

      final actualTotal = days.fold<int>(0, (sum, d) => sum + d.places.length);

      print('✅ Scheduled ${days.length} days');
      for (int i = 0; i < days.length; i++) {
        print('  Day ${i + 1}: ${days[i].places.length} places'
            ' — ${days[i].places.map((p) => p.name).join(', ')}');
      }
      print('📊 Final: $actualTotal/$requestedTotal places scheduled');
      print('🔄 Final leftover pool: ${finalLeftovers.length}');

      final permanentDays = await resolvePermanentPhotosForDays(days);

      final itinerary = ItineraryModel(
        id:        '',
        title:     tripTitle,
        startDate: startDate,
        totalDays: totalDays,
        days:      permanentDays,
        createdAt: DateTime.now(),
        isOriginCurrentLocation: isCurrentLocation,
        originLat:  lat,
        originLng:  lng,
        originName: null,
        travelMode: travelMode,
        leftoverPlaceIds: finalLeftovers.map((p) => p.id).toList(),

      );

      return ItineraryGenerationResult(
        itinerary: itinerary,
        requestedTotal: requestedTotal,
        actualTotal: actualTotal,
        leftoverCandidates: finalLeftovers,
      );
    } catch (e) {
      print('❌ generate: $e');
      return ItineraryGenerationResult(
        itinerary: null,
        requestedTotal: requestedTotal,
        actualTotal: 0,
        leftoverCandidates: [],
      );
    }
  }
  
  Future<List<ItineraryDay>> resolvePermanentPhotosForDays(
    List<ItineraryDay> days,
  ) async {
    final Map<String, String> toResolve = {};
    for (final day in days) {
      for (final place in day.places) {
        if (place.photoUrl != null && place.photoUrl!.isNotEmpty) {
          toResolve[place.placeId] = place.photoUrl!;
        }
      }
    }
    if (toResolve.isEmpty) return days;

    print('📸 Resolving ${toResolve.length} permanent place photos for itinerary...');

    final ids = toResolve.keys.toList();
    final resolved = await Future.wait(
      ids.map((id) => StorageService.resolvePermanentPlacePhoto(
        placeId:   id,
        sourceUrl: toResolve[id]!,
      )),
    );

    final resolvedMap = <String, String>{
      for (int i = 0; i < ids.length; i++) ids[i]: resolved[i],
    };

    return days.map((day) => day.copyWith(
      places: day.places.map((place) {
        final newUrl = resolvedMap[place.placeId];
        if (newUrl == null) return place;
        return place.copyWith(photoUrl: newUrl);
      }).toList(),
    )).toList();
  }


  // ─────────────────────────────────────────────
  // Scheduler
  // ─────────────────────────────────────────────

 ({
  List<ItineraryDay>? days,
  List<PlaceModel> unused,
}) _scheduleItinerary({
  required List<PlaceModel> places,
  required int totalDays,
  required int placesPerDay,
  required List<String> startDates,
  required List<String> cuisines,
  required double userLat,
  required double userLng,
  required String travelMode,
  List<PlaceModel>? leftoverPool,
}) {
  // ─────────────────────────────────────────────
  // Unified category classification
  //
  // Do NOT rely on:
  //   p.primaryType == 'restaurant'
  //
  // CategoryMapper now decides whether a place is
  // Food based on both primaryType and allTypes.
  // This keeps cafes, bakeries, coffee shops,
  // cuisine-specific restaurants, etc. consistent
  // across the entire app.
  // ─────────────────────────────────────────────

  bool isRestaurant(PlaceModel place) {
    return CategoryMapper.isRestaurant(
      place.primaryType,
      place.allTypes,
    );
  }

  final restaurants =
      places.where(isRestaurant).toList();

  final others =
      places.where((p) => !isRestaurant(p)).toList();

  // 1 place/day  → no forced food stop
  // 2–3/day      → 1 food stop
  // 4+ places/day → 2 food stops
  final minRestaurantsPerDay =
      _requiredRestaurantsPerDay(placesPerDay);

  final targetAttractionsPerDay =
      placesPerDay - minRestaurantsPerDay;

  // ─────────────────────────────────────────────
  // Geographic clustering uses non-food places
  // ─────────────────────────────────────────────

  final clusters = _geoClusters(
    others,
    totalDays,
    userLat: userLat,
    userLng: userLng,
  );

  final dayCenters = List.generate(
    totalDays,
    (i) {
      final seed =
          clusters[i].isNotEmpty
              ? clusters[i]
              : others;

      return _centroid(seed);
    },
  );

  final usedIds = <String>{};

  final List<List<PlaceModel>> dayPlaces =
      List.generate(
    totalDays,
    (_) => <PlaceModel>[],
  );

  // ─────────────────────────────────────────────
  // Balanced daily assignment
  // ─────────────────────────────────────────────

  for (int round = 0;
      round < placesPerDay;
      round++) {
    for (int day = 0;
        day < totalDays;
        day++) {
      if (dayPlaces[day].length >=
          placesPerDay) {
        continue;
      }

      final currentRestaurantCount =
          dayPlaces[day]
              .where(isRestaurant)
              .length;

      final currentOthersCount =
          dayPlaces[day].length -
              currentRestaurantCount;

      final needsRestaurant =
          currentRestaurantCount <
              minRestaurantsPerDay;

      final needsAttraction =
          currentOthersCount <
              targetAttractionsPerDay;

      PlaceModel? picked;

      // Food gets priority while the day's required
      // food slots have not yet been satisfied.
      if (needsRestaurant) {
        picked = _pickClosestUnused(
          restaurants,
          dayCenters[day],
          usedIds,
          cuisines,
        );
      }

      // Then fill the non-food requirement.
      if (needsAttraction) {
        picked ??=
            _pickClosestUnused(
              clusters[day],
              dayCenters[day],
              usedIds,
              null,
            ) ??
            _pickClosestUnused(
              others,
              dayCenters[day],
              usedIds,
              null,
            );
      }

      // Final fallback:
      // use any remaining suitable place so the
      // itinerary does not become unnecessarily short.
      picked ??=
          _pickClosestUnused(
            restaurants,
            dayCenters[day],
            usedIds,
            cuisines,
          ) ??
          _pickClosestUnused(
            clusters[day],
            dayCenters[day],
            usedIds,
            null,
          ) ??
          _pickClosestUnused(
            others,
            dayCenters[day],
            usedIds,
            null,
          );

      if (picked != null) {
        usedIds.add(
          picked.id,
        );

        dayPlaces[day].add(
          picked,
        );
      }
    }
  }

  // ─────────────────────────────────────────────
  // Quality improvement using leftover candidates
  // ─────────────────────────────────────────────

  if (leftoverPool != null &&
      leftoverPool.isNotEmpty) {
    for (int day = 0;
        day < totalDays;
        day++) {
      final dayList =
          dayPlaces[day];

      for (int i = 0;
          i < dayList.length;
          i++) {
        final current =
            dayList[i];

        // Do not replace meal stops during the
        // quality-swap phase.
        if (isRestaurant(current)) {
          continue;
        }

        final currentScore = _score(
          current,
          originLat: userLat,
          originLng: userLng,
          travelMode: travelMode,
        );

        final currentDist =
            (current.lat != null &&
                    current.lng != null)
                ? _distSq(
                    current.lat!,
                    current.lng!,
                    dayCenters[day].lat,
                    dayCenters[day].lng,
                  )
                : double.infinity;

        PlaceModel? better;
        double bestScore =
            currentScore;

        for (final candidate
            in leftoverPool) {
          if (usedIds.contains(
            candidate.id,
          )) {
            continue;
          }

          if (candidate.lat == null ||
              candidate.lng == null) {
            continue;
          }

          final candScore = _score(
            candidate,
            originLat: userLat,
            originLng: userLng,
            travelMode: travelMode,
          );

          if (candScore <=
              bestScore + 0.05) {
            continue;
          }

          final candDist =
              _distSq(
            candidate.lat!,
            candidate.lng!,
            dayCenters[day].lat,
            dayCenters[day].lng,
          );

          if (candDist >
              currentDist * 2.5) {
            continue;
          }

          bestScore =
              candScore;

          better =
              candidate;
        }

        if (better != null) {
          usedIds.remove(
            current.id,
          );

          usedIds.add(
            better.id,
          );

          dayList[i] =
              better;

          print(
            '🔄 Quality swap Day ${day + 1}: '
            '${current.name}'
            '(${currentScore.toStringAsFixed(2)}) '
            '→ ${better.name}'
            '(${bestScore.toStringAsFixed(2)})',
          );
        }
      }
    }
  }

  // ─────────────────────────────────────────────
  // Unused candidates
  // ─────────────────────────────────────────────

  final allCandidates = [
    ...restaurants,
    ...others,
  ];

  final unused =
      allCandidates
          .where(
            (p) =>
                !usedIds.contains(p.id),
          )
          .toList();

  // ─────────────────────────────────────────────
  // Convert daily selections into time slots
  // ─────────────────────────────────────────────

  final days =
      <ItineraryDay>[];

  for (int i = 0;
      i < totalDays;
      i++) {
    final dayRestaurants =
        dayPlaces[i]
            .where(isRestaurant)
            .toList();

    final dayAttractions =
        dayPlaces[i]
            .where(
              (p) =>
                  !isRestaurant(p),
            )
            .toList();

    final scheduled =
        _assignTimeSlots(
      dayAttractions,
      dayRestaurants,
      placesPerDay,
    );

    days.add(
      ItineraryDay(
        dayNumber: i + 1,
        date: startDates[i],
        places: scheduled,
      ),
    );
  }

  return (
    days: days,
    unused: unused,
  );
}




PlaceModel? _pickClosestUnused(
  List<PlaceModel> pool,
  ({double lat, double lng}) center,
  Set<String> used,
  List<String>? cuisines,
) {
  final available = pool
      .where((p) => !used.contains(p.id) && p.lat != null && p.lng != null)
      .toList();

  if (available.isEmpty) return null;

  if (cuisines != null && cuisines.isNotEmpty) {
    available.sort((a, b) {
      final aMatch = cuisines.any((c) =>
          a.name.toLowerCase().contains(c) || a.allTypes.any((t) => t.contains(c)));
      final bMatch = cuisines.any((c) =>
          b.name.toLowerCase().contains(c) || b.allTypes.any((t) => t.contains(c)));
      if (aMatch != bMatch) return aMatch ? -1 : 1;
      return _distSq(a.lat!, a.lng!, center.lat, center.lng)
          .compareTo(_distSq(b.lat!, b.lng!, center.lat, center.lng));
    });
  } else {
    available.sort((a, b) =>
        _distSq(a.lat!, a.lng!, center.lat, center.lng)
            .compareTo(_distSq(b.lat!, b.lng!, center.lat, center.lng)));
  }

  return available.first;
}
  
  // ─────────────────────────────────────────────
  // Geo clustering
  // ─────────────────────────────────────────────

  List<List<PlaceModel>> _geoClusters(
    List<PlaceModel> places,
    int k, {
    required double userLat,
    required double userLng,
  }) {
    if (places.isEmpty) return List.generate(k, (_) => []);

    final located = places.where((p) => p.lat != null && p.lng != null).toList();
    if (located.isEmpty) return List.generate(k, (_) => []);

    final seedCount = k.clamp(1, located.length);
    final rand = math.Random();

    PlaceModel firstSeed = located.first;
    double bestDist = double.infinity;
    for (final p in located) {
      final d = _distSq(p.lat!, p.lng!, userLat, userLng);
      if (d < bestDist) { bestDist = d; firstSeed = p; }
    }
    final seeds = <PlaceModel>[firstSeed];

    while (seeds.length < seedCount) {
      final weights = <double>[];
      double totalWeight = 0;

      for (final p in located) {
        if (seeds.contains(p)) {
          weights.add(0);
          continue;
        }
        double minDistToSeeds = double.infinity;
        for (final s in seeds) {
          final d = _distSq(p.lat!, p.lng!, s.lat!, s.lng!);
          if (d < minDistToSeeds) minDistToSeeds = d;
        }
        weights.add(minDistToSeeds);
        totalWeight += minDistToSeeds;
      }

      if (totalWeight <= 0) break;

      final threshold = rand.nextDouble() * totalWeight;
      double cumulative = 0;
      PlaceModel? picked;
      for (int i = 0; i < located.length; i++) {
        cumulative += weights[i];
        if (cumulative >= threshold) {
          picked = located[i];
          break;
        }
      }

      picked ??= located.firstWhere((p) => !seeds.contains(p));
      seeds.add(picked);
    }

    List<({double lat, double lng})> centers =
        seeds.map((s) => (lat: s.lat!, lng: s.lng!)).toList();

    List<List<PlaceModel>> assign(List<({double lat, double lng})> centers) {
      final clusters = List.generate(centers.length, (_) => <PlaceModel>[]);
      for (final p in located) {
        int    bestIdx  = 0;
        double bestDist = double.infinity;
        for (int i = 0; i < centers.length; i++) {
          final d = _distSq(p.lat!, p.lng!, centers[i].lat, centers[i].lng);
          if (d < bestDist) { bestDist = d; bestIdx = i; }
        }
        clusters[bestIdx].add(p);
      }
      return clusters;
    }

    var clusters = assign(centers);

    const maxPasses = 8;
    const convergenceThresholdMeters = 20.0;
    final thresholdSq =
        math.pow(convergenceThresholdMeters / 111000, 2).toDouble();

    for (int pass = 0; pass < maxPasses; pass++) {
      final newCenters = <({double lat, double lng})>[];
      for (int i = 0; i < clusters.length; i++) {
        if (clusters[i].isEmpty) {
          newCenters.add(centers[i]);
        } else {
          newCenters.add(_centroid(clusters[i]));
        }
      }

      double maxShift = 0;
      for (int i = 0; i < centers.length; i++) {
        final shift = _distSq(
            centers[i].lat, centers[i].lng, newCenters[i].lat, newCenters[i].lng);
        if (shift > maxShift) maxShift = shift;
      }

      centers  = newCenters;
      clusters = assign(centers);

      if (maxShift < thresholdSq) break;
    }

    final targetSize = (located.length / k).ceil();
    const maxBalancePasses = 20;
    for (int pass = 0; pass < maxBalancePasses; pass++) {
      int largestIdx = 0;
      for (int i = 1; i < clusters.length; i++) {
        if (clusters[i].length > clusters[largestIdx].length) largestIdx = i;
      }
      int smallestIdx = 0;
      for (int i = 1; i < clusters.length; i++) {
        if (clusters[i].length < clusters[smallestIdx].length) smallestIdx = i;
      }

      final sizeDiff = clusters[largestIdx].length - clusters[smallestIdx].length;
      if (sizeDiff <= 1 || clusters[largestIdx].length <= targetSize) break;

      PlaceModel? candidate;
      double bestDelta = double.infinity;
      for (final p in clusters[largestIdx]) {
        final distOwn   = _distSq(p.lat!, p.lng!, centers[largestIdx].lat, centers[largestIdx].lng);
        final distOther = _distSq(p.lat!, p.lng!, centers[smallestIdx].lat, centers[smallestIdx].lng);
        final delta = distOther - distOwn;
        if (delta < bestDelta) { bestDelta = delta; candidate = p; }
      }
      if (candidate == null) break;

      clusters[largestIdx].remove(candidate);
      clusters[smallestIdx].add(candidate);
    }

    while (clusters.length < k) {
      clusters.add(<PlaceModel>[]);
    }

    for (final c in clusters) {
      c.sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
    }

    return clusters;
  }

  // ─────────────────────────────────────────────
  // Assign time slots
  // ─────────────────────────────────────────────

  List<ItineraryPlace> _assignTimeSlots(
    List<PlaceModel> attractions,
    List<PlaceModel> restaurants,
    int              placesPerDay,
  ) {
    final slots = <({String time, int duration, bool isRestaurant})>[];

    if (placesPerDay == 2) {
      slots.add((time: '09:00', duration: 120, isRestaurant: false));
      slots.add((time: '12:30', duration: 75,  isRestaurant: true));
    } else if (placesPerDay == 3) {
      slots.add((time: '09:00', duration: 120, isRestaurant: false));
      slots.add((time: '12:00', duration: 75,  isRestaurant: true));
      slots.add((time: '14:30', duration: 120, isRestaurant: false));
    } else if (placesPerDay == 4) {
      slots.add((time: '08:00', duration: 150, isRestaurant: false));
      slots.add((time: '11:30', duration: 75,  isRestaurant: true));
      slots.add((time: '14:00', duration: 150, isRestaurant: false));
      slots.add((time: '18:00', duration: 90,  isRestaurant: true));
    } else if (placesPerDay == 5) {
      slots.add((time: '08:00', duration: 120, isRestaurant: false));
      slots.add((time: '11:00', duration: 75,  isRestaurant: true));
      slots.add((time: '13:30', duration: 120, isRestaurant: false));
      slots.add((time: '17:00', duration: 90,  isRestaurant: true));
      slots.add((time: '19:30', duration: 90,  isRestaurant: false));
    } else {
      slots.add((time: '08:00', duration: 90,  isRestaurant: false));
      slots.add((time: '10:30', duration: 90,  isRestaurant: false));
      slots.add((time: '12:30', duration: 75,  isRestaurant: true));
      slots.add((time: '14:30', duration: 90,  isRestaurant: false));
      slots.add((time: '17:30', duration: 90,  isRestaurant: true));
      slots.add((time: '20:00', duration: 90,  isRestaurant: false));
    }

    final result = <ItineraryPlace>[];
    int attIdx = 0;
    int resIdx = 0;
    int? cursorMinutes;

    for (final slot in slots) {
      PlaceModel? place;

      if (slot.isRestaurant && resIdx < restaurants.length) {
        place = restaurants[resIdx++];
      } else if (!slot.isRestaurant && attIdx < attractions.length) {
        place = attractions[attIdx++];
      } else if (!slot.isRestaurant && resIdx < restaurants.length) {
        place = restaurants[resIdx++];
      } else if (slot.isRestaurant && attIdx < attractions.length) {
        place = attractions[attIdx++];
      }

      if (place == null) continue;

      final duration = _defaultDurationByType[place.primaryType] ?? slot.duration;

      final startMinutes = cursorMinutes ?? _parseTimeToMinutesStatic(slot.time);
      final hh = (startMinutes ~/ 60) % 24;
      final mm = startMinutes % 60;
      final timeStr =
          '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';

      result.add(ItineraryPlace(
        placeId:         place.id,
        name:            place.name,
        address:         place.address ?? '',
        photoUrl:        place.photoUrl,
        lat:             place.lat,
        lng:             place.lng,
        primaryType:     place.primaryType,
        suggestedTime:   timeStr,
        durationMinutes: duration,
        notes:           _generateNote(place),
      ));

      cursorMinutes = startMinutes + duration;
    }

    return result;
  }

  int _parseTimeToMinutesStatic(String t) {
    try {
      final parts = t.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    } catch (_) {
      return 9 * 60;
    }
  }

  // ─────────────────────────────────────────────
  // Rule-based notes
  //
  // 🔧 CHANGED: 'amusement_park' → 'entertainment'
  // ─────────────────────────────────────────────

  String _generateNote(PlaceModel p) {
    final stars = p.rating != null
        ? '⭐ ${p.rating!.toStringAsFixed(1)} · '
        : '';

    return switch (p.primaryType ?? '') {
      'restaurant'         => '${stars}Popular dining spot. Check wait times during peak hours.',
      'tourist_attraction' => '${stars}A must-visit landmark. Arrive early to avoid crowds.',
      'shopping_mall'      => '${stars}Great for shopping and indoor activities.',
      'entertainment'      => '${stars}Fun for all ages. Book tickets in advance if possible.',
      'park'               => '${stars}Perfect for a relaxing outdoor break.',
      _                    => '${stars}Worth a visit during your trip.',
    };
  }

  // ─────────────────────────────────────────────
  // Geometry helpers
  // ─────────────────────────────────────────────

  double _distSq(double lat1, double lng1, double lat2, double lng2) {
    final dlat = lat1 - lat2;
    final dlng = lng1 - lng2;
    return dlat * dlat + dlng * dlng;
  }

  ({double lat, double lng}) _centroid(List<PlaceModel> places) {
    final valid = places
        .where((p) => p.lat != null && p.lng != null)
        .toList();
    if (valid.isEmpty) return (lat: 0.0, lng: 0.0);
    final lat = valid.map((p) => p.lat!).reduce((a, b) => a + b) / valid.length;
    final lng = valid.map((p) => p.lng!).reduce((a, b) => a + b) / valid.length;
    return (lat: lat, lng: lng);
  }
}

// ─────────────────────────────────────────────
// Generation result
// ─────────────────────────────────────────────

class ItineraryGenerationResult {
  final ItineraryModel? itinerary;
  final int requestedTotal;
  final int actualTotal;
  final bool isShortfall;
  final List<PlaceModel> leftoverCandidates;

  ItineraryGenerationResult({
    required this.itinerary,
    required this.requestedTotal,
    required this.actualTotal,
    required this.leftoverCandidates,
  }) : isShortfall = actualTotal < requestedTotal;
}
