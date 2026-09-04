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
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'storage_service.dart';
import '../services/route_service.dart';
import 'category_mapper.dart';
import 'history_service.dart';
import 'userActivity_service.dart';
import 'opening_hours_evaluator.dart';

enum _ItineraryFoodRole { fullMeal, lightFood, nonFood, excluded }

enum _OptwRole {
  attraction,
  lightFood,
  lunch,
  dinner,
}

class _OptwRoleWindow {
  final int startMinutes;
  final int endMinutes;
  final int defaultDuration;

  const _OptwRoleWindow({
    required this.startMinutes,
    required this.endMinutes,
    required this.defaultDuration,
  });
}

const _optwRoleWindows = <_OptwRole, _OptwRoleWindow>{
  _OptwRole.attraction: _OptwRoleWindow(
    startMinutes: 480,
    endMinutes: 1290,
    defaultDuration: 120,
  ),
  _OptwRole.lightFood: _OptwRoleWindow(
    startMinutes: 480,
    endMinutes: 1290,
    defaultDuration: 60,
  ),
  _OptwRole.lunch: _OptwRoleWindow(
    startMinutes: 690,
    endMinutes: 840,
    defaultDuration: 60,
  ),
  _OptwRole.dinner: _OptwRoleWindow(
    startMinutes: 1050,
    endMinutes: 1200,
    defaultDuration: 90,
  ),
};

class _OptwFeasiblePlan {
  final List<PlaceModel> places;
  final List<_OptwRole> roles;
  final List<int> visitStarts;
  final int totalRoadDurationSec;
  final double totalRoadDistMeters;
  final int totalWaitMinutes;
  final double totalQuality;
  final List<String> coveredPreferences;
  final int matchedPreferencesCount;
  final int categoryDiversityCount;
  final String idSequence;

  _OptwFeasiblePlan({
    required this.places,
    required this.roles,
    required this.visitStarts,
    required this.totalRoadDurationSec,
    required this.totalRoadDistMeters,
    required this.totalWaitMinutes,
    required this.totalQuality,
    required this.coveredPreferences,
    required this.matchedPreferencesCount,
    required this.categoryDiversityCount,
    required this.idSequence,
  });

