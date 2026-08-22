// services/achievement_service.dart
//
// Single source of truth for all achievement logic.
// Used by:
//   - dashboard_page.dart   (full grid display)
//   - profileInfo.dart      (compact badge row)
//   - itineraryDetail.dart  (unlock detection on check-in)
//   - interactionPage.dart  (badge next to username in posts)
//   - addPost.dart          (badge next to username when posting)
//
// ── CHANGE LOG (bug fix pass) ──────────────────────────────────────────────
// 1. saveTopBadgeToFirestore() now uses set(merge: true) instead of update().
//    update() throws if the users/{uid} document doesn't exist yet (e.g. a
//    brand-new account whose profile doc hasn't been created), which was
//    silently failing and leaving topBadgeEmoji/Label/Level permanently
//    missing from Firestore.
// 2. Wrapped the write in try/catch with a debug print so failures are no
//    longer silent.
// 3. ★ NEW: fetchStats() now has a short-lived in-memory cache (30s TTL).
//    Home / Post / Profile pages all call fetchTopBadge()/fetchGroups()
//    independently in their own initState(), which previously meant each
//    page triggered its own full Firestore read + recompute of the
//    history + itineraries collections, even when they all loaded within
//    the same few seconds. Now the first caller does the real read; any
//    other caller within the TTL window gets the cached result instantly.
//    Operations that actually change the underlying data (check-in) call
//    invalidateStatsCache() to force a real refresh on the next read.
// 4. ★ FIX: fetchStats() previously ignored forceRefresh entirely — it took
//    no parameters and always hit Firestore, even though fetchGroups() was
//    already calling fetchStats(forceRefresh: forceRefresh) and the cache
//    fields (_cachedStats/_cachedAt) were declared but never read or
//    written. This didn't compile. fetchStats() now accepts forceRefresh,
//    actually serves from the cache when valid, and populates the cache
//    after a real read.
// -----------------------------------------------------------------------------

import 'dart:math';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'userActivity_service.dart';
import 'category_mapper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Tier — one level within an achievement group
// ─────────────────────────────────────────────────────────────────────────────

class AchievementTier {
  final String level;       // 'bronze' | 'silver' | 'gold'
  final String emoji;       // tier-specific badge emoji (shown in UI)
  final String label;       // e.g. 'Explorer I'
  final String desc;        // e.g. 'Visit 10 places'
  final int threshold;      // value needed to unlock this tier
  final bool unlocked;
  final int currentValue;   // user's current progress value
  final DateTime? unlockedAt; 

  const AchievementTier({
    required this.level,
    required this.emoji,
    required this.label,
    required this.desc,
    required this.threshold,
    required this.unlocked,
    required this.currentValue,
    this.unlockedAt,    
  });

  /// Progress towards this tier: 0.0 – 1.0
  double get progress => unlocked
      ? 1.0
      : (currentValue / threshold).clamp(0.0, 1.0);

  /// How many more units the user needs to unlock this tier.
  int get remaining => unlocked ? 0 : (threshold - currentValue).clamp(0, threshold);

    AchievementTier copyWith({DateTime? unlockedAt}) => AchievementTier(
      level: level, emoji: emoji, label: label, desc: desc,
      threshold: threshold, unlocked: unlocked, currentValue: currentValue,
      unlockedAt: unlockedAt ?? this.unlockedAt,
    );

}

// ─────────────────────────────────────────────────────────────────────────────
// AchievementGroup — one "category" with 3 tiers (bronze → silver → gold)
// ─────────────────────────────────────────────────────────────────────────────

class AchievementGroup {
  final String id;          // unique key, e.g. 'explorer'
  final String baseEmoji;   // used as fallback / locked state icon
  final String title;       // e.g. 'Explorer'
  final List<AchievementTier> tiers; // always exactly 3, bronze → silver → gold

  const AchievementGroup({
    required this.id,
    required this.baseEmoji,
    required this.title,
    required this.tiers,
  });

