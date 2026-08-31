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
    // A 5.0 rating can be legitimate. Review volume is used by itinerary
    // popularity scoring instead of treating a high rating as suspicious.
    if (r != null && r < 3.5)  return false;
    return true;
  }

  double _score(
    PlaceModel p, {
    required double originLat,
    required double originLng,
    required String travelMode,
    List<String> requestedCategories = const [],
    List<String> requestedCuisines = const [],
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

    final recommendation = prefs.recommendationScore(
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
    );

    final canonicalCategory = CategoryMapper.resolvePrimaryType(
      p.primaryType,
      p.allTypes,
    );
    final normalizedCategories = requestedCategories
        .map(_normalizeItineraryCategory)
        .toSet();

    // Explicit choices made on Generate Itinerary must outweigh preferences
    // previously saved in the profile.  The old implementation only read the
    // saved preference service, so temporary choices made on this page could
    // be ignored during ranking.
    double explicitPreference;
    if (normalizedCategories.isEmpty) {
      explicitPreference = recommendation.interestMatch;
    } else if (normalizedCategories.contains(canonicalCategory)) {
      explicitPreference = 1.0;
    } else if (canonicalCategory == 'restaurant') {
      // Restaurants can still be reserved as meal stops even when Food was
      // not selected, but they must not outrank the requested attractions.
      explicitPreference = 0.55;
    } else {
      explicitPreference = 0.0;
    }

    if (canonicalCategory == 'restaurant' && requestedCuisines.isNotEmpty) {
      final cuisineMatch = _matchesCuisine(p, requestedCuisines);
      explicitPreference = cuisineMatch
          ? math.max(explicitPreference, 1.0)
          : explicitPreference * 0.75;
    }

    final ratingScore = p.rating == null
        ? 0.5
        : ((p.rating! - 2.0) / 3.0).clamp(0.0, 1.0);
    final reviewVolumeScore = p.userRatingCount == null
        ? 0.5
        : (math.log(p.userRatingCount! + 1) / math.log(10001))
            .clamp(0.0, 1.0);
    final popularityScore =
        0.65 * ratingScore + 0.35 * reviewVolumeScore;

    // Itinerary ranking is deliberately preference/popularity first.
    // Distance remains a small feasibility term; daily assignment below is
    // responsible for geographical compactness.
    return (
      0.35 * explicitPreference +
      0.15 * recommendation.interestMatch +
      0.30 * popularityScore +
      0.10 * recommendation.budgetSuitability +
      0.10 * recommendation.distanceScore
    ).clamp(0.0, 1.0);
  }

  String _normalizeItineraryCategory(String category) {
    // Backward compatibility for itineraries/preferences saved before the UI
    // adopted CategoryMapper's canonical bucket name.
    return category == 'amusement_park' ? 'entertainment' : category;
  }

  bool _matchesCuisine(PlaceModel place, List<String> cuisines) {
    if (cuisines.isEmpty) return true;
    final name = place.name.toLowerCase();
    final types = place.allTypes.map((t) => t.toLowerCase()).toList();
    return cuisines.any((rawCuisine) {
      final cuisine = rawCuisine.toLowerCase().trim();
      if (cuisine.isEmpty) return false;
      return name.contains(cuisine) ||
          types.any((type) => type.contains(cuisine));
    });
  }

  String _normalizedPlaceName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_.(),&/]+'), '')
        .trim();
  }

  bool _isSemanticDuplicate(PlaceModel a, PlaceModel b) {
    final aName = _normalizedPlaceName(a.name);
    final bName = _normalizedPlaceName(b.name);
    if (aName.isEmpty || bName.isEmpty) return false;
    if (aName == bName) return true;
    if (a.lat == null || a.lng == null || b.lat == null || b.lng == null) {
      return false;
    }

    final sameCategory = CategoryMapper.resolvePrimaryType(
          a.primaryType,
          a.allTypes,
        ) ==
        CategoryMapper.resolvePrimaryType(
          b.primaryType,
          b.allTypes,
        );
    final relatedName = aName.length >= 5 &&
        bName.length >= 5 &&
        (aName.contains(bName) || bName.contains(aName));
    if (!sameCategory || !relatedName) return false;

    return _haversineMeters(a.lat!, a.lng!, b.lat!, b.lng!) <= 500;
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
    required bool includeRestaurants,
  }) async {

    print('🎯 [_fetchPlacesForItinerary] received radius=${radius}m');

    final normalizedCategories = categories
        .map(_normalizeItineraryCategory)
        .where(CategoryMapper.isLearnableCategory)
        .toSet()
        .toList();
    final includeRestaurant =
        normalizedCategories.contains('restaurant') || includeRestaurants;
    final types = normalizedCategories.isNotEmpty
        ? {
            ...normalizedCategories,
            if (includeRestaurant) 'restaurant',
          }.toList()
        : _defaultCategories;

    print('🗺️ Fetching itinerary candidates — dedicated 5-category fetch '
        '(${isCurrentLocation ? "current location" : "searched location"})');
    final stopwatch = Stopwatch()..start();

    print('🎯 [_fetchPlacesForItinerary] about to call fetchForItinerary with radius=${radius}m');

    final allPlaces = await NearbyPlacesService.instance.fetchForItinerary(
      lat: lat,
      lng: lng,
      categories: types,
      radius: radius,
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
    required List<String> cuisines,
    required bool isCurrentLocation,
    required int radius,
    required String travelMode,
  }) async {
    print('🎯 [_buildBalancedPlaces] received radius=${radius}m');

    final normalizedCategories = categories
        .map(_normalizeItineraryCategory)
        .where(CategoryMapper.isLearnableCategory)
        .toSet()
        .toList();
    final onlyFoodRequested = normalizedCategories.length == 1 &&
        normalizedCategories.single == 'restaurant';
    final requestedTotal = totalDays * placesPerDay;
    final minRestaurantsPerDay =
        _requiredRestaurantsPerDay(placesPerDay);
    final targetAttractionsPerDay = onlyFoodRequested
        ? 0
        : placesPerDay - minRestaurantsPerDay;
    final totalAttractionsNeeded = totalDays * targetAttractionsPerDay;
    // Do not cap this at Google's single-request limit (20). The itinerary
    // fetcher can now deepen a category with additional type batches.
    final perCategory = totalAttractionsNeeded == 0
        ? 0
        : math.max(4, totalAttractionsNeeded);

    final totalRestaurantsNeeded = onlyFoodRequested
        ? requestedTotal
        : totalDays * minRestaurantsPerDay;
    final restaurantCount = totalRestaurantsNeeded == 0
        ? 0
        : math.max(4, totalRestaurantsNeeded);

    final byType = await _fetchPlacesForItinerary(
      lat: lat, lng: lng, categories: normalizedCategories,
      isCurrentLocation: isCurrentLocation,
      radius: radius,
      includeRestaurants: totalRestaurantsNeeded > 0,
    );

    // Stage 2 is conditional. First evaluate the filtered, deduplicated
    // results from the single broad request made for each category. Only a
    // category that contributes to a real itinerary shortfall is deepened
    // with subtype requests.
    int eligibleUniqueCount(Iterable<PlaceModel> source) {
      return source
          .where(_isSuitableForTravel)
          .map((place) => place.id)
          .toSet()
          .length;
    }

    final effectiveCategories = normalizedCategories.isEmpty
        ? List<String>.from(_defaultCategories)
        : normalizedCategories;
    final nonFoodCategories = effectiveCategories
        .where((category) => category != 'restaurant')
        .toList();
    final additionalNeeded = <String, int>{};

    if (totalRestaurantsNeeded > 0) {
      final availableRestaurants =
          eligibleUniqueCount(byType['restaurant'] ?? const <PlaceModel>[]);
      final shortage = totalRestaurantsNeeded - availableRestaurants;
      if (shortage > 0) additionalNeeded['restaurant'] = shortage;
    }

    final nonFoodIds = <String>{};
    for (final category in nonFoodCategories) {
      for (final place in byType[category] ?? const <PlaceModel>[]) {
        if (_isSuitableForTravel(place)) nonFoodIds.add(place.id);
      }
    }
    var remainingNonFoodShortage =
        math.max(0, totalAttractionsNeeded - nonFoodIds.length);

    if (remainingNonFoodShortage > 0 && nonFoodCategories.isNotEmpty) {
      final baseTarget = totalAttractionsNeeded ~/ nonFoodCategories.length;
      final extraSlots = totalAttractionsNeeded % nonFoodCategories.length;
      final indexedCategories = nonFoodCategories.asMap().entries.toList()
        ..sort((a, b) {
          final aCount = eligibleUniqueCount(
            byType[a.value] ?? const <PlaceModel>[],
          );
          final bCount = eligibleUniqueCount(
            byType[b.value] ?? const <PlaceModel>[],
          );
          return aCount.compareTo(bCount);
        });

      for (final entry in indexedCategories) {
        if (remainingNonFoodShortage == 0) break;
        final category = entry.value;
        final fairTarget = baseTarget + (entry.key < extraSlots ? 1 : 0);
        final available = eligibleUniqueCount(
          byType[category] ?? const <PlaceModel>[],
        );
        final categoryDeficit = math.max(0, fairTarget - available);
        if (categoryDeficit == 0) continue;
        final requestCount = math.min(
          remainingNonFoodShortage,
          categoryDeficit,
        );
        additionalNeeded[category] = requestCount;
        remainingNonFoodShortage -= requestCount;
      }

      // If duplicates across buckets caused a remaining global shortage,
      // deepen the currently smallest selected bucket only.
      if (remainingNonFoodShortage > 0) {
        final smallestCategory = indexedCategories.first.value;
        additionalNeeded[smallestCategory] =
            (additionalNeeded[smallestCategory] ?? 0) +
                remainingNonFoodShortage;
      }
    }

    if (additionalNeeded.isNotEmpty) {
      print('🔁 Candidate shortfall detected: $additionalNeeded');
      final existingIds = <String>{
        for (final list in byType.values)
          for (final place in list) place.id,
      };
      final additional = await NearbyPlacesService.instance
          .fetchAdditionalForItinerary(
        lat: lat,
        lng: lng,
        radius: radius,
        additionalNeededByCategory: additionalNeeded,
        existingPlaceIds: existingIds,
      );

      for (final place in additional) {
        if (!_isSuitableForTravel(place)) continue;
        final category = CategoryMapper.resolvePrimaryType(
          place.primaryType,
          place.allTypes,
        );
        final bucket = byType.putIfAbsent(category, () => <PlaceModel>[]);
        if (!bucket.any((existing) => existing.id == place.id)) {
          bucket.add(place);
        }
      }
    } else {
      print('✅ Initial popularity fetch is sufficient — no subtype API calls');
    }

    double score(PlaceModel p) => _score(
      p,
      originLat: lat,
      originLng: lng,
      travelMode: travelMode,
      requestedCategories: normalizedCategories,
      requestedCuisines: cuisines,
    );

    bool wants(String type) => normalizedCategories.isEmpty ||
        normalizedCategories.contains(type);

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
        cuisines: cuisines,
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
        categories:   categories,
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
  required List<String> categories,
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

  final candidateById = <String, PlaceModel>{};
  final semanticCandidates = <PlaceModel>[];
  for (final place in [...places, ...?leftoverPool]) {
    if (place.id.isEmpty || place.lat == null || place.lng == null) continue;
    if (candidateById.containsKey(place.id)) continue;
    if (semanticCandidates.any(
      (existing) => _isSemanticDuplicate(existing, place),
    )) {
      print('🧹 Semantic duplicate removed: ${place.name}');
      continue;
    }
    candidateById[place.id] = place;
    semanticCandidates.add(place);
  }
  final candidates = candidateById.values.toList();
  final restaurants = candidates.where(isRestaurant).toList();
  final others = candidates.where((p) => !isRestaurant(p)).toList();

  final normalizedCategories = categories
      .map(_normalizeItineraryCategory)
      .where(CategoryMapper.isLearnableCategory)
      .toSet()
      .toList();
  final onlyFoodRequested = normalizedCategories.length == 1 &&
      normalizedCategories.single == 'restaurant';

  // Food-only means every requested stop may be Food.  Otherwise the meal
  // rule reserves only the minimum number of restaurant slots.
  final minRestaurantsPerDay = onlyFoodRequested
      ? placesPerDay
      : _requiredRestaurantsPerDay(placesPerDay);
  final targetAttractionsPerDay = placesPerDay - minRestaurantsPerDay;

  final scoreCache = <String, double>{};
  double quality(PlaceModel place) => scoreCache.putIfAbsent(
        place.id,
        () => _score(
          place,
          originLat: userLat,
          originLng: userLng,
          travelMode: travelMode,
          requestedCategories: normalizedCategories,
          requestedCuisines: cuisines,
        ),
      );

  // Deterministic high-quality geographical seeds replace random K-means.
  // Capacity is enforced directly while filling each day, so no cluster can
  // grow beyond placesPerDay while another day is left short.
  final seedPool = others.isNotEmpty ? others : restaurants;
  final dayCenters = _seedDayCenters(
    seedPool,
    totalDays,
    userLat: userLat,
    userLng: userLng,
    quality: quality,
  );
  final usedIds = <String>{};
  final dayPlaces = List.generate(totalDays, (_) => <PlaceModel>[]);

  void addToDay(int day, PlaceModel place) {
    usedIds.add(place.id);
    dayPlaces[day].add(place);
    dayCenters[day] = _centroid(dayPlaces[day]);
  }

  // Fill attraction capacity in rounds so every day receives one place
  // before any day receives its next one.
  for (int round = 0; round < targetAttractionsPerDay; round++) {
    for (int day = 0; day < totalDays; day++) {
      final picked = _pickBestForDay(
        others,
        dayCenters[day],
        usedIds,
        quality: quality,
        travelMode: travelMode,
      );
      if (picked != null) addToDay(day, picked);
    }
  }

  // Restaurants are chosen around each day's already-selected attraction
  // area. Cuisine choices are a preference boost, not a brittle hard filter.
  for (int round = 0; round < minRestaurantsPerDay; round++) {
    for (int day = 0; day < totalDays; day++) {
      final picked = _pickBestForDay(
        restaurants,
        dayCenters[day],
        usedIds,
        quality: quality,
        travelMode: travelMode,
        cuisines: cuisines,
      );
      if (picked != null) addToDay(day, picked);
    }
  }

  // If one bucket is scarce, fill remaining capacity from any requested,
  // suitable candidate instead of returning an avoidably short itinerary.
  for (int round = 0; round < placesPerDay; round++) {
    for (int day = 0; day < totalDays; day++) {
      if (dayPlaces[day].length >= placesPerDay) continue;
      final picked = _pickBestForDay(
        candidates,
        dayCenters[day],
        usedIds,
        quality: quality,
        travelMode: travelMode,
        cuisines: cuisines,
      );
      if (picked != null) addToDay(day, picked);
    }
  }

  // Improve the complete multi-day solution after every capacity has been
  // filled. Same-type swaps preserve meal feasibility while reducing the
  // combined within-day travel spread.
  _improveCrossDayAssignments(dayPlaces);

  // ─────────────────────────────────────────────
  // Unused candidates
  // ─────────────────────────────────────────────

  final allCandidates = candidates;

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




double _dayCompactnessCost(List<PlaceModel> places) {
  if (places.length < 2) return 0;
  var total = 0.0;
  var pairs = 0;
  for (int i = 0; i < places.length - 1; i++) {
    final a = places[i];
    if (a.lat == null || a.lng == null) continue;
    for (int j = i + 1; j < places.length; j++) {
      final b = places[j];
      if (b.lat == null || b.lng == null) continue;
      total += _haversineMeters(a.lat!, a.lng!, b.lat!, b.lng!);
      pairs++;
    }
  }
  return pairs == 0 ? 0 : total / pairs;
}

void _improveCrossDayAssignments(List<List<PlaceModel>> days) {
  if (days.length < 2) return;

  bool isRestaurant(PlaceModel place) => CategoryMapper.isRestaurant(
        place.primaryType,
        place.allTypes,
      );

  // Bounded best-improvement local search. Each accepted swap strictly lowers
  // the global compactness cost while keeping every day's capacity unchanged.
  for (int pass = 0; pass < 60; pass++) {
    double bestSaving = 0;
    int? bestDayA;
    int? bestIndexA;
    int? bestDayB;
    int? bestIndexB;

    for (int dayA = 0; dayA < days.length - 1; dayA++) {
      for (int dayB = dayA + 1; dayB < days.length; dayB++) {
        final before =
            _dayCompactnessCost(days[dayA]) + _dayCompactnessCost(days[dayB]);

        for (int indexA = 0; indexA < days[dayA].length; indexA++) {
          for (int indexB = 0; indexB < days[dayB].length; indexB++) {
            // Preserve each day's Food count and meal feasibility.
            if (isRestaurant(days[dayA][indexA]) !=
                isRestaurant(days[dayB][indexB])) {
              continue;
            }

            final placeA = days[dayA][indexA];
            final placeB = days[dayB][indexB];
            days[dayA][indexA] = placeB;
            days[dayB][indexB] = placeA;
            final after = _dayCompactnessCost(days[dayA]) +
                _dayCompactnessCost(days[dayB]);
            days[dayA][indexA] = placeA;
            days[dayB][indexB] = placeB;

            final saving = before - after;
            if (saving > bestSaving + 1.0) {
              bestSaving = saving;
              bestDayA = dayA;
              bestIndexA = indexA;
              bestDayB = dayB;
              bestIndexB = indexB;
            }
          }
        }
      }
    }

    if (bestDayA == null || bestDayB == null) break;
    final indexA = bestIndexA!;
    final indexB = bestIndexB!;
    final placeA = days[bestDayA][indexA];
    days[bestDayA][indexA] = days[bestDayB][indexB];
    days[bestDayB][indexB] = placeA;
  }
}

List<({double lat, double lng})> _seedDayCenters(
  List<PlaceModel> pool,
  int dayCount, {
  required double userLat,
  required double userLng,
  required double Function(PlaceModel) quality,
}) {
  final located = pool
      .where((p) => p.lat != null && p.lng != null)
      .toList();
  if (located.isEmpty) {
    return List.generate(
      dayCount,
      (_) => (lat: userLat, lng: userLng),
    );
  }

  // The first day starts from the strongest candidate, with a small origin
  // proximity term. Later seeds favour both quality and separation, creating
  // distinct compact areas without random initialization or empty clusters.
  PlaceModel first = located.first;
  double firstValue = double.negativeInfinity;
  for (final candidate in located) {
    final originDistance = _haversineMeters(
      userLat,
      userLng,
      candidate.lat!,
      candidate.lng!,
    );
    final originProximity =
        (1.0 - originDistance / 20000.0).clamp(0.0, 1.0);
    final value = 0.85 * quality(candidate) + 0.15 * originProximity;
    if (value > firstValue) {
      first = candidate;
      firstValue = value;
    }
  }

  final seeds = <PlaceModel>[first];
  while (seeds.length < dayCount && seeds.length < located.length) {
    PlaceModel? best;
    double bestValue = double.negativeInfinity;
    for (final candidate in located) {
      if (seeds.any((seed) => seed.id == candidate.id)) continue;
      var nearestSeedDistance = double.infinity;
      for (final seed in seeds) {
        final distance = _haversineMeters(
          candidate.lat!,
          candidate.lng!,
          seed.lat!,
          seed.lng!,
        );
        if (distance < nearestSeedDistance) nearestSeedDistance = distance;
      }
      final separation =
          (nearestSeedDistance / 20000.0).clamp(0.0, 1.0);
      final value = 0.35 * quality(candidate) + 0.65 * separation;
      if (value > bestValue) {
        best = candidate;
        bestValue = value;
      }
    }
    if (best == null) break;
    seeds.add(best);
  }

  return List.generate(dayCount, (index) {
    if (index < seeds.length) {
      return (lat: seeds[index].lat!, lng: seeds[index].lng!);
    }
    return (lat: userLat, lng: userLng);
  });
}

PlaceModel? _pickBestForDay(
  List<PlaceModel> pool,
  ({double lat, double lng}) center,
  Set<String> used, {
  required double Function(PlaceModel) quality,
  required String travelMode,
  List<String> cuisines = const [],
}) {
  PlaceModel? best;
  double bestValue = double.negativeInfinity;
  final double distanceBaseline;
  switch (travelMode) {
    case 'walk':
      distanceBaseline = 2500.0;
      break;
    case 'drive':
    case 'both':
      distanceBaseline = 9000.0;
      break;
    case 'motor':
    default:
      distanceBaseline = 6000.0;
      break;
  }

  for (final candidate in pool) {
    if (used.contains(candidate.id) ||
        candidate.lat == null ||
        candidate.lng == null) {
      continue;
    }
    final distance = _haversineMeters(
      center.lat,
      center.lng,
      candidate.lat!,
      candidate.lng!,
    );
    final proximity = math.exp(-distance / distanceBaseline);
    final cuisineBoost = cuisines.isNotEmpty &&
            CategoryMapper.isRestaurant(
              candidate.primaryType,
              candidate.allTypes,
            ) &&
            _matchesCuisine(candidate, cuisines)
        ? 0.05
        : 0.0;
    final value = 0.25 * quality(candidate) +
        0.75 * proximity +
        cuisineBoost;

    final shouldReplace = value > bestValue ||
        (value == bestValue &&
            (candidate.rating ?? 0) > (best?.rating ?? 0));
    if (shouldReplace) {
      best = candidate;
      bestValue = value;
    }
  }
  return best;
}

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
        // Store the canonical type because ItineraryPlace intentionally does
        // not carry Google allTypes. Route optimization can then still
        // recognize cafes/bakeries/etc. as Food reliably.
        primaryType:     CategoryMapper.resolvePrimaryType(
          place.primaryType,
          place.allTypes,
        ),
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