  bool isBetterThan(_OptwFeasiblePlan? other) {
    if (other == null) return true;

    // 1. Stronger coverage of the user's requested categories and cuisines
    if (matchedPreferencesCount != other.matchedPreferencesCount) {
      return matchedPreferencesCount > other.matchedPreferencesCount;
    }

    // 2. Better category diversity and reasonable role distribution
    if (categoryDiversityCount != other.categoryDiversityCount) {
      return categoryDiversityCount > other.categoryDiversityCount;
    }

    // 3. Lower total actual-road travel duration
    if (totalRoadDurationSec != other.totalRoadDurationSec) {
      return totalRoadDurationSec < other.totalRoadDurationSec;
    }

    // 4. Lower total actual-road distance
    if (totalRoadDistMeters != other.totalRoadDistMeters) {
      return totalRoadDistMeters < other.totalRoadDistMeters;
    }

    // 5. Lower waiting time
    if (totalWaitMinutes != other.totalWaitMinutes) {
      return totalWaitMinutes < other.totalWaitMinutes;
    }

    // 6. Higher total recommendation/quality score
    if (totalQuality != other.totalQuality) {
      return totalQuality > other.totalQuality;
    }

    // 7. Lexical Place ID sequence as final tie-break
    return idSequence.compareTo(other.idSequence) < 0;
  }
}

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
    'lodging',
    'hotel',
    'motel',
    'guest_house',
    'hostel',
    'campground',
    'rv_park',
    'hospital',
    'doctor',
    'dentist',
    'pharmacy',
    'bank',
    'atm',
    'finance',
    'insurance_agency',
    'gas_station',
    'car_repair',
    'car_wash',
    'car_dealer',
    'laundry',
    'storage',
    'funeral_home',
    'cemetery',
    'police',
    'courthouse',
    'embassy',
    'real_estate_agency',
    'electrician',
    'plumber',
    'roofing_contractor',
  };

  static const _blockedNameKeywords = [
    'sdn bhd',
    'sdn. bhd',
    'sdnbhd',
    'network',
    'solution',
    'solutions',
    'enterprise',
    'enterprises',
    'management',
    'services',
    'trading',
    'holdings',
    'group berhad',
    'berhad',
    'consultant',
    'consultancy',
    'insurance',
    'agency',
    'agencies',
    'clinic',
    'hospital',
    'pharmacy',
    'hardware',
    'spare part',
  ];

  // 🔧 CHANGED: 'amusement_park' → 'entertainment'
  static const _defaultDurationByType = {
    'restaurant': 75,
    'tourist_attraction': 120,
    'shopping_mall': 90,
    'entertainment': 150,
    'park': 60,
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
    if (r != null && r < 3.5) return false;
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
    final normalizedCategories =
        requestedCategories.map(_normalizeItineraryCategory).toSet();

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

    final ratingScore =
        p.rating == null ? 0.5 : ((p.rating! - 2.0) / 3.0).clamp(0.0, 1.0);
    final reviewVolumeScore = p.userRatingCount == null
        ? 0.5
        : (math.log(p.userRatingCount! + 1) / math.log(10001)).clamp(0.0, 1.0);
    final popularityScore = 0.65 * ratingScore + 0.35 * reviewVolumeScore;

    // Itinerary ranking is deliberately preference/popularity first.
    // Distance remains a small feasibility term; daily assignment below is
    // responsible for geographical compactness.
    return (0.35 * explicitPreference +
            0.15 * recommendation.interestMatch +
            0.30 * popularityScore +
            0.10 * recommendation.budgetSuitability +
            0.10 * recommendation.distanceScore)
        .clamp(0.0, 1.0);
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
    return name.toLowerCase().replaceAll(RegExp(r'[\s\-_.(),&/]+'), '').trim();
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

    final a = math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1Rad) *
            math.cos(lat2Rad) *
            math.sin(deltaLng / 2) *
            math.sin(deltaLng / 2);

    final c = 2 *
        math.atan2(
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
          .map((d) =>
              ItineraryModel.fromMap(d.id, d.data() as Map<String, dynamic>))
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
    final collection =
        _db.collection('users').doc(uid).collection('itineraries');

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
        await collection.doc(item.id).set(
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

      UserActivityDataService.instance.invalidate();

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

    if (uid == null || item.id.isEmpty) {
      throw Exception(
        'Unable to update itinerary',
      );
    }

    // Bind the update to the user who started it.
    final collection =
        _db.collection('users').doc(uid).collection('itineraries');

    try {
      if (_uid != uid) {
        throw Exception(
          'Account changed during itinerary update',
        );
      }

      final itineraryDoc = collection.doc(item.id);

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

      UserActivityDataService.instance.invalidate();
    } catch (e) {
      print(
        '❌ update itinerary failed: $e',
      );

      if (e.toString().contains('Account changed')) {
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
    final itineraryDoc = userDoc.collection('itineraries').doc(itinerary.id);

    // A deterministic document id makes a retried check-in idempotent instead
    // of creating duplicate history cards.
    final safePlaceId = visitedPlace.placeId.replaceAll('/', '_');
    final historyDoc =
        userDoc.collection('history').doc('${itinerary.id}_$safePlaceId');

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
    final collection =
        _db.collection('users').doc(uid).collection('itineraries');

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

    print(
        '🎯 [_fetchPlacesForItinerary] about to call fetchForItinerary with radius=${radius}m');

    final allPlaces = await NearbyPlacesService.instance.fetchForItinerary(
      lat: lat,
      lng: lng,
      categories: types,
      radius: radius,
    );

    stopwatch.stop();
    print(
        '🗺️ Got ${allPlaces.length} candidate places in ${stopwatch.elapsedMilliseconds}ms');

    final categoryTypeMap = <String, List<String>>{
      'restaurant': CategoryMapper.restaurantTypes,
      'tourist_attraction': CategoryMapper.attractionTypes,
      'shopping_mall': CategoryMapper.shoppingTypes,
      'entertainment': CategoryMapper.entertainmentTypesForItinerary,
      'park': CategoryMapper.natureTypes,
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

  // ─────────────────────────────────────────────
  // Build balanced places with recommendation score
  // ─────────────────────────────────────────────

  Future<({List<PlaceModel> places, List<PlaceModel> leftovers})>
      _buildBalancedPlaces(
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
    final minRestaurantsPerDay = _requiredRestaurantsPerDay(placesPerDay);
    final targetAttractionsPerDay =
        onlyFoodRequested ? 0 : placesPerDay - minRestaurantsPerDay;
    final totalAttractionsNeeded = totalDays * targetAttractionsPerDay;
    // Do not cap this at Google's single-request limit (20). The itinerary
    // fetcher can now deepen a category with additional type batches.
    final perCategory =
        totalAttractionsNeeded == 0 ? 0 : math.max(4, totalAttractionsNeeded);

    final totalRestaurantsNeeded =
        onlyFoodRequested ? requestedTotal : totalDays * minRestaurantsPerDay;
    final restaurantCount =
        totalRestaurantsNeeded == 0 ? 0 : math.max(4, totalRestaurantsNeeded);

    final byType = await _fetchPlacesForItinerary(
      lat: lat,
      lng: lng,
      categories: normalizedCategories,
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
      final additional =
          await NearbyPlacesService.instance.fetchAdditionalForItinerary(
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

    bool wants(String type) =>
        normalizedCategories.isEmpty || normalizedCategories.contains(type);

    final leftoverPool = <PlaceModel>[];

    List<PlaceModel> topByType(String type, int count,
        {bool forceInclude = false}) {
      if (!forceInclude && !wants(type)) return [];

      final list = (byType[type] ?? []).where(_isSuitableForTravel).toList()
        ..sort((a, b) => score(b).compareTo(score(a)));

      List<PlaceModel> selected;
      List<PlaceModel> rest;

      if (list.length < count) {
        final fallback = (byType[type] ?? [])
            .where(
                (p) => !_isBlocked(p) && (p.rating == null || p.rating! >= 3.5))
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

    final restaurants =
        topByType('restaurant', restaurantCount, forceInclude: true);
    final attractions = topByType('tourist_attraction', perCategory);
    final malls = topByType('shopping_mall', perCategory);
    final entertainment = topByType('entertainment', perCategory);
    final parks = topByType('park', perCategory);

    print('📋 Per category:');
    print('  🍽️  Restaurants: ${restaurants.length}');
    print('  🏛️  Attractions: ${attractions.length}');
    print('  🛍️  Malls: ${malls.length}');
    print('  🎭  Entertainment: ${entertainment.length}');
    print('  🌿  Parks: ${parks.length}');

    final seen = <String>{};
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

    for (final p in result) {
      final d = _haversineMeters(lat, lng, p.lat ?? lat, p.lng ?? lng);
      debugPrint(
          '[ITIN_TRACE][CANDIDATE] placeId=${p.id} name=${p.name} category=${p.primaryType} lat=${p.lat} lng=${p.lng} score=${score(p)} distFromOriginM=${d.toStringAsFixed(1)} candidatePool=selected survivedPreselection=true');
    }
    for (final p in leftovers.take(5)) {
      final d = _haversineMeters(lat, lng, p.lat ?? lat, p.lng ?? lng);
      debugPrint(
          '[ITIN_TRACE][CANDIDATE] placeId=${p.id} name=${p.name} category=${p.primaryType} lat=${p.lat} lng=${p.lng} score=${score(p)} distFromOriginM=${d.toStringAsFixed(1)} candidatePool=leftover survivedPreselection=false');
    }
    debugPrint(
        '[ITIN_TRACE][CANDIDATE] SUMMARY totalRetrieved=${byType.values.fold(0, (s, l) => s + l.length)} selectedCount=${result.length} leftoverCount=${leftovers.length}');

    return (places: result, leftovers: leftovers);
  }

  // ─────────────────────────────────────────────
  // Generate — no Gemini, pure algorithm
  // ─────────────────────────────────────────────

  Future<ItineraryGenerationResult> generate({
    required String startDate,
    required int totalDays,
    required int placesPerDay,
    required String tripTitle,
    List<String>? overrideCategories,
    List<String>? overrideCuisines,
    double? overrideLat,
    double? overrideLng,
    bool isCurrentLocation = true,
    String? overrideTravelMode,
    int? overrideRadius,
  }) async {
    final requestedTotal = totalDays * placesPerDay;

    try {
      final cuisines =
          overrideCuisines ?? UserPreferenceService.instance.current.cuisines;
      final categories = overrideCategories ??
          UserPreferenceService.instance.current.categories;

      final travelMode = overrideTravelMode ??
          UserPreferenceService.instance.current.travelMode;
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

      debugPrint(
          '[ITIN_TRACE][GEN] overrideLat=$overrideLat overrideLng=$overrideLng resolvedOriginLat=$lat resolvedOriginLng=$lng isCurrentLocation=$isCurrentLocation overrideTravelMode=$overrideTravelMode resolvedTravelMode=$travelMode overrideRadius=$overrideRadius resolvedRadius=${radius}m requestedDays=$totalDays requestedPlacesPerDay=$placesPerDay requestedCategories=$categories requestedCuisines=$cuisines');

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

      final startDt = DateTime.parse(startDate);
      final dayDates = List.generate(totalDays, (i) {
        final d = startDt.add(Duration(days: i));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      });

      final scheduleResult = await _scheduleItinerary(
        places: validPlaces,
        totalDays: totalDays,
        placesPerDay: placesPerDay,
        startDates: dayDates,
        categories: categories,
        cuisines: cuisines,
        userLat: lat,
        userLng: lng,
        travelMode: travelMode,
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

      for (int i = 0; i < days.length; i++) {
        double pathDist = 0;
        double prevL = lat;
        double prevG = lng;
        final legsInfo = <String>[];
        for (int pIdx = 0; pIdx < days[i].places.length; pIdx++) {
          final p = days[i].places[pIdx];
          final legDist = (p.lat != null && p.lng != null)
              ? _haversineMeters(prevL, prevG, p.lat!, p.lng!)
              : 0.0;
          pathDist += legDist;
          final fromLabel = pIdx == 0 ? 'origin' : 'place$pIdx';
          legsInfo.add(
              '$fromLabel->place${pIdx + 1}(${p.name})=${legDist.toStringAsFixed(1)}m');
          if (p.lat != null && p.lng != null) {
            prevL = p.lat!;
            prevG = p.lng!;
          }
        }
        final orderedNames = days[i].places.map((p) => p.name).join(' -> ');
        debugPrint(
            '[ITIN_TRACE][FINAL_DAY] day=${i + 1} orderedPlaces=[$orderedNames] legs=[${legsInfo.join(', ')}] straightLineTotal=${pathDist.toStringAsFixed(1)}m travelMode=$travelMode configuredRadius=${radius}m');
      }

      final permanentDays = await resolvePermanentPhotosForDays(days);

      final itinerary = ItineraryModel(
        id: '',
        title: tripTitle,
        startDate: startDate,
        totalDays: totalDays,
        days: permanentDays,
        createdAt: DateTime.now(),
        isOriginCurrentLocation: isCurrentLocation,
        originLat: lat,
        originLng: lng,
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

    print(
        '📸 Resolving ${toResolve.length} permanent place photos for itinerary...');

    final ids = toResolve.keys.toList();
    final resolved = await Future.wait(
      ids.map((id) => StorageService.resolvePermanentPlacePhoto(
            placeId: id,
            sourceUrl: toResolve[id]!,
          )),
    );

    final resolvedMap = <String, String>{
      for (int i = 0; i < ids.length; i++) ids[i]: resolved[i],
    };

    return days
        .map((day) => day.copyWith(
              places: day.places.map((place) {
                final newUrl = resolvedMap[place.placeId];
                if (newUrl == null) return place;
                return place.copyWith(photoUrl: newUrl);
              }).toList(),
            ))
        .toList();
  }

  // ─────────────────────────────────────────────
  // Scheduler
  // ─────────────────────────────────────────────

  Future<
      ({
        List<ItineraryDay>? days,
        List<PlaceModel> unused,
      })> _scheduleItinerary({
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
  }) async {
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
    final fullMeals = <PlaceModel>[];
    final lightFoods = <PlaceModel>[];
    final attractions = <PlaceModel>[];

    for (final place in candidates) {
      final classification = _classifyFoodRole(place);
      switch (classification.role) {
        case _ItineraryFoodRole.fullMeal:
          fullMeals.add(place);
          break;
        case _ItineraryFoodRole.lightFood:
          lightFoods.add(place);
          debugPrint(
            '[ITIN_FOOD_ROLE] placeId=${place.id} '
            'name=${place.name} '
            'rawTypes=${place.allTypes} '
            'role=lightFood '
            'reason=${classification.reason}',
          );
          break;
        case _ItineraryFoodRole.nonFood:
          attractions.add(place);
          if (place.allTypes.any((t) => t == 'restaurant' || t == 'food')) {
            debugPrint(
              '[ITIN_FOOD_ROLE] placeId=${place.id} '
              'name=${place.name} '
              'rawTypes=${place.allTypes} '
              'role=nonFood '
              'reason=${classification.reason}',
            );
          }
          break;
        case _ItineraryFoodRole.excluded:
          debugPrint(
            '[ITIN_FOOD_ROLE] placeId=${place.id} '
            'name=${place.name} '
            'rawTypes=${place.allTypes} '
            'role=excluded '
            'reason=${classification.reason}',
          );
          break;
      }
    }

    final normalizedCategories = categories
        .map(_normalizeItineraryCategory)
        .where(CategoryMapper.isLearnableCategory)
        .toSet()
        .toList();
    final onlyFoodRequested = normalizedCategories.length == 1 &&
        normalizedCategories.single == 'restaurant';

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

    // ─────────────────────────────────────────────
    // Task 11G: Preference-Aware Orienteering Problem with Time Windows (OPTW)
    // ─────────────────────────────────────────────
    final optwResult = await _generateOptwItinerary(
      totalDays: totalDays,
      placesPerDay: placesPerDay,
      startDates: startDates,
      candidates: candidates,
      attractions: attractions,
      fullMeals: fullMeals,
      lightFoods: lightFoods,
      userLat: userLat,
      userLng: userLng,
      travelMode: travelMode,
      quality: quality,
      onlyFoodRequested: onlyFoodRequested,
      normalizedCategories: normalizedCategories,
      cuisines: cuisines,
    );

    if (optwResult != null) {
      debugPrint(
        '[ITIN_OPTW][HANDOFF] totalDays=$totalDays '
        'status=success '
        'preserveFlag=true',
      );
      return optwResult;
    }

    debugPrint(
      '[ITIN_OPTW][HANDOFF] totalDays=$totalDays '
      'status=failure '
      'action=return_null',
    );
    return (days: null, unused: candidates);
  }

  // ─────────────────────────────────────────────
  // Task 11G: OPTW Scheduling & Optimization Engine
  // ─────────────────────────────────────────────

  int _resolveVisitDuration(PlaceModel place, _OptwRole role) {
    switch (role) {
      case _OptwRole.lunch:
        return 60;
      case _OptwRole.dinner:
        return 90;
      case _OptwRole.lightFood:
        return 60;
      case _OptwRole.attraction:
        final canonicalType = CategoryMapper.resolvePrimaryType(
          place.primaryType,
          place.allTypes,
        );
        if (canonicalType != 'restaurant') {
          return _defaultDurationByType[canonicalType] ?? 120;
        }
        return 120;
    }
  }

  int? _findEarliestFeasibleVisitStart({
    required PlaceModel place,
    required _OptwRole role,
    required int minEarliestArrival,
    required int duration,
    required int googleWeekday,
  }) {
    final window = _optwRoleWindows[role]!;
    final tMin = math.max(minEarliestArrival, window.startMinutes);
    final tMax = window.endMinutes;

    if (tMin > tMax || tMin + duration > 1290) return null;

    final statusMin = OpeningHoursEvaluator.evaluateVisit(
      visitWeekday: googleWeekday,
      arrivalMinutes: tMin,
      durationMinutes: duration,
      periods: place.regularOpeningPeriods,
    );
    if (statusMin == OpeningStatus.open) {
      return tMin;
    }

    for (int t = tMin + 5; t <= tMax; t += 5) {
      if (t + duration > 1290) break;
      final st = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: googleWeekday,
        arrivalMinutes: t,
        durationMinutes: duration,
        periods: place.regularOpeningPeriods,
      );
      if (st == OpeningStatus.open) {
        return t;
      }
    }

    return null;
  }

  List<List<_OptwRole>> _buildRolePatterns(
    int placesPerDay,
    bool onlyFoodRequested,
  ) {
    if (onlyFoodRequested) {
      switch (placesPerDay) {
        case 1:
          return [
            [_OptwRole.lunch],
            [_OptwRole.lightFood],
            [_OptwRole.dinner],
          ];
        case 2:
          return [
            [_OptwRole.lightFood, _OptwRole.lunch],
            [_OptwRole.lunch, _OptwRole.lightFood],
            [_OptwRole.lightFood, _OptwRole.dinner],
            [_OptwRole.lunch, _OptwRole.dinner],
          ];
        case 3:
          return [
            [_OptwRole.lightFood, _OptwRole.lunch, _OptwRole.lightFood],
            [_OptwRole.lunch, _OptwRole.lightFood, _OptwRole.dinner],
            [_OptwRole.lightFood, _OptwRole.lunch, _OptwRole.dinner],
          ];
        case 4:
          return [
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.dinner
            ],
          ];
        case 5:
          return [
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.dinner,
              _OptwRole.lightFood
            ],
          ];
        case 6:
        default:
          return [
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.lightFood,
              _OptwRole.dinner,
              _OptwRole.lightFood
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.dinner,
              _OptwRole.lightFood
            ],
          ];
      }
    } else {
      switch (placesPerDay) {
        case 1:
          return [
            [_OptwRole.attraction],
            [_OptwRole.lightFood],
          ];
        case 2:
          return [
            [_OptwRole.attraction, _OptwRole.lunch],
            [_OptwRole.attraction, _OptwRole.dinner],
            [_OptwRole.lightFood, _OptwRole.lunch],
            [_OptwRole.lightFood, _OptwRole.dinner],
            [_OptwRole.lunch, _OptwRole.attraction],
          ];
        case 3:
          return [
            [_OptwRole.attraction, _OptwRole.lunch, _OptwRole.attraction],
            [_OptwRole.attraction, _OptwRole.lunch, _OptwRole.lightFood],
            [_OptwRole.lightFood, _OptwRole.lunch, _OptwRole.attraction],
            [_OptwRole.attraction, _OptwRole.dinner, _OptwRole.attraction],
            [_OptwRole.lightFood, _OptwRole.lunch, _OptwRole.lightFood],
          ];
        case 4:
          return [
            [
              _OptwRole.attraction,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.dinner
            ],
            [
              _OptwRole.attraction,
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
          ];
        case 5:
          return [
            [
              _OptwRole.attraction,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.attraction,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.attraction,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.attraction,
              _OptwRole.dinner
            ],
            [
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.dinner
            ],
          ];
        case 6:
        default:
          return [
            [
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.lightFood,
              _OptwRole.attraction,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.attraction,
              _OptwRole.attraction,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.dinner
            ],
            [
              _OptwRole.attraction,
              _OptwRole.lightFood,
              _OptwRole.lunch,
              _OptwRole.attraction,
              _OptwRole.attraction,
              _OptwRole.dinner
            ],
          ];
      }
    }
  }

  List<PlaceModel> _buildOptwShortlist({
    required List<PlaceModel> pool,
    required int quota,
    required List<_OptwRole> rolesToCover,
    required int googleWeekday,
    required double userLat,
    required double userLng,
    required double Function(PlaceModel) quality,
  }) {
    if (quota <= 0 || pool.isEmpty) return [];

    final feasiblePool = pool.where((p) {
      return rolesToCover.any((role) {
        final dur = _resolveVisitDuration(p, role);
        return _findEarliestFeasibleVisitStart(
              place: p,
              role: role,
              minEarliestArrival: 480,
              duration: dur,
              googleWeekday: googleWeekday,
            ) !=
            null;
      });
    }).toList();

    final targetCount = math.min(quota, feasiblePool.length);
    if (targetCount == 0) return [];

    // List A: Quality descending, origin distance ascending, Place ID ascending
    final listA = List<PlaceModel>.from(feasiblePool);
    listA.sort((a, b) {
      final qCmp = quality(b).compareTo(quality(a));
      if (qCmp != 0) return qCmp;
      final dA = _haversineMeters(userLat, userLng, a.lat!, a.lng!);
      final dB = _haversineMeters(userLat, userLng, b.lat!, b.lng!);
      final dCmp = dA.compareTo(dB);
      if (dCmp != 0) return dCmp;
      return a.id.compareTo(b.id);
    });

    // List B: Origin distance ascending, quality descending, Place ID ascending
    final listB = List<PlaceModel>.from(feasiblePool);
    listB.sort((a, b) {
      final dA = _haversineMeters(userLat, userLng, a.lat!, a.lng!);
      final dB = _haversineMeters(userLat, userLng, b.lat!, b.lng!);
      final dCmp = dA.compareTo(dB);
      if (dCmp != 0) return dCmp;
      final qCmp = quality(b).compareTo(quality(a));
      if (qCmp != 0) return qCmp;
      return a.id.compareTo(b.id);
    });

    final selected = <PlaceModel>[];
    final selectedIds = <String>{};

    // Step 1: Distance-first seed for each distinct role to cover
    for (final role in rolesToCover) {
      if (selected.length >= targetCount) break;
      for (final p in listB) {
        if (!selectedIds.contains(p.id)) {
          final dur = _resolveVisitDuration(p, role);
          if (_findEarliestFeasibleVisitStart(
                place: p,
                role: role,
                minEarliestArrival: 480,
                duration: dur,
                googleWeekday: googleWeekday,
              ) !=
              null) {
            selected.add(p);
            selectedIds.add(p.id);
            break;
          }
        }
      }
    }

    // Step 2: Balanced quality / distance alternation for remaining quota
    int indexA = 0;
    int indexB = 0;
    bool takeFromA = true;

    while (selected.length < targetCount &&
        (indexA < listA.length || indexB < listB.length)) {
      if (takeFromA) {
        while (
            indexA < listA.length && selectedIds.contains(listA[indexA].id)) {
          indexA++;
        }
        if (indexA < listA.length) {
          final p = listA[indexA++];
          selected.add(p);
          selectedIds.add(p.id);
        }
      } else {
        while (
            indexB < listB.length && selectedIds.contains(listB[indexB].id)) {
          indexB++;
        }
        if (indexB < listB.length) {
          final p = listB[indexB++];
          selected.add(p);
          selectedIds.add(p.id);
        }
      }
      takeFromA = !takeFromA;
    }

    for (final p in listA) {
      if (selected.length >= targetCount) break;
      if (selectedIds.add(p.id)) {
        selected.add(p);
      }
    }
    for (final p in listB) {
      if (selected.length >= targetCount) break;
      if (selectedIds.add(p.id)) {
        selected.add(p);
      }
    }

    return selected;
  }

  Future<({List<ItineraryDay> days, List<PlaceModel> unused})?>
      _generateOptwItinerary({
    required int totalDays,
    required int placesPerDay,
    required List<String> startDates,
    required List<PlaceModel> candidates,
    required List<PlaceModel> attractions,
    required List<PlaceModel> fullMeals,
    required List<PlaceModel> lightFoods,
    required double userLat,
    required double userLng,
    required String travelMode,
    required double Function(PlaceModel) quality,
    required bool onlyFoodRequested,
    required List<String> normalizedCategories,
    required List<String> cuisines,
  }) async {
    debugPrint(
      '[ITIN_OPTW][INPUT] totalDays=$totalDays '
      'placesPerDay=$placesPerDay '
      'travelMode=$travelMode '
      'onlyFoodRequested=$onlyFoodRequested '
      'candidates=${candidates.length}',
    );

    final dayWeekdays = List.generate(
      totalDays,
      (d) => d < startDates.length
          ? ((DateTime.tryParse(startDates[d])?.weekday ?? 1) % 7)
          : 1,
    );

    final travelModeEnum = travelModeFromString(travelMode);
    final tentativeUsedIds = <String>{};
    final tentativeDays = <ItineraryDay>[];

    for (int day = 0; day < totalDays; day++) {
      final dayResult = await _generateOptwSingleDay(
        dayIndex: day,
        googleWeekday: dayWeekdays[day],
        date: day < startDates.length ? startDates[day] : '',
        placesPerDay: placesPerDay,
        attractions: attractions,
        fullMeals: fullMeals,
        lightFoods: lightFoods,
        tentativeUsedIds: tentativeUsedIds,
        userLat: userLat,
        userLng: userLng,
        travelMode: travelMode,
        travelModeEnum: travelModeEnum,
        quality: quality,
        onlyFoodRequested: onlyFoodRequested,
        normalizedCategories: normalizedCategories,
        cuisines: cuisines,
      );

      if (dayResult == null) {
        return null;
      }

      tentativeDays.add(dayResult.day);
      tentativeUsedIds.addAll(dayResult.usedIds);
    }

    final unused =
        candidates.where((p) => !tentativeUsedIds.contains(p.id)).toList();

    return (
      days: tentativeDays,
      unused: unused,
    );
  }

  Future<({ItineraryDay day, Set<String> usedIds})?> _generateOptwSingleDay({
    required int dayIndex,
    required int googleWeekday,
    required String date,
    required int placesPerDay,
    required List<PlaceModel> attractions,
    required List<PlaceModel> fullMeals,
    required List<PlaceModel> lightFoods,
    required Set<String> tentativeUsedIds,
    required double userLat,
    required double userLng,
    required String travelMode,
    required TravelMode travelModeEnum,
    required double Function(PlaceModel) quality,
    required bool onlyFoodRequested,
    required List<String> normalizedCategories,
    required List<String> cuisines,
  }) async {
    final availableMeals =
        fullMeals.where((p) => !tentativeUsedIds.contains(p.id)).toList();
    final availableAttractions =
        attractions.where((p) => !tentativeUsedIds.contains(p.id)).toList();
    final availableLightFoods =
        lightFoods.where((p) => !tentativeUsedIds.contains(p.id)).toList();

    final S = placesPerDay;
    final R = _requiredRestaurantsPerDay(S);
    final N = S - R;

    int mealQuota;
    int attrQuota;
    int lightQuota;

    if (onlyFoodRequested) {
      attrQuota = 0;
      final desiredMeals = math.max(R + 2, S);
      final desiredLights = math.max(N + 1, 3);
      var mQ = math.min(availableMeals.length, desiredMeals);
      var lQ = math.min(availableLightFoods.length, desiredLights);

      if (mQ + lQ > 9) {
        if (mQ > 5) mQ = 5;
        lQ = math.min(availableLightFoods.length, 9 - mQ);
      }
      if (mQ + lQ < 9) {
        final extraM = math.min(availableMeals.length - mQ, 9 - (mQ + lQ));
        mQ += extraM;
        final extraL = math.min(availableLightFoods.length - lQ, 9 - (mQ + lQ));
        lQ += extraL;
      }
      mealQuota = mQ;
      lightQuota = lQ;
    } else {
      final desiredMeals = math.max(R + 1, 3);
      final desiredAttrs = math.max(N + 1, 4);
      const desiredLights = 2;
      var mQ = math.min(availableMeals.length, desiredMeals);
      var aQ = math.min(availableAttractions.length, desiredAttrs);
      var lQ = math.min(availableLightFoods.length, desiredLights);

      var total = mQ + aQ + lQ;
      if (total < 9) {
        final extraA = math.min(availableAttractions.length - aQ, 9 - total);
        aQ += extraA;
        total = mQ + aQ + lQ;
      }
      if (total < 9) {
        final extraL = math.min(availableLightFoods.length - lQ, 9 - total);
        lQ += extraL;
        total = mQ + aQ + lQ;
      }
      if (total < 9) {
        final extraM = math.min(availableMeals.length - mQ, 9 - total);
        mQ += extraM;
        total = mQ + aQ + lQ;
      }

      while (mQ + aQ + lQ > 9) {
        if (lQ > 2) {
          lQ--;
        } else if (aQ > 4) {
          aQ--;
        } else if (mQ > 3) {
          mQ--;
        } else if (lQ > 1) {
          lQ--;
        } else if (aQ > 2) {
          aQ--;
        } else if (mQ > 2) {
          mQ--;
        } else {
          break;
        }
      }
      mealQuota = mQ;
      attrQuota = aQ;
      lightQuota = lQ;
    }

    final shortlistedMeals = _buildOptwShortlist(
      pool: availableMeals,
      quota: mealQuota,
      rolesToCover: [_OptwRole.lunch, _OptwRole.dinner],
      googleWeekday: googleWeekday,
      userLat: userLat,
      userLng: userLng,
      quality: quality,
    );
    final shortlistedAttrs = _buildOptwShortlist(
      pool: availableAttractions,
      quota: attrQuota,
      rolesToCover: [_OptwRole.attraction],
      googleWeekday: googleWeekday,
      userLat: userLat,
      userLng: userLng,
      quality: quality,
    );
    final shortlistedLights = _buildOptwShortlist(
      pool: availableLightFoods,
      quota: lightQuota,
      rolesToCover: [_OptwRole.lightFood],
      googleWeekday: googleWeekday,
      userLat: userLat,
      userLng: userLng,
      quality: quality,
    );

    final dayCandidates = <PlaceModel>[
      ...shortlistedMeals,
      ...shortlistedAttrs,
      ...shortlistedLights,
    ];

    if (dayCandidates.isEmpty) {
      return null;
    }

    debugPrint(
      '[ITIN_OPTW][SHORTLIST] '
      'day=${dayIndex + 1} '
      'meals=[${shortlistedMeals.map((p) => '${p.id}:${p.name}').join(', ')}] '
      'attractions=[${shortlistedAttrs.map((p) => '${p.id}:${p.name}').join(', ')}] '
      'lightFoods=[${shortlistedLights.map((p) => '${p.id}:${p.name}').join(', ')}] '
      'totalCandidates=${dayCandidates.length}',
    );

    // Request pairwise Route Matrix
    final points = [
      LatLng(userLat, userLng),
      ...dayCandidates.map((p) => LatLng(p.lat!, p.lng!)),
    ];

    List<RouteMatrixElement> matrixElements;
    try {
      matrixElements = await RouteService.instance.fetchRouteMatrix(
        origins: points,
        destinations: points,
        mode: travelModeEnum,
      );
    } catch (_) {
      return null;
    }

    if (matrixElements.isEmpty) {
      return null;
    }

    debugPrint(
      '[ITIN_OPTW][MATRIX] day=${dayIndex + 1} '
      'points=${points.length} '
      'elements=${matrixElements.length} '
      'travelMode=$travelMode',
    );

    // Build matrix lookup map: key = "${originIndex}_${destinationIndex}"
    final matrixMap = <String, RouteMatrixElement>{};
    for (final el in matrixElements) {
      if (el.isValid && el.durationSeconds >= 0 && el.distanceMeters >= 0) {
        matrixMap['${el.originIndex}_${el.destinationIndex}'] = el;
      }
    }

    _OptwFeasiblePlan? bestPlan;
    int totalPatternsEvaluated = 0;
    int totalStatesEvaluated = 0;
    int totalFeasiblePlansFound = 0;

    for (int targetLength = S; targetLength >= 1; targetLength--) {
      final patterns = _buildRolePatterns(targetLength, onlyFoodRequested);
      _OptwFeasiblePlan? bestPlanForLength;

      for (int pIdx = 0; pIdx < patterns.length; pIdx++) {
        final pattern = patterns[pIdx];
        if (pattern.length != targetLength) {
          debugPrint(
            '[ITIN_OPTW][PATTERN_SKIP] day=${dayIndex + 1} '
            'patternIndex=$pIdx '
            'expected=$targetLength '
            'actual=${pattern.length} '
            'reason="length_mismatch"',
          );
          continue;
        }

        final lunchCount = pattern.where((r) => r == _OptwRole.lunch).length;
        final dinnerCount = pattern.where((r) => r == _OptwRole.dinner).length;
        final fullMealCount = lunchCount + dinnerCount;

        if (!onlyFoodRequested) {
          final reqMeals = _requiredRestaurantsPerDay(targetLength);
          if (fullMealCount != reqMeals || lunchCount > 1 || dinnerCount > 1) {
            debugPrint(
              '[ITIN_OPTW][PATTERN_SKIP] day=${dayIndex + 1} '
              'patternIndex=$pIdx '
              'fullMeals=$fullMealCount '
              'expectedMeals=$reqMeals '
              'lunchCount=$lunchCount '
              'dinnerCount=$dinnerCount '
              'reason="meal_count_mismatch"',
            );
            continue;
          }
        } else {
          if (lunchCount > 1 || dinnerCount > 1) {
            debugPrint(
              '[ITIN_OPTW][PATTERN_SKIP] day=${dayIndex + 1} '
              'patternIndex=$pIdx '
              'lunchCount=$lunchCount '
              'dinnerCount=$dinnerCount '
              'reason="meal_count_mismatch"',
            );
            continue;
          }
        }

        totalPatternsEvaluated++;

        debugPrint(
          '[ITIN_OPTW][ROLE_PATTERN] day=${dayIndex + 1} '
          'patternIndex=$pIdx '
          'pattern=[${pattern.map((r) => r.name).join(' -> ')}]',
        );

        // Deterministic bounded exhaustive DFS with feasibility pruning
        void dfs({
          required int index,
          required List<PlaceModel> currentPlaces,
          required List<int> visitStarts,
          required Set<String> usedIds,
          required int cursorMinutes,
          required int totalRoadDurationSec,
          required double totalRoadDistMeters,
          required int totalWaitMinutes,
          required double totalQuality,
        }) {
          totalStatesEvaluated++;
          if (index == pattern.length) {
            totalFeasiblePlansFound++;

            // Distinct requested preference coverage
            final coveredPrefs = <String>{};
            for (final p in currentPlaces) {
              final canonical = CategoryMapper.resolvePrimaryType(
                p.primaryType,
                p.allTypes,
              );
              if (normalizedCategories.contains(canonical)) {
                coveredPrefs.add('cat:$canonical');
              }
              for (final c in cuisines) {
                if (_matchesCuisine(p, [c])) {
                  coveredPrefs.add('cuisine:$c');
                }
              }
            }
            final coveredPrefsList = coveredPrefs.toList()..sort();
            final matchedPrefs = coveredPrefsList.length;

            // Canonical category diversity
            final diversity = currentPlaces
                .map((p) {
                  return CategoryMapper.resolvePrimaryType(
                    p.primaryType,
                    p.allTypes,
                  );
                })
                .toSet()
                .length;

            final idSeq = currentPlaces.map((p) => p.id).join('_');

            final candidatePlan = _OptwFeasiblePlan(
              places: List.from(currentPlaces),
              roles: List.from(pattern),
              visitStarts: List.from(visitStarts),
              totalRoadDurationSec: totalRoadDurationSec,
              totalRoadDistMeters: totalRoadDistMeters,
              totalWaitMinutes: totalWaitMinutes,
              totalQuality: totalQuality,
              coveredPreferences: coveredPrefsList,
              matchedPreferencesCount: matchedPrefs,
              categoryDiversityCount: diversity,
              idSequence: idSeq,
            );

            if (candidatePlan.isBetterThan(bestPlanForLength)) {
              bestPlanForLength = candidatePlan;
            }
            return;
          }

          final role = pattern[index];
          final List<PlaceModel> rolePool;
          if (role == _OptwRole.lunch || role == _OptwRole.dinner) {
            rolePool = shortlistedMeals;
          } else if (role == _OptwRole.attraction) {
            rolePool = shortlistedAttrs;
          } else {
            rolePool = shortlistedLights;
          }

          final remainingOfThisRole =
              pattern.sublist(index).where((r) => r == role).length;
          final availableInPool =
              rolePool.where((p) => !usedIds.contains(p.id)).length;
          if (availableInPool < remainingOfThisRole) {
            return;
          }

          for (final place in rolePool) {
            if (usedIds.contains(place.id)) continue;

            final int legTravelSec;
            final double legTravelDist;
            final int legTravelMin;
            final int minEarliestArrival;

            if (index == 0) {
              final toIdx = dayCandidates.indexOf(place) + 1;
              final el = matrixMap['0_$toIdx'];
              if (el == null) continue;
              legTravelSec = el.durationSeconds;
              legTravelDist = el.distanceMeters;
              legTravelMin = (legTravelSec / 60.0).ceil();
              minEarliestArrival = 480;
            } else {
              final prev = currentPlaces[index - 1];
              final fromIdx = dayCandidates.indexOf(prev) + 1;
              final toIdx = dayCandidates.indexOf(place) + 1;
              final el = matrixMap['${fromIdx}_$toIdx'];
              if (el == null) continue;
              legTravelSec = el.durationSeconds;
              legTravelDist = el.distanceMeters;
              legTravelMin = (legTravelSec / 60.0).ceil();
              minEarliestArrival = cursorMinutes + legTravelMin;
            }

            final dur = _resolveVisitDuration(place, role);
            final vStart = _findEarliestFeasibleVisitStart(
              place: place,
              role: role,
              minEarliestArrival: minEarliestArrival,
              duration: dur,
              googleWeekday: googleWeekday,
            );
            if (vStart == null) continue;

            final waitMin = index == 0 ? 0 : (vStart - minEarliestArrival);
            final newCursor = vStart + dur;
            if (newCursor > 1290) continue;

            currentPlaces.add(place);
            visitStarts.add(vStart);
            usedIds.add(place.id);

            dfs(
              index: index + 1,
              currentPlaces: currentPlaces,
              visitStarts: visitStarts,
              usedIds: usedIds,
              cursorMinutes: newCursor,
              totalRoadDurationSec: totalRoadDurationSec + legTravelSec,
              totalRoadDistMeters: totalRoadDistMeters + legTravelDist,
              totalWaitMinutes: totalWaitMinutes + waitMin,
              totalQuality: totalQuality + quality(place),
            );

            usedIds.remove(place.id);
            visitStarts.removeLast();
            currentPlaces.removeLast();
          }
        }

        dfs(
          index: 0,
          currentPlaces: [],
          visitStarts: [],
          usedIds: {},
          cursorMinutes: 480,
          totalRoadDurationSec: 0,
          totalRoadDistMeters: 0.0,
          totalWaitMinutes: 0,
          totalQuality: 0.0,
        );
      }

      if (bestPlanForLength != null) {
        bestPlan = bestPlanForLength;
        break;
      }
    }

    debugPrint(
      '[ITIN_OPTW][SEARCH_SUMMARY] day=${dayIndex + 1} '
      'patternsEvaluated=$totalPatternsEvaluated '
      'statesEvaluated=$totalStatesEvaluated '
      'feasiblePlansFound=$totalFeasiblePlansFound',
    );

    if (bestPlan == null) {
      return null;
    }

    if (bestPlan.places.length < S) {
      debugPrint(
        '[ITIN_OPTW][REDUCED] day=${dayIndex + 1} '
        'requestedStops=$S '
        'reducedStops=${bestPlan.places.length} '
        'reason="no_full_schedule_feasible"',
      );
    }

    final orderStr = bestPlan.places
        .asMap()
        .entries
        .map((e) => '${e.value.name}(${bestPlan!.roles[e.key].name})')
        .join(' -> ');
    final timesStr = bestPlan.visitStarts.map((t) {
      final hh = (t ~/ 60).toString().padLeft(2, '0');
      final mm = (t % 60).toString().padLeft(2, '0');
      return '$hh:$mm';
    }).join(', ');

    debugPrint(
      '[ITIN_OPTW][BEST] day=${dayIndex + 1} '
      'stops=${bestPlan.places.length} '
      'order=[$orderStr] '
      'times=[$timesStr] '
      'roadDurationSec=${bestPlan.totalRoadDurationSec} '
      'roadDistanceMeters=${bestPlan.totalRoadDistMeters.toStringAsFixed(1)} '
      'waitMin=${bestPlan.totalWaitMinutes} '
      'prefMatch=${bestPlan.matchedPreferencesCount} '
      'coveredPrefs=[${bestPlan.coveredPreferences.join(', ')}] '
      'diversity=${bestPlan.categoryDiversityCount} '
      'quality=${bestPlan.totalQuality.toStringAsFixed(2)}',
    );

    final plan = bestPlan;
    final timelineItems = plan.places.asMap().entries.map((e) {
      final p = e.value;
      final role = plan.roles[e.key];
      final vStart = plan.visitStarts[e.key];
      final dur = _resolveVisitDuration(p, role);
      final vEnd = vStart + dur;
      final sH = (vStart ~/ 60).toString().padLeft(2, '0');
      final sM = (vStart % 60).toString().padLeft(2, '0');
      final eH = (vEnd ~/ 60).toString().padLeft(2, '0');
      final eM = (vEnd % 60).toString().padLeft(2, '0');
      return '$sH:$sM-$eH:$eM ${p.name} (${role.name})';
    }).join(' | ');

    debugPrint(
      '[ITIN_OPTW][TIMELINE] day=${dayIndex + 1} '
      'schedule=[$timelineItems]',
    );

    final scheduledPlaces = <ItineraryPlace>[];
    for (int i = 0; i < plan.places.length; i++) {
      final p = plan.places[i];
      final role = plan.roles[i];
      final startMin = plan.visitStarts[i];
      final hh = (startMin ~/ 60) % 24;
      final mm = startMin % 60;
      final timeStr =
          '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
      final dur = _resolveVisitDuration(p, role);

      scheduledPlaces.add(
        ItineraryPlace(
          placeId: p.id,
          name: p.name,
          address: p.address ?? '',
          photoUrl: p.photoUrl,
          lat: p.lat,
          lng: p.lng,
          primaryType: CategoryMapper.resolvePrimaryType(
            p.primaryType,
            p.allTypes,
          ),
          suggestedTime: timeStr,
          durationMinutes: dur,
          notes: _generateNote(p),
        ),
      );
    }

    final dayObj = ItineraryDay(
      dayNumber: dayIndex + 1,
      date: date,
      places: scheduledPlaces,
    );

    return (
      day: dayObj,
      usedIds: plan.places.map((p) => p.id).toSet(),
    );
  }

  // ─────────────────────────────────────────────
  // Food role classification helper
  // ─────────────────────────────────────────────

  static const _majorNonMealVenueTypes = {
    'amusement_park',
    'tourist_attraction',
    'museum',
    'shopping_mall',
    'movie_theater',
    'bowling_alley',
    'video_arcade',
    'amusement_center',
    'zoo',
    'aquarium',
    'stadium',
    'park',
    'historical_landmark',
    'monument',
    'art_gallery',
    'national_park',
    'botanical_garden',
  };

  static const _fullMealTypes = {
    'restaurant',
    'fast_food_restaurant',
    'food_court',
    'chinese_restaurant',
    'malaysian_restaurant',
    'malay_restaurant',
    'indian_restaurant',
    'western_restaurant',
    'american_restaurant',
    'japanese_restaurant',
    'korean_restaurant',
    'thai_restaurant',
    'italian_restaurant',
    'vietnamese_restaurant',
    'seafood_restaurant',
    'vegetarian_restaurant',
    'buffet_restaurant',
    'steak_house',
    'sushi_restaurant',
    'pizza_restaurant',
    'ramen_restaurant',
  };

  static const _lightFoodTypes = {
    'cafe',
    'coffee_shop',
    'bakery',
    'dessert_shop',
    'ice_cream_shop',
    'meal_takeaway',
  };

  static const _excludedItineraryTypes = {
    'meal_delivery',
    'bar',
    'night_club',
  };

  static ({_ItineraryFoodRole role, String reason}) _classifyFoodRole(
    PlaceModel place,
  ) {
    final rawTypes = place.allTypes;

    // 1. Major non-meal venue: must stay in attractions (nonFood), never meal or lightFood
    if (rawTypes.any(_majorNonMealVenueTypes.contains)) {
      return (role: _ItineraryFoodRole.nonFood, reason: 'major_non_meal_venue');
    }

    // 2. Full-meal destination: verified dining types
    if (rawTypes.any(_fullMealTypes.contains)) {
      return (
        role: _ItineraryFoodRole.fullMeal,
        reason: 'full_meal_type_match'
      );
    }

    // 3. Light food / snack: verified light food types
    if (rawTypes.any(_lightFoodTypes.contains)) {
      return (
        role: _ItineraryFoodRole.lightFood,
        reason: 'light_food_type_match'
      );
    }

    // 4. Excluded non-destination types (e.g. delivery only or nightlife)
    if (rawTypes.any(_excludedItineraryTypes.contains)) {
      return (role: _ItineraryFoodRole.excluded, reason: 'excluded_venue_type');
    }

    return (role: _ItineraryFoodRole.nonFood, reason: 'no_food_type');
  }

  // ─────────────────────────────────────────────
  // Rule-based notes
  //
  // 🔧 CHANGED: 'amusement_park' → 'entertainment'
  // ─────────────────────────────────────────────

  String _generateNote(PlaceModel p) {
    final stars =
        p.rating != null ? '⭐ ${p.rating!.toStringAsFixed(1)} · ' : '';

    return switch (p.primaryType ?? '') {
      'restaurant' =>
        '${stars}Popular dining spot. Check wait times during peak hours.',
      'tourist_attraction' =>
        '${stars}A must-visit landmark. Arrive early to avoid crowds.',
      'shopping_mall' => '${stars}Great for shopping and indoor activities.',
      'entertainment' =>
        '${stars}Fun for all ages. Book tickets in advance if possible.',
      'park' => '${stars}Perfect for a relaxing outdoor break.',
      _ => '${stars}Worth a visit during your trip.',
    };
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