  /// Highest unlocked tier, or null if none.
  AchievementTier? get highestUnlocked {
    for (int i = tiers.length - 1; i >= 0; i--) {
      if (tiers[i].unlocked) return tiers[i];
    }
    return null;
  }

  /// Next locked tier (the one the user is working towards).
  AchievementTier? get nextTier {
    for (final t in tiers) {
      if (!t.unlocked) return t;
    }
    return null; // all tiers unlocked
  }

  bool get hasAnyUnlocked => highestUnlocked != null;
  bool get fullyUnlocked  => tiers.every((t) => t.unlocked);
}

// ─────────────────────────────────────────────────────────────────────────────
// NewUnlock — returned by checkForNewUnlocks() so the caller can show a dialog
// ─────────────────────────────────────────────────────────────────────────────

class NewUnlock {
  final String groupTitle;
  final AchievementTier tier;

  const NewUnlock({required this.groupTitle, required this.tier});
}

// ─────────────────────────────────────────────────────────────────────────────
// AchievementStats — raw computed values (all-time)
// ─────────────────────────────────────────────────────────────────────────────

class AchievementStats {
  final int placesVisited;
  final int citiesExplored;
  final int tripsCompleted;
  final int foodVisits;
  final int natureVisits;
  final int attractionVisits;
  final double totalDistanceKm;

  const AchievementStats({
    required this.placesVisited,
    required this.citiesExplored,
    required this.tripsCompleted,
    required this.foodVisits,
    required this.natureVisits,
    required this.attractionVisits,
    required this.totalDistanceKm,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// AchievementService — singleton
// ─────────────────────────────────────────────────────────────────────────────

class AchievementService {
  AchievementService._();
  static final AchievementService instance = AchievementService._();

  final _db   = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ── ★ NEW: short-lived stats cache ────────────────────────────────────────
  // Home / Post / Profile pages each independently call fetchTopBadge() or
  // fetchUnlockedBadges() in their own initState(), which all funnel down to
  // fetchStats(). Without this cache, loading all three pages within a few
  // seconds of each other triggers 3 separate full reads + recomputes of the
  // history + itineraries collections for data that hasn't actually changed.
  AchievementStats? _cachedStats;
  DateTime? _cachedAt;
  static const _cacheTtl = Duration(seconds: 30);

  /// Call this after any operation that actually changes the underlying
  /// data (e.g. a check-in that writes a new history entry) so the next
  /// fetchStats() call is forced to do a real read instead of returning a
  /// stale cached value.
  void invalidateStatsCache() {
    _cachedStats = null;
    _cachedAt    = null;
    UserActivityDataService.instance.invalidate();
  }

  // ── Category labels for type mapping ──────────────────────────────────────

  static const _kFoodTypes = [
    'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
    'fast_food_restaurant', 'food_court', 'dessert_shop',
  ];
  static const _kNatureTypes = [
    'park', 'national_park', 'botanical_garden', 'garden', 'hiking_area', 'beach',
  ];
  static const _kAttractionTypes = [
    'tourist_attraction', 'historical_landmark', 'monument', 'museum', 'art_gallery',
  ];

  static String _extractCity(String address) {
    if (address.isEmpty) return '';
    final postcodeRegex = RegExp(r'\d{4,6}\s+([A-Za-z][^,]+)');
    final m = postcodeRegex.firstMatch(address);
    if (m != null) return m.group(1)!.trim();
    final parts = address.split(',').map((s) => s.trim()).toList();
    if (parts.length >= 2) {
      final candidate = parts[parts.length - 2];
      if (!RegExp(r'^\d+$').hasMatch(candidate) && candidate.isNotEmpty) {
        return candidate;
      }
    }
    return parts.isNotEmpty ? parts.last : '';
  }

  static double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
        sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  // ─────────────────────────────────────────────
  // Fetch all-time stats from Firestore
  //
  // ★ [forceRefresh] bypasses the cache — use this after an operation
  // that just wrote new data (e.g. right after a check-in) so the caller
  // is guaranteed to see the up-to-date numbers rather than a stale cache.
  //
  // Otherwise, if a cached result exists and is younger than [_cacheTtl],
  // it's returned immediately with no Firestore read at all.
  // ─────────────────────────────────────────────

  
  Future<AchievementStats> fetchStats({bool forceRefresh = false}) async {
    final uid = _uid;
    if (uid == null) return _emptyStats();
  
    if (!forceRefresh &&
        _cachedStats != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cachedStats!;
    }
  
    // ★ 改动：不再自己查 Firestore，改用共享的 UserActivityDataService，
    // 跟 Dashboard 读的是完全同一份原始数据（同一次 .get() 调用的结果）
    final activity = await UserActivityDataService.instance.getAll(
      forceRefresh: forceRefresh,
    );
    final historyDocs     = activity.history;
    final itinerariesDocs = activity.itineraries;
  
    final seenKeys  = <String>{};
    int placesVisited    = 0;
    int foodVisits       = 0;
    int natureVisits     = 0;
    int attractionVisits = 0;
    double totalDistanceKm = 0;
    final citySet = <String>{};
  
    final Map<String, List<({double lat, double lng, DateTime visitedAt})>>
        byItineraryCoords = {};
  
    // 1) History —— ActivityDoc 而不是 QueryDocumentSnapshot，用法一样，
    //    只是 doc.data() 变成 doc.data（没有括号，因为已经是 Map 了）
    for (final doc in historyDocs) {
      final data      = doc.data;
      final timestamp = data['visitedAt'] as Timestamp?;
      if (timestamp == null) continue;
      final visitedAt = timestamp.toDate();
  
      final placeName = data['placeName'] as String? ?? '';
      final dayKey    = '${visitedAt.year}-${visitedAt.month}-${visitedAt.day}';
      final placeId   = data['placeId'] as String?;
      final key       = placeId != null && placeId.isNotEmpty
          ? '${placeId}_$dayKey' : '${placeName}_$dayKey';
      if (seenKeys.contains(key)) continue;
      seenKeys.add(key);
  
      placesVisited++;
      final address = data['address'] as String? ?? '';
      final city    = _extractCity(address);
      if (city.isNotEmpty) citySet.add(city);
  
      // ★ 改用统一的 CategoryMapper
      final primaryType = data['primaryType'] as String? ?? '';
      final category    = CategoryMapper.toAchievementCategory(primaryType);
      if (category == 'Food')       foodVisits++;
      if (category == 'Nature')     natureVisits++;
      if (category == 'Attraction') attractionVisits++;
  
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final itineraryId = data['itineraryId'] as String? ?? '';
      if (lat != null && lng != null && itineraryId.isNotEmpty) {
        byItineraryCoords.putIfAbsent(itineraryId, () => []);
        byItineraryCoords[itineraryId]!.add((lat: lat, lng: lng, visitedAt: visitedAt));
      }
    }
  
    // 2) Itinerary visited places —— 补漏 + 去重（逻辑不变，只是数据源换了）
    for (final doc in itinerariesDocs) {
      final data = doc.data;
      final days = data['days'] as List? ?? [];
      final itineraryId = doc.id;
  
      for (final day in days) {
        final places = (day as Map<String, dynamic>)['places'] as List? ?? [];
        for (final place in places) {
          final p         = place as Map<String, dynamic>;
          final isVisited = p['isVisited'] as bool? ?? false;
          if (!isVisited) continue;
  
          final timestamp = p['visitedAt'] as Timestamp?;
          if (timestamp == null) continue;
          final visitedAt = timestamp.toDate();
  
          final name    = p['name']    as String? ?? '';
          final placeId = p['placeId'] as String? ?? '';
          final dayKey  = '${visitedAt.year}-${visitedAt.month}-${visitedAt.day}';
          final key     = placeId.isNotEmpty
              ? '${placeId}_$dayKey' : '${name}_$dayKey';
  
          if (!seenKeys.contains(key)) {
            seenKeys.add(key);
            placesVisited++;
            final address = p['address'] as String? ?? '';
            final city    = _extractCity(address);
            if (city.isNotEmpty) citySet.add(city);
  
            final primaryType = p['primaryType'] as String? ?? '';
            final category    = CategoryMapper.toAchievementCategory(primaryType);
            if (category == 'Food')       foodVisits++;
            if (category == 'Nature')     natureVisits++;
            if (category == 'Attraction') attractionVisits++;
  
            final lat = (p['lat'] as num?)?.toDouble();
            final lng = (p['lng'] as num?)?.toDouble();
            if (lat != null && lng != null) {
              byItineraryCoords.putIfAbsent(itineraryId, () => []);
              byItineraryCoords[itineraryId]!.add((lat: lat, lng: lng, visitedAt: visitedAt));
            }
          }
        }
      }
    }
  
    for (final group in byItineraryCoords.values) {
      group.sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
      for (int i = 0; i < group.length - 1; i++) {
        totalDistanceKm += _haversineKm(
          group[i].lat,     group[i].lng,
          group[i + 1].lat, group[i + 1].lng,
        );
      }
    }
  
    int tripsCompleted = 0;
    for (final doc in itinerariesDocs) {
      final data  = doc.data;
      final days  = data['days'] as List? ?? [];
      int total   = 0;
      int visited = 0;
      for (final day in days) {
        final places = (day as Map<String, dynamic>)['places'] as List? ?? [];
        total   += places.length;
        visited += places.where((p) =>
            (p as Map<String, dynamic>)['isVisited'] == true).length;
      }
      if (total > 0 && visited == total) tripsCompleted++;
    }
  
    final stats = AchievementStats(
      placesVisited:    placesVisited,
      citiesExplored:   citySet.length,
      tripsCompleted:   tripsCompleted,
      foodVisits:       foodVisits,
      natureVisits:     natureVisits,
      attractionVisits: attractionVisits,
      totalDistanceKm:  totalDistanceKm,
    );
  
    _cachedStats = stats;
    _cachedAt    = DateTime.now();
  
    return stats;
  }
    
    
  
  // ─────────────────────────────────────────────
  // Build AchievementGroups from stats
  // ─────────────────────────────────────────────
    List<AchievementGroup> buildGroups(AchievementStats s, [Map<String, DateTime>? unlockedDates]) {
      final dates = unlockedDates ?? const {};
      return [
        // ── Explorer (places visited) ──
        _group(
          id: 'explorer', baseEmoji: '📍', title: 'Explorer',
          unlockedDates: dates,
          tiers: [
            (level: 'bronze', emoji: '📍', label: 'Explorer I',   desc: 'Visit 10 places',  threshold: 10,  value: s.placesVisited),
            (level: 'silver', emoji: '🗺️', label: 'Explorer II',  desc: 'Visit 30 places',  threshold: 30,  value: s.placesVisited),
            (level: 'gold',   emoji: '🌏', label: 'Explorer III', desc: 'Visit 100 places', threshold: 100, value: s.placesVisited),
          ],
        ),

        // ── Foodie (food visits) ──
        _group(
          id: 'foodie', baseEmoji: '🍜', title: 'Foodie',
          unlockedDates: dates,
          tiers: [
            (level: 'bronze', emoji: '🍜', label: 'Foodie I',   desc: 'Visit 5 food spots',  threshold: 5,  value: s.foodVisits),
            (level: 'silver', emoji: '🍽️', label: 'Foodie II',  desc: 'Visit 15 food spots', threshold: 15, value: s.foodVisits),
            (level: 'gold',   emoji: '👨‍🍳', label: 'Foodie III', desc: 'Visit 50 food spots', threshold: 50, value: s.foodVisits),
          ],
        ),

        // ── Nature Lover (nature visits) ──
        _group(
          id: 'nature', baseEmoji: '🌿', title: 'Nature Lover',
          unlockedDates: dates,
          tiers: [
            (level: 'bronze', emoji: '🌿', label: 'Nature Lover I',   desc: 'Visit 5 nature spots',  threshold: 5,  value: s.natureVisits),
            (level: 'silver', emoji: '🌲', label: 'Nature Lover II',  desc: 'Visit 15 nature spots', threshold: 15, value: s.natureVisits),
            (level: 'gold',   emoji: '🏔️', label: 'Nature Lover III', desc: 'Visit 50 nature spots', threshold: 50, value: s.natureVisits),
          ],
        ),

        // ── History Buff (attraction visits) ──
        _group(
          id: 'history', baseEmoji: '🏛️', title: 'History Buff',
          unlockedDates: dates,
          tiers: [
            (level: 'bronze', emoji: '🏛️', label: 'History Buff I',   desc: 'Visit 5 attractions',  threshold: 5,  value: s.attractionVisits),
            (level: 'silver', emoji: '🗿', label: 'History Buff II',  desc: 'Visit 15 attractions', threshold: 15, value: s.attractionVisits),
            (level: 'gold',   emoji: '🏆', label: 'History Buff III', desc: 'Visit 50 attractions', threshold: 50, value: s.attractionVisits),
          ],
        ),

        // ── City Hopper (cities explored) ──
        _group(
          id: 'city', baseEmoji: '🏙️', title: 'City Hopper',
          unlockedDates: dates,
          tiers: [
            (level: 'bronze', emoji: '🏙️', label: 'City Hopper I',   desc: 'Explore 3 cities',  threshold: 3,  value: s.citiesExplored),
            (level: 'silver', emoji: '🌆', label: 'City Hopper II',  desc: 'Explore 10 cities', threshold: 10, value: s.citiesExplored),
            (level: 'gold',   emoji: '🌍', label: 'City Hopper III', desc: 'Explore 25 cities', threshold: 25, value: s.citiesExplored),
          ],
        ),

        // ── Traveller (completed itineraries) ──
        _group(
          id: 'traveller', baseEmoji: '✈️', title: 'Traveller',
          unlockedDates: dates,
          tiers: [
            (level: 'bronze', emoji: '✈️', label: 'Traveller I',   desc: 'Complete 1 itinerary',  threshold: 1,  value: s.tripsCompleted),
            (level: 'silver', emoji: '🧳', label: 'Traveller II',  desc: 'Complete 5 itineraries', threshold: 5,  value: s.tripsCompleted),
            (level: 'gold',   emoji: '🌐', label: 'Traveller III', desc: 'Complete 15 itineraries', threshold: 15, value: s.tripsCompleted),
          ],
        ),

        // ── Road Warrior (distance km) ──
        _group(
          id: 'road', baseEmoji: '🚀', title: 'Road Warrior',
          unlockedDates: dates,
          tiers: [
            (level: 'bronze', emoji: '🛵', label: 'Road Warrior I',   desc: 'Travel 50 km',   threshold: 50,  value: s.totalDistanceKm.toInt()),
            (level: 'silver', emoji: '🚗', label: 'Road Warrior II',  desc: 'Travel 200 km',  threshold: 200, value: s.totalDistanceKm.toInt()),
            (level: 'gold',   emoji: '🚀', label: 'Road Warrior III', desc: 'Travel 1000 km', threshold: 1000, value: s.totalDistanceKm.toInt()),
          ],
        ),
      ];
    }
  
  // ─────────────────────────────────────────────
  // Check for new unlocks (call after a check-in)
  //
  // Pass in the groups computed BEFORE the check-in (oldGroups)
  // and AFTER (newGroups). Returns a list of newly unlocked tiers.
  // ─────────────────────────────────────────────

  List<NewUnlock> checkForNewUnlocks({
    required List<AchievementGroup> oldGroups,
    required List<AchievementGroup> newGroups,
  }) {
    final newUnlocks = <NewUnlock>[];

    for (int g = 0; g < oldGroups.length && g < newGroups.length; g++) {
      final oldGroup = oldGroups[g];
      final newGroup = newGroups[g];

      for (int t = 0; t < oldGroup.tiers.length && t < newGroup.tiers.length; t++) {
        final wasUnlocked = oldGroup.tiers[t].unlocked;
        final isNowUnlocked = newGroup.tiers[t].unlocked;

        if (!wasUnlocked && isNowUnlocked) {
          newUnlocks.add(NewUnlock(
            groupTitle: newGroup.title,
            tier: newGroup.tiers[t],
          ));
        }
      }
    }

    return newUnlocks;
  }

  // ─────────────────────────────────────────────
  // Save top badge to Firestore users/{uid}
  //
  // Called after every check-in (regardless of whether that specific
  // check-in unlocked something new) so post cards can display the badge
  // without extra Firestore reads.
  //
  // FIX: previously used .update(), which throws if the users/{uid}
  // document doesn't exist yet — that failure was silent (no try/catch),
  // so topBadgeEmoji/Label/Level could end up permanently missing.
  // Now uses set(merge: true), which creates-or-merges safely, and any
  // unexpected error is at least logged instead of swallowed.
  // ─────────────────────────────────────────────

  Future<void> saveTopBadgeToFirestore() async {
    final uid = _uid;
    if (uid == null) return;

    try {
      final tier = await fetchTopBadge();
      final data = tier == null
          ? {
              'topBadgeEmoji': null,
              'topBadgeLabel': null,
              'topBadgeLevel': null,
            }
          : {
              'topBadgeEmoji': tier.emoji,
              'topBadgeLabel': tier.label,
              'topBadgeLevel': tier.level,
            };

      await _db
          .collection('users')
          .doc(uid)
          .set(data, SetOptions(merge: true));
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('AchievementService.saveTopBadgeToFirestore failed: $e');
      }
    }
  }

  Map<String, DateTime>? _cachedUnlockedDates;

  Future<Map<String, DateTime>> _loadUnlockedDates({bool forceRefresh = false}) async {
    final uid = _uid;
    if (uid == null) return {};
    if (!forceRefresh && _cachedUnlockedDates != null) return _cachedUnlockedDates!;

    try {
      final doc = await _db.collection('users').doc(uid).get();
      final raw = doc.data()?['unlockedBadges'] as Map<String, dynamic>? ?? {};
      final dates = <String, DateTime>{};
      raw.forEach((k, v) {
        if (v is Timestamp) dates[k] = v.toDate();
      });
      _cachedUnlockedDates = dates;
      return dates;
    } catch (e) {
      if (kDebugMode) print('AchievementService._loadUnlockedDates failed: $e');
      return {};
    }
  }

  Future<void> _saveUnlockedDates(Map<String, DateTime> newDates) async {
    final uid = _uid;
    if (uid == null || newDates.isEmpty) return;

    try {
      final data = <String, dynamic>{};
      newDates.forEach((key, date) {
        data['unlockedBadges.$key'] = Timestamp.fromDate(date);   // 点号路径，只补新 key，不覆盖旧的
      });
      await _db.collection('users').doc(uid).set(data, SetOptions(merge: true));
      _cachedUnlockedDates = {...?_cachedUnlockedDates, ...newDates};
    } catch (e) {
      if (kDebugMode) print('AchievementService._saveUnlockedDates failed: $e');
    }
  }


  // ─────────────────────────────────────────────
  // Convenience: fetch stats + build groups in one call
  // ─────────────────────────────────────────────

  Future<List<AchievementGroup>> fetchGroups({bool forceRefresh = false}) async {
    final stats         = await fetchStats(forceRefresh: forceRefresh);
    final unlockedDates = await _loadUnlockedDates(forceRefresh: forceRefresh);
    final groups        = buildGroups(stats, unlockedDates);

    // 找出「已解锁但还没记录时间」的 tier，用当前时间补一条记录
    final newlyRecorded = <String, DateTime>{};
    final now = DateTime.now();
    for (final group in groups) {
      for (final tier in group.tiers) {
        final key = '${group.id}_${tier.level}';
        if (tier.unlocked && !unlockedDates.containsKey(key)) {
          newlyRecorded[key] = now;
        }
      }
    }

    if (newlyRecorded.isNotEmpty) {
      await _saveUnlockedDates(newlyRecorded);
      // 把刚补上的日期直接贴回这次返回的结果，不用重新查一次
      for (final group in groups) {
        for (int i = 0; i < group.tiers.length; i++) {
          final tier = group.tiers[i];
          final key  = '${group.id}_${tier.level}';
          if (newlyRecorded.containsKey(key)) {
            group.tiers[i] = tier.copyWith(unlockedAt: newlyRecorded[key]);
          }
        }
      }
    }

    return groups;
  }

  // ─────────────────────────────────────────────
  // Badge for post/profile — returns the highest unlocked tier
  // across ALL groups, or null if user has unlocked nothing yet.
  // "Highest" = gold > silver > bronze, and within same level,
  // the group that appears last in buildGroups() wins (arbitrary
  // but deterministic).
  // ─────────────────────────────────────────────

  Future<AchievementTier?> fetchTopBadge() async {
    final groups = await fetchGroups();
    AchievementTier? top;
    const levelRank = {'bronze': 1, 'silver': 2, 'gold': 3};

    for (final group in groups) {
      final highest = group.highestUnlocked;
      if (highest == null) continue;
      if (top == null) {
        top = highest;
      } else {
        final topRank = levelRank[top.level] ?? 0;
        final newRank = levelRank[highest.level] ?? 0;
        if (newRank > topRank) top = highest;
      }
    }
    return top;
  }

  // ─────────────────────────────────────────────
  // All unlocked tiers (for profile badge row)
  // Returns one tier per group — the highest unlocked.
  // ─────────────────────────────────────────────

  Future<List<AchievementTier>> fetchUnlockedBadges() async {
    final groups = await fetchGroups();
    return groups
        .map((g) => g.highestUnlocked)
        .whereType<AchievementTier>()
        .toList();
  }

  // ─────────────────────────────────────────────
  // Private helpers
  // ─────────────────────────────────────────────

  AchievementGroup _group({
    required String id,
    required String baseEmoji,
    required String title,
    required List<({String level, String emoji, String label, String desc, int threshold, int value})> tiers,
    required Map<String, DateTime> unlockedDates,   // ★ 新增
  }) {
    return AchievementGroup(
      id: id, baseEmoji: baseEmoji, title: title,
      tiers: tiers.map((t) {
        final unlocked = t.value >= t.threshold;
        final key = '${id}_${t.level}';               // ★ 新增
        return AchievementTier(
          level: t.level, emoji: t.emoji, label: t.label, desc: t.desc,
          threshold: t.threshold,
          unlocked: unlocked,
          currentValue: t.value,
          unlockedAt: unlocked ? unlockedDates[key] : null,   // ★ 新增
        );
      }).toList(),
    );
}

  AchievementStats _emptyStats() => const AchievementStats(
    placesVisited:    0,
    citiesExplored:   0,
    tripsCompleted:   0,
    foodVisits:       0,
    natureVisits:     0,
    attractionVisits: 0,
    totalDistanceKm:  0,
  );

  Future<List<UnlockedBadge>> fetchAllUnlockedBadges({bool forceRefresh = false}) async {
  final groups = await AchievementService.instance.fetchGroups();  // ✅
  final result = <UnlockedBadge>[];
  for (final g in groups) {
    for (final t in g.tiers) {
      if (t.unlocked) result.add(UnlockedBadge(groupTitle: g.title, tier: t));
    }
  }
  result.sort((a, b) {
    final ad = a.tier.unlockedAt, bd = b.tier.unlockedAt;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return bd.compareTo(ad); // 新的在前
  });
  return result;
}

  
}

class UnlockedBadge {
  final String groupTitle;
  final AchievementTier tier;
  const UnlockedBadge({required this.groupTitle, required this.tier});
}


