// services/itinerary_service.dart
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/itineraryModel.dart';
import '../models/placeModel.dart';
import '../services/location_service.dart';
import '../services/userPreference_service.dart';
import '../services/nearbyPlace_service.dart'; 
import 'storage_service.dart';
import '../services/nearbyPlace_service.dart'; 
import '../services/route_service.dart';


class ItineraryService {
  static final ItineraryService instance = ItineraryService._();
  ItineraryService._();

  final _db = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference? get _col => _uid == null
      ? null
      : _db.collection('users').doc(_uid).collection('itineraries');

  // ─────────────────────────────────────────────
  // Default categories (fallback when user selects none)
  // ─────────────────────────────────────────────

  static const _defaultCategories = [
    'restaurant',
    'tourist_attraction',
    'shopping_mall',
    'amusement_park',
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

  // 🆕 每个类别的默认停留时长（分钟）——用于问题3：时长不再死套模板，
  // 而是按地点类型给一个更合理的默认值。类型不在这张表里的，
  // 仍会 fallback 用原本的 slot 模板时长。
  static const _defaultDurationByType = {
    'restaurant':         75,
    'tourist_attraction': 120,
    'shopping_mall':      90,
    'amusement_park':     150,
    'park':               60,
  };

  bool _isBlocked(PlaceModel p) {
    if (p.allTypes.any((t) => _blockedTypes.contains(t))) return true;
    final nameLower = p.name.toLowerCase();
    if (_blockedNameKeywords.any((k) => nameLower.contains(k))) return true;
    return false;
  }

  bool _isSuitableForTravel(PlaceModel p) {
    if (_isBlocked(p)) return false;
    final r = p.rating;
    if (r != null && r > 4.95) return false;
    if (r != null && r < 3.5)  return false;
    return true;
  }

  // 🆕 抽出来的共用评分方法（问题4要在 _scheduleItinerary 里也用到，
  // 之前是 _buildBalancedPlaces 内部的匿名闭包，现在变成可复用的方法）
  double _score(PlaceModel p) {
    final prefs = UserPreferenceService.instance;
    return prefs.recommendationScore(
      primaryType: p.primaryType, allTypes: p.allTypes,
      rating: p.rating, distanceMeters: null, priceLevel: p.priceLevel,
    ).total;
  }

  // ─────────────────────────────────────────────
  // Radius from travel mode
  // ─────────────────────────────────────────────
  //
  // 跟 onboarding 收集的 travelMode 用同一套字符串（walk/drive/both），
  // 但这里独立维护映射，不依赖 route_service.dart 的 TravelMode 枚举
  // （那个是 walk/drive/motor，跟 onboarding 的选项不是一回事）。
  int _radiusFromTravelMode(String travelMode) {
    switch (travelMode) {
      case 'walk':  return 3000;
      case 'drive': return 15000;
      case 'both':  return 8000;
      default:      return 8000;
    }
  }

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

  Future<String?> save(ItineraryModel item) async {
    if (_uid == null) {
      print('❌ save: user not logged in');
      return null;
    }
    if (_col == null) return null;
    try {
      if (item.id.isEmpty) {
        final ref = await _col!.add(item.toMap());
        return ref.id;
      } else {
        await _col!.doc(item.id).set(item.toMap());
        return item.id;
      }
    } catch (e) {
      print('❌ save: $e');
      return null;
    }
  }

  Future<void> update(ItineraryModel item) async {
    if (_col == null || item.id.isEmpty) return;
    try {
      await _col!.doc(item.id).update(item.toMap());
    } catch (e) {
      print('❌ update: $e');
    }
  }

  Future<bool> delete(String id) async {
    if (_col == null) return false;
  
    try {
      final doc = await _col!.doc(id).get();
      if (!doc.exists) return false;
  
      final itinerary = ItineraryModel.fromMap(
        doc.id,
        doc.data() as Map<String, dynamic>,
      );
  
      // ★ 改动：只要开始打卡（isStarted），不管完成与否，一律不能删
      if (itinerary.isStarted) {
        print('🚫 delete blocked: "${itinerary.title}" has been started, cannot delete');
        return false;
      }
  
      await _col!.doc(id).delete();
      return true;
    } catch (e) {
      print('❌ delete: $e');
      return false;
    }
  }
  

  // ─────────────────────────────────────────────
  // Fetch places for itinerary generation
  // ─────────────────────────────────────────────
  //
  // FIX: now accepts `categories` so that the user's selection from
  // GenerateItineraryPage (overrideCategories) actually controls which
  // place types get queried. Falls back to the full default set if the
  // user cleared every category, so generation never silently returns
  // nothing.

  Future<Map<String, List<PlaceModel>>> _fetchPlacesForItinerary({
    required double lat,
    required double lng,
    required List<String> categories,
    required bool isCurrentLocation,   // 保留这个参数（未来可能还有用），但现在两条路径走同一个 fetch
    required int radius,
  }) async {

    // 🔍 DEBUG
    print('🎯 [_fetchPlacesForItinerary] received radius=${radius}m');

    final types = categories.isNotEmpty
        ? {...categories, 'restaurant'}.toList()
        : _defaultCategories;

    print('🗺️ Fetching itinerary candidates — dedicated 5-category fetch '
        '(${isCurrentLocation ? "current location" : "searched location"})');
    final stopwatch = Stopwatch()..start();

    // 🔍 DEBUG
    print('🎯 [_fetchPlacesForItinerary] about to call fetchForItinerary with radius=${radius}m');

    // 🔧 CHANGED: 不再区分 current/searched location 走不同的底层 fetch。
    // 两条路径现在统一走这个专门给 itinerary 用的 5 类独立 fetch，
    // 不再依赖 Home 的 4 组共享 cache，也不再调用 Geoapify。
    final allPlaces = await NearbyPlacesService.instance.fetchForItinerary(
      lat: lat, lng: lng, categories: types, radius: radius,
    );

    stopwatch.stop();
    print('🗺️ Got ${allPlaces.length} candidate places in ${stopwatch.elapsedMilliseconds}ms');

    const categoryTypeMap = <String, List<String>>{
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
  //
  // FIX: now accepts `categories` and threads it through to
  // _fetchPlacesForItinerary, and skips categories the user didn't select
  // (via `wants`). `restaurant` is force-included regardless of selection
  // because every itinerary needs somewhere to eat.

  Future<({List<PlaceModel> places, List<PlaceModel> leftovers})> _buildBalancedPlaces(
    int totalDays, {
    required int placesPerDay, 
    required double lat,
    required double lng,
    required List<String> categories,
    required bool isCurrentLocation,
    required int radius,
  }) async {
    print('🎯 [_buildBalancedPlaces] received radius=${radius}m');

    final minRestaurantsPerDay = placesPerDay <= 2 ? 1 : 2;
    final targetAttractionsPerDay = placesPerDay - minRestaurantsPerDay;
    final totalAttractionsNeeded = totalDays * targetAttractionsPerDay;
    final perCategory = totalAttractionsNeeded.clamp(4, 20);

    final totalRestaurantsNeeded = totalDays * minRestaurantsPerDay;
    final restaurantCount = totalRestaurantsNeeded.clamp(4, 30);

    final byType = await _fetchPlacesForItinerary(
      lat: lat, lng: lng, categories: categories,
      isCurrentLocation: isCurrentLocation, radius: radius, 
    );

    // 🔧 CHANGED: 之前这里是一个内嵌的 score() 闭包，现在改成调用
    // 共用的 _score()，让 _scheduleItinerary 里的质量复查也能用同一套评分。
    double score(PlaceModel p) => _score(p);

    bool wants(String type) => categories.isEmpty || categories.contains(type);

    // 收集"合格但没被选中"的候选，作为 RouteOptimizerPage 的候补池
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
    final entertainment = topByType('amusement_park',     perCategory);
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

    // 候补池去重（跟正式候选去重、也跟自己内部去重）
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
  //
  // FIX: overrideCategories is now actually read and passed down to
  // _buildBalancedPlaces instead of being ignored.

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
}) async {

  final requestedTotal = totalDays * placesPerDay;

  try {
    final cuisines = overrideCuisines
        ?? UserPreferenceService.instance.current.cuisines;
    final categories = overrideCategories
        ?? UserPreferenceService.instance.current.categories;

    final travelMode = overrideTravelMode
      ?? UserPreferenceService.instance.current.travelMode;
    final radius = _radiusFromTravelMode(travelMode);

    print('🎯 [generate] overrideTravelMode=$overrideTravelMode → '
        'travelMode=$travelMode → radius=${radius}m');

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

    // 🔧 CHANGED: 传入 userLat/userLng（给地理分组用来锚定 Day1），
    // 以及 leftoverPool（给质量复查步骤用）。返回值现在是一个 record：
    // days + unused（分配阶段没用到、之前会"人间蒸发"的候选）。
    final scheduleResult = _scheduleItinerary(
      places:       validPlaces,
      totalDays:    totalDays,
      placesPerDay: placesPerDay,
      startDates:   dayDates,
      cuisines:     cuisines,
      userLat:      lat,
      userLng:      lng,
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

    // 🆕 把分配阶段没用到的候选（之前会直接消失）合并进候补池，去重
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
      isOriginCurrentLocation: isCurrentLocation,   // 🆕
      originLat:  lat,                               // 🆕
      originLng:  lng,                               // 🆕
      originName: null,                              // 🆕 GenerateItineraryPage 那边会 copyWith 补上真正的名字
      travelMode: travelMode,                        // 🆕 复用方法开头已解析出来的 'walk'/'drive'/'both' 字符串
      leftoverPlaceIds: finalLeftovers.map((p) => p.id).toList(),  // 🆕

    );

    return ItineraryGenerationResult(
      itinerary: itinerary,
      requestedTotal: requestedTotal,
      actualTotal: actualTotal,
      leftoverCandidates: finalLeftovers,   // 🔧 CHANGED: 用合并后的完整候补池
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
  
  /// 把一批 ItineraryDay 里所有地点的 photoUrl，从 Google 的临时链接
  /// 换成 Firebase Storage 的永久链接。
  ///
  /// 公开方法（不是 _ 开头）—— 因为除了 generate() 自动生成的行程要用，
  /// RouteOptimizerPage 里用户手动拼的自定义行程在保存前也要走一遍
  /// 同样的处理，否则手动拼的行程一样会遇到「过几天图片消失」的问题。
  ///
  /// 同一个 placeId 在这批 days 里只会下载/上传一次（哪怕它出现在
  /// 好几个不同的 day 里），减少不必要的网络开销。
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
  //
  // 🔧 CHANGED: 签名加了 userLat/userLng（传给 _geoClusters 用来锚定
  // Day1）和 leftoverPool（质量复查用）。返回值从 `List<ItineraryDay>?`
  // 改成一个 record：{days, unused} —— unused 是分配阶段没用到的候选，
  // 之前这些点会直接消失，现在交回给 generate() 合并进候补池。

  ({List<ItineraryDay>? days, List<PlaceModel> unused}) _scheduleItinerary({
    required List<PlaceModel> places,
    required int              totalDays,
    required int              placesPerDay,
    required List<String>     startDates,
    required List<String>     cuisines,
    required double            userLat,
    required double            userLng,
    List<PlaceModel>?          leftoverPool,
  }) {
    final restaurants = places.where((p) => p.primaryType == 'restaurant').toList();
    final others      = places.where((p) => p.primaryType != 'restaurant').toList();

    final minRestaurantsPerDay = placesPerDay <= 2 ? 1 : 2;
    final targetAttractionsPerDay = placesPerDay - minRestaurantsPerDay;

    // 🔧 CHANGED: 传入 userLat/userLng，让 Day 1 的种子锚定在用户实际出发点
    final clusters = _geoClusters(others, totalDays, userLat: userLat, userLng: userLng);
    final dayCenters = List.generate(totalDays, (i) {
      final seed = clusters[i].isNotEmpty ? clusters[i] : others;
      return _centroid(seed);
    });

    final usedIds = <String>{};
    final List<List<PlaceModel>> dayPlaces = List.generate(totalDays, (_) => []);

    // ── Step 2: 全局贪心——每一轮，每天依次尝试补一个坑，直到排满或候选耗尽 ──
    for (int round = 0; round < placesPerDay; round++) {
      for (int day = 0; day < totalDays; day++) {
        if (dayPlaces[day].length >= placesPerDay) continue;

        final currentRestaurantCount =
            dayPlaces[day].where((p) => p.primaryType == 'restaurant').length;
        final currentOthersCount = dayPlaces[day].length - currentRestaurantCount;

        final needsRestaurant = currentRestaurantCount < minRestaurantsPerDay;
        final needsAttraction = currentOthersCount < targetAttractionsPerDay;

        PlaceModel? picked;

        if (needsRestaurant) {
          picked = _pickClosestUnused(restaurants, dayCenters[day], usedIds, cuisines);
        }
        if (needsAttraction) {
          // 🔧 CHANGED: 优先从这一天自己的地理分组里挑，避免把"视觉上
          // 属于别天那一堆"的边界点抢过来。只有这一天自己的分组已经
          // 被挑光了，才退回全局池子补位。
          picked ??= _pickClosestUnused(clusters[day], dayCenters[day], usedIds, null)
                ?? _pickClosestUnused(others, dayCenters[day], usedIds, null);
        }
        // 弹性兜底：正常配额都满了，但这天还没排满 placesPerDay，
        // 就不管类型，池子谁还有剩的就拿谁（离得近的优先，自己那堆优先）。
        picked ??= _pickClosestUnused(restaurants, dayCenters[day], usedIds, cuisines)
              ?? _pickClosestUnused(clusters[day], dayCenters[day], usedIds, null)
              ?? _pickClosestUnused(others, dayCenters[day], usedIds, null);

        if (picked != null) {
          usedIds.add(picked.id);
          dayPlaces[day].add(picked);
        }
      }
    }

    // ── Step 2.5: 质量复查——把候补池里被埋没的高分地点捞回来 ──
    // Step 2 只在各 category 各自取的 top-N 候选里挑，但候补池
    // (leftoverPool) 里可能躺着一个分数更高的地点，只是因为它所在的
    // category 名额比较挤，没能进正式候选池。这里做一次事后复查：
    // 分数明显更高、离这天中心也不算太远，就换进来。餐厅不参与这项
    // 复查（餐厅本来就是按"离得近"选的，不做跨类别质量比较）。
    if (leftoverPool != null && leftoverPool.isNotEmpty) {
      for (int day = 0; day < totalDays; day++) {
        final dayList = dayPlaces[day];
        for (int i = 0; i < dayList.length; i++) {
          final current = dayList[i];
          if (current.primaryType == 'restaurant') continue;

          final currentScore = _score(current);
          final currentDist = (current.lat != null && current.lng != null)
              ? _distSq(current.lat!, current.lng!, dayCenters[day].lat, dayCenters[day].lng)
              : double.infinity;

          PlaceModel? better;
          double bestScore = currentScore;

          for (final candidate in leftoverPool) {
            if (usedIds.contains(candidate.id)) continue;
            if (candidate.lat == null || candidate.lng == null) continue;

            final candScore = _score(candidate);
            if (candScore <= bestScore + 0.05) continue; // 分数没明显更好，跳过

            final candDist = _distSq(
                candidate.lat!, candidate.lng!, dayCenters[day].lat, dayCenters[day].lng);
            // 候补要么离这天中心更近，要么距离差距在容忍范围内（2.5倍），
            // 否则宁可保留地理集中度，也不为了分数牺牲太远的路程
            if (candDist > currentDist * 2.5) continue;

            bestScore = candScore;
            better = candidate;
          }

          if (better != null) {
            usedIds.remove(current.id);
            usedIds.add(better.id);
            dayList[i] = better;
            print('🔄 Quality swap Day ${day + 1}: ${current.name}'
                '(${currentScore.toStringAsFixed(2)}) → ${better.name}'
                '(${bestScore.toStringAsFixed(2)})');
          }
        }
      }
    }

    // 🆕 把两个池子里没被用到的地点收集起来，交回给 generate() 合并进候补池，
    // 而不是像之前那样直接消失（问题2）
    final allCandidates = [...restaurants, ...others];
    final unused = allCandidates.where((p) => !usedIds.contains(p.id)).toList();

    // ── Step 3: 组装成 ItineraryDay，复用现有的时间段分配逻辑 ──
    final days = <ItineraryDay>[];
    for (int i = 0; i < totalDays; i++) {
      final dayRestaurants = dayPlaces[i].where((p) => p.primaryType == 'restaurant').toList();
      final dayAttractions = dayPlaces[i].where((p) => p.primaryType != 'restaurant').toList();

      final scheduled = _assignTimeSlots(dayAttractions, dayRestaurants, placesPerDay);

      days.add(ItineraryDay(
        dayNumber: i + 1,
        date:      startDates[i],
        places:    scheduled,
      ));
    }

    return (days: days, unused: unused);
  }

// 抽出的单点选取辅助——从 pool 里挑一个离 center 最近、还没被用过的
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
  // Geo clustering — user-anchored seed + k-means++ weighted sampling
  //   + balanced cluster sizes + convergence-based refinement
  //
  // Groups nearby non-restaurant places into days so each day's stops
  // are geographically close.
  //
  // 🔧 CHANGED (this version):
  //   1. First seed is now the point closest to the user's actual
  //      location, so Day 1 naturally anchors near where the trip starts,
  //      instead of an arbitrary "first in the list" point.
  //   2. Remaining seeds use k-means++ style weighted random sampling
  //      (weight = squared distance to nearest existing seed) instead of
  //      always picking the single farthest point — this still spreads
  //      seeds out but is less easily thrown off by one distant outlier
  //      candidate.
  //   3. After Lloyd refinement, an extra balancing pass moves boundary
  //      points from oversized clusters into undersized ones, so no day
  //      ends up starved of candidates while another is overloaded —
  //      this is what was causing later scheduling to "borrow" points
  //      that visually belonged to a different day's area.
  //   4. Refinement now runs until the centers stop moving meaningfully
  //      (convergence) or a max pass count is hit, instead of a fixed
  //      2 passes.
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

    // ── Step 1a: 第一个种子——离用户实际出发点最近的地方 ──
    PlaceModel firstSeed = located.first;
    double bestDist = double.infinity;
    for (final p in located) {
      final d = _distSq(p.lat!, p.lng!, userLat, userLng);
      if (d < bestDist) { bestDist = d; firstSeed = p; }
    }
    final seeds = <PlaceModel>[firstSeed];

    // ── Step 1b: 后续种子——k-means++ 概率加权采样 ──
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

      if (totalWeight <= 0) break; // 剩下的点都跟种子重合，没得选了

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

    // ── Step 2: 初次分组 ──
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

    // ── Step 3: Lloyd refinement——跑到收敛，或最多 8 轮兜底 ──
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

      if (maxShift < thresholdSq) break; // 已收敛，提前结束
    }

    // ── Step 3.5: 均衡分组大小 ──
    // Lloyd refinement 只保证"每个点归到最近的中心"，完全不管每组
    // 最终有几个点，可能一组30个、另一组只有5个，逼着点少的那天去
    // 跨区域借地点。这里做一次贪心均衡：从最大组里，挑一个"挪去
    // 最小组后损失最小"（也就是真正夹在两组之间）的边界点，挪过去。
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

    // ── Step 4: 补齐到 k 组 ──
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
  // Structure mirrors the old Gemini prompt rules
  // ─────────────────────────────────────────────
  //
  // 🔧 CHANGED: slot 模板仍然决定"这个位置大概几点、是不是餐厅时段"
  // 这个骨架（这样吃饭时间依然合理地落在中午/傍晚），但每个地点的
  // 实际停留时长（durationMinutes）现在按它的 primaryType 决定，
  // 不再死套模板数字；类型不在表里的才 fallback 用模板时长。
  // 后续每个地点的开始时间 = 上一个地点的开始时间 + 上一个的实际时长，
  // 而不是永远采用模板里写死的时间点。

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
      // 6 places
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
    int? cursorMinutes; // 累加实际时长用，不再死套模板时间

    for (final slot in slots) {
      PlaceModel? place;

      if (slot.isRestaurant && resIdx < restaurants.length) {
        place = restaurants[resIdx++];
      } else if (!slot.isRestaurant && attIdx < attractions.length) {
        place = attractions[attIdx++];
      } else if (!slot.isRestaurant && resIdx < restaurants.length) {
        place = restaurants[resIdx++]; // fallback
      } else if (slot.isRestaurant && attIdx < attractions.length) {
        place = attractions[attIdx++]; // fallback
      }

      if (place == null) continue;

      // 按地点实际类型决定时长，类型不在表里才 fallback 用模板数字
      final duration = _defaultDurationByType[place.primaryType] ?? slot.duration;

      // 第一个地点仍用模板时间当"锚点"（一天还是差不多时间开始），
      // 之后每个地点的开始时间 = 上一个的开始时间 + 上一个的实际时长
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

  // 🆕 小工具方法，解析模板里写死的时间字符串（用于 _assignTimeSlots 的锚点）
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
  // ─────────────────────────────────────────────

  String _generateNote(PlaceModel p) {
    final stars = p.rating != null
        ? '⭐ ${p.rating!.toStringAsFixed(1)} · '
        : '';

    return switch (p.primaryType ?? '') {
      'restaurant'         => '${stars}Popular dining spot. Check wait times during peak hours.',
      'tourist_attraction' => '${stars}A must-visit landmark. Arrive early to avoid crowds.',
      'shopping_mall'      => '${stars}Great for shopping and indoor activities.',
      'amusement_park'     => '${stars}Fun for all ages. Book tickets in advance if possible.',
      'park'               => '${stars}Perfect for a relaxing outdoor break.',
      _                    => '${stars}Worth a visit during your trip.',
    };
  }

  // ─────────────────────────────────────────────
  // Geometry helpers
  // ─────────────────────────────────────────────

  /// Squared Euclidean distance (no sqrt needed — used for comparison only)
  double _distSq(double lat1, double lng1, double lat2, double lng2) {
    final dlat = lat1 - lat2;
    final dlng = lng1 - lng2;
    return dlat * dlat + dlng * dlng;
  }

  /// Geographic centroid of a list of places
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
// Generation result — wraps the itinerary plus a flag for whether
// candidate places were insufficient for what the user asked for.
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