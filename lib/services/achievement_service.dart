// services/achievement_service.dart
//
// Single source of truth for all achievement logic.
// Used by:
//   - dashboard_page.dart   (full grid display)
//   - profileInfo.dart      (compact badge row)
//   - itineraryDetail.dart  (unlock detection on check-in)
//   - interactionPage.dart  (badge next to username in posts)
//   - addPost.dart          (badge next to username when posting)

import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

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

  const AchievementTier({
    required this.level,
    required this.emoji,
    required this.label,
    required this.desc,
    required this.threshold,
    required this.unlocked,
    required this.currentValue,
  });

  /// Progress towards this tier: 0.0 – 1.0
  double get progress => unlocked
      ? 1.0
      : (currentValue / threshold).clamp(0.0, 1.0);

  /// How many more units the user needs to unlock this tier.
  int get remaining => unlocked ? 0 : (threshold - currentValue).clamp(0, threshold);
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

  static String _typeToCategory(String primaryType) {
    if (_kFoodTypes.contains(primaryType))       return 'Food';
    if (_kNatureTypes.contains(primaryType))     return 'Nature';
    if (_kAttractionTypes.contains(primaryType)) return 'Attraction';
    return 'Other';
  }

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
  // ─────────────────────────────────────────────

  Future<AchievementStats> fetchStats() async {
    final uid = _uid;
    if (uid == null) return _emptyStats();

    final results = await Future.wait([
      _db.collection('users').doc(uid).collection('history').get(),
      _db.collection('users').doc(uid).collection('itineraries').get(),
    ]);

    final historySnap     = results[0] as QuerySnapshot;
    final itinerariesSnap = results[1] as QuerySnapshot;

    // ── Build deduped visit events ──
    final seenKeys  = <String>{};
    int placesVisited    = 0;
    int foodVisits       = 0;
    int natureVisits     = 0;
    int attractionVisits = 0;
    double totalDistanceKm = 0;
    final citySet = <String>{};

    // 1) History
    for (final doc in historySnap.docs) {
      final data      = doc.data() as Map<String, dynamic>;
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
      // History doesn't store primaryType directly — category counted via
      // itinerary visits below which do have primaryType.
    }

    // 2) Itinerary visited places (also contribute category + distance)
    for (final doc in itinerariesSnap.docs) {
      final data = doc.data() as Map<String, dynamic>;
      final days = data['days'] as List? ?? [];

      final orderedVisits = <({double lat, double lng, DateTime visitedAt})>[];

      for (final day in days) {
        final places = (day as Map<String, dynamic>)['places'] as List? ?? [];
        for (final place in places) {
          final p         = place as Map<String, dynamic>;
          final isVisited = p['isVisited'] as bool? ?? false;
          if (!isVisited) continue;

          final timestamp = p['visitedAt'] as Timestamp?;
          if (timestamp == null) continue;
          final visitedAt = timestamp.toDate();

          final name    = p['name']        as String? ?? '';
          final placeId = p['placeId']     as String? ?? '';
          final dayKey  = '${visitedAt.year}-${visitedAt.month}-${visitedAt.day}';
          final key     = placeId.isNotEmpty
              ? '${placeId}_$dayKey' : '${name}_$dayKey';

          // Count place if not already counted from history
          if (!seenKeys.contains(key)) {
            seenKeys.add(key);
            placesVisited++;
            final address = p['address'] as String? ?? '';
            final city    = _extractCity(address);
            if (city.isNotEmpty) citySet.add(city);
          }

          // Category counts (using primaryType which only itineraries store)
          final primaryType = p['primaryType'] as String? ?? '';
          final category    = _typeToCategory(primaryType);
          if (category == 'Food')       foodVisits++;
          if (category == 'Nature')     natureVisits++;
          if (category == 'Attraction') attractionVisits++;

          // Collect coordinates for distance calculation
          final lat = (p['lat'] as num?)?.toDouble();
          final lng = (p['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            orderedVisits.add((lat: lat, lng: lng, visitedAt: visitedAt));
          }
        }
      }

      // Sum haversine between consecutive stops within this itinerary
      orderedVisits.sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
      for (int i = 0; i < orderedVisits.length - 1; i++) {
        totalDistanceKm += _haversineKm(
          orderedVisits[i].lat,     orderedVisits[i].lng,
          orderedVisits[i + 1].lat, orderedVisits[i + 1].lng,
        );
      }
    }

    // ── Completed trips ──
    int tripsCompleted = 0;
    for (final doc in itinerariesSnap.docs) {
      final data  = doc.data() as Map<String, dynamic>;
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

    return AchievementStats(
      placesVisited:    placesVisited,
      citiesExplored:   citySet.length,
      tripsCompleted:   tripsCompleted,
      foodVisits:       foodVisits,
      natureVisits:     natureVisits,
      attractionVisits: attractionVisits,
      totalDistanceKm:  totalDistanceKm,
    );
  }

  // ─────────────────────────────────────────────
  // Build AchievementGroups from stats
  // ─────────────────────────────────────────────

  List<AchievementGroup> buildGroups(AchievementStats s) {
    return [
      // ── Explorer (places visited) ──
      _group(
        id: 'explorer', baseEmoji: '📍', title: 'Explorer',
        tiers: [
          (level: 'bronze', emoji: '📍', label: 'Explorer I',   desc: 'Visit 10 places',  threshold: 10,  value: s.placesVisited),
          (level: 'silver', emoji: '🗺️', label: 'Explorer II',  desc: 'Visit 30 places',  threshold: 30,  value: s.placesVisited),
          (level: 'gold',   emoji: '🌏', label: 'Explorer III', desc: 'Visit 100 places', threshold: 100, value: s.placesVisited),
        ],
      ),

      // ── Foodie (food visits) ──
      _group(
        id: 'foodie', baseEmoji: '🍜', title: 'Foodie',
        tiers: [
          (level: 'bronze', emoji: '🍜', label: 'Foodie I',   desc: 'Visit 5 food spots',  threshold: 5,  value: s.foodVisits),
          (level: 'silver', emoji: '🍽️', label: 'Foodie II',  desc: 'Visit 15 food spots', threshold: 15, value: s.foodVisits),
          (level: 'gold',   emoji: '👨‍🍳', label: 'Foodie III', desc: 'Visit 50 food spots', threshold: 50, value: s.foodVisits),
        ],
      ),

      // ── Nature Lover (nature visits) ──
      _group(
        id: 'nature', baseEmoji: '🌿', title: 'Nature Lover',
        tiers: [
          (level: 'bronze', emoji: '🌿', label: 'Nature Lover I',   desc: 'Visit 5 nature spots',  threshold: 5,  value: s.natureVisits),
          (level: 'silver', emoji: '🌲', label: 'Nature Lover II',  desc: 'Visit 15 nature spots', threshold: 15, value: s.natureVisits),
          (level: 'gold',   emoji: '🏔️', label: 'Nature Lover III', desc: 'Visit 50 nature spots', threshold: 50, value: s.natureVisits),
        ],
      ),

      // ── History Buff (attraction visits) ──
      _group(
        id: 'history', baseEmoji: '🏛️', title: 'History Buff',
        tiers: [
          (level: 'bronze', emoji: '🏛️', label: 'History Buff I',   desc: 'Visit 5 attractions',  threshold: 5,  value: s.attractionVisits),
          (level: 'silver', emoji: '🗿', label: 'History Buff II',  desc: 'Visit 15 attractions', threshold: 15, value: s.attractionVisits),
          (level: 'gold',   emoji: '🏆', label: 'History Buff III', desc: 'Visit 50 attractions', threshold: 50, value: s.attractionVisits),
        ],
      ),

      // ── City Hopper (cities explored) ──
      _group(
        id: 'city', baseEmoji: '🏙️', title: 'City Hopper',
        tiers: [
          (level: 'bronze', emoji: '🏙️', label: 'City Hopper I',   desc: 'Explore 3 cities',  threshold: 3,  value: s.citiesExplored),
          (level: 'silver', emoji: '🌆', label: 'City Hopper II',  desc: 'Explore 10 cities', threshold: 10, value: s.citiesExplored),
          (level: 'gold',   emoji: '🌍', label: 'City Hopper III', desc: 'Explore 25 cities', threshold: 25, value: s.citiesExplored),
        ],
      ),

      // ── Traveller (completed itineraries) ──
      _group(
        id: 'traveller', baseEmoji: '✈️', title: 'Traveller',
        tiers: [
          (level: 'bronze', emoji: '✈️', label: 'Traveller I',   desc: 'Complete 1 itinerary',  threshold: 1,  value: s.tripsCompleted),
          (level: 'silver', emoji: '🧳', label: 'Traveller II',  desc: 'Complete 5 itineraries', threshold: 5,  value: s.tripsCompleted),
          (level: 'gold',   emoji: '🌐', label: 'Traveller III', desc: 'Complete 15 itineraries', threshold: 15, value: s.tripsCompleted),
        ],
      ),

      // ── Road Warrior (distance km) ──
      _group(
        id: 'road', baseEmoji: '🚀', title: 'Road Warrior',
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
  // Called after every check-in so post cards can
  // display the badge without extra Firestore reads.
  // ─────────────────────────────────────────────

  Future<void> saveTopBadgeToFirestore() async {
    final uid = _uid;
    if (uid == null) return;

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

    await _db.collection('users').doc(uid).update(data);
  }

  // ─────────────────────────────────────────────
  // Convenience: fetch stats + build groups in one call
  // ─────────────────────────────────────────────

  Future<List<AchievementGroup>> fetchGroups() async {
    final stats = await fetchStats();
    return buildGroups(stats);
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
  }) {
    return AchievementGroup(
      id:        id,
      baseEmoji: baseEmoji,
      title:     title,
      tiers: tiers.map((t) => AchievementTier(
        level:        t.level,
        emoji:        t.emoji,
        label:        t.label,
        desc:         t.desc,
        threshold:    t.threshold,
        unlocked:     t.value >= t.threshold,
        currentValue: t.value,
      )).toList(),
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
}