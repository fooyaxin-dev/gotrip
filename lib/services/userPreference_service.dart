// services/user_preference_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Budget tier  (set during onboarding)
// ─────────────────────────────────────────────────────────────────────────────

enum BudgetTier { budget, midRange, premium }

extension BudgetTierX on BudgetTier {
  String get label {
    switch (this) {
      case BudgetTier.budget:   return 'Budget';
      case BudgetTier.midRange: return 'Mid-range';
      case BudgetTier.premium:  return 'Premium';
    }
  }

  String get description {
    switch (this) {
      case BudgetTier.budget:   return 'Affordable spots & local eats';
      case BudgetTier.midRange: return 'A balance of comfort & value';
      case BudgetTier.premium:  return 'Top-rated & high-end experiences';
    }
  }

  String toJson() => name; // 'budget' | 'midRange' | 'premium'

  static BudgetTier fromJson(String? s) {
    switch (s) {
      case 'midRange': return BudgetTier.midRange;
      case 'premium':  return BudgetTier.premium;
      default:         return BudgetTier.budget;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class UserPreferences {
  final List<String> categories;
  final List<String> cuisines;
  final String       travelMode;
  final BudgetTier   budgetTier; 
  final bool         onboardingDone;

  UserPreferences({
    required this.categories,
    required this.cuisines,
    required this.travelMode,
    required this.budgetTier,
    required this.onboardingDone,
  });

  factory UserPreferences.empty() => UserPreferences(
    categories:     [],
    cuisines:       [],
    travelMode:     'walk',
    budgetTier:     BudgetTier.budget,
    onboardingDone: false,
  );

  factory UserPreferences.fromMap(Map<String, dynamic> map) {
    final prefs = map['preferences'] as Map<String, dynamic>? ?? {};
    return UserPreferences(
      categories:     List<String>.from(prefs['categories'] ?? []),
      cuisines:       List<String>.from(prefs['cuisines']   ?? []),
      travelMode:     prefs['travelMode']  as String? ?? 'walk',
      budgetTier:     BudgetTierX.fromJson(prefs['budgetTier'] as String?),
      onboardingDone: map['onboardingDone'] as bool?  ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
    'onboardingDone': true,
    'preferences': {
      'categories': categories,
      'cuisines':   cuisines,
      'travelMode': travelMode,
      'budgetTier': budgetTier.toJson(),
    },
  };

  UserPreferences copyWith({
    List<String>? categories,
    List<String>? cuisines,
    String?       travelMode,
    BudgetTier?   budgetTier,
    bool?         onboardingDone,
  }) => UserPreferences(
    categories:     categories     ?? this.categories,
    cuisines:       cuisines       ?? this.cuisines,
    travelMode:     travelMode     ?? this.travelMode,
    budgetTier:     budgetTier     ?? this.budgetTier,
    onboardingDone: onboardingDone ?? this.onboardingDone,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Score breakdown object
// ─────────────────────────────────────────────────────────────────────────────

class RecommendationScore {
  final double total;
  final double interestMatch;
  final double distanceScore;
  final double ratingScore;
  final double timeSuitability;
  final double budgetSuitability;

  const RecommendationScore({
    required this.total,
    required this.interestMatch,
    required this.distanceScore,
    required this.ratingScore,
    required this.timeSuitability,
    required this.budgetSuitability,
  });

  String get percentage => '${(total * 100).toStringAsFixed(1)}%';

  @override
  String toString() =>
      'Score=${percentage} '
      '[interest=${(interestMatch  * 100).toStringAsFixed(0)}% '
      'dist=${(distanceScore       * 100).toStringAsFixed(0)}% '
      'rating=${(ratingScore       * 100).toStringAsFixed(0)}% '
      'time=${(timeSuitability     * 100).toStringAsFixed(0)}% '
      'budget=${(budgetSuitability * 100).toStringAsFixed(0)}%]';
}

// ─────────────────────────────────────────────────────────────────────────────

class UserPreferenceService {
  static final UserPreferenceService instance = UserPreferenceService._();
  UserPreferenceService._();

  UserPreferences _prefs = UserPreferences.empty();
  UserPreferences get current => _prefs;

  final ValueNotifier<int> preferencesChanged = ValueNotifier(0);

  final Map<String, int> _favouriteCount = {};

  // Hard gate: category/cuisine must be favourited ≥3 times
  // before it enters _prefs.categories / _prefs.cuisines.
  // After that, the raw count still accumulates and boosts the score further.
  static const int _minCountToLearn = 3;

  // ─────────────────────────────────────────────
  // Load
  // ─────────────────────────────────────────────

  Future<UserPreferences> load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return UserPreferences.empty();
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(uid).get();
      if (!doc.exists) return UserPreferences.empty();

      _prefs = UserPreferences.fromMap(doc.data()!);

      final countMap =
          doc.data()!['favouriteTypeCounts'] as Map<String, dynamic>? ?? {};
      _favouriteCount.clear();
      countMap.forEach((k, v) => _favouriteCount[k] = (v as num).toInt());

      return _prefs;
    } catch (e) {
      print('❌ UserPreferenceService.load: $e');
      return UserPreferences.empty();
    }
  }

  // ─────────────────────────────────────────────
  // Save
  // ─────────────────────────────────────────────

  Future<void> save(UserPreferences prefs) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _prefs = prefs;
    await FirebaseFirestore.instance
        .collection('users').doc(uid).update(prefs.toMap());
    preferencesChanged.value++;
  }

  // ─────────────────────────────────────────────
  // Reset
  // ─────────────────────────────────────────────

  Future<void> reset() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _prefs = UserPreferences.empty().copyWith(onboardingDone: true);
    _favouriteCount.clear();
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'preferences': {
        'categories': [],
        'cuisines':   [],
        'travelMode': 'walk',
        'budgetTier': 'budget',
      },
      'favouriteTypeCounts': {},
    });
    preferencesChanged.value++;
  }

  // ─────────────────────────────────────────────
  // Update from favourite
  // ─────────────────────────────────────────────

  Future<void> updateFromFavourite({
    required String       primaryType,
    required List<String> allTypes,
    required bool         isFavouriting,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    const typeToCategory = {
      'restaurant':         'restaurant',
      'park':               'park',
      'tourist_attraction': 'tourist_attraction',
      'shopping_mall':      'shopping_mall',
      'amusement_park':     'amusement_park',
    };
    const typeToCuisine = {
      'chinese_restaurant':   'chinese',
      'malay_restaurant':     'malay',
      'malaysian_restaurant': 'malay',
      'indian_restaurant':    'indian',
      'western_restaurant':   'western',
      'american_restaurant':  'western',
      'japanese_restaurant':  'japanese',
      'korean_restaurant':    'korean',
      'dessert_shop':         'dessert',
      'ice_cream_shop':       'dessert',
      'bakery':               'dessert',
      'cafe':                 'cafe',
      'coffee_shop':          'cafe',
    };

    final List<String> involvedKeys = [];
    final category = typeToCategory[primaryType];
    if (category != null) involvedKeys.add('cat_$category');
    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null) involvedKeys.add('cui_$cuisine');
    }
    if (involvedKeys.isEmpty) return;

    for (final key in involvedKeys) {
      if (isFavouriting) {
        _favouriteCount[key] = (_favouriteCount[key] ?? 0) + 1;
      } else {
        _favouriteCount[key] =
            ((_favouriteCount[key] ?? 0) - 1).clamp(0, 999);
      }
    }

    // ── Gate: only promote to _prefs once count >= 3 ──
    final updatedCategories = List<String>.from(_prefs.categories);
    final updatedCuisines   = List<String>.from(_prefs.cuisines);

    for (final entry in _favouriteCount.entries) {
      final key   = entry.key;
      final count = entry.value;

      if (key.startsWith('cat_')) {
        final cat = key.substring(4);
        if (count >= _minCountToLearn && !updatedCategories.contains(cat)) {
          updatedCategories.add(cat);
        } else if (count < _minCountToLearn) {
          updatedCategories.remove(cat);
        }
      }
      if (key.startsWith('cui_')) {
        final cui = key.substring(4);
        if (count >= _minCountToLearn && !updatedCuisines.contains(cui)) {
          updatedCuisines.add(cui);
        } else if (count < _minCountToLearn) {
          updatedCuisines.remove(cui);
        }
      }
    }

    _prefs = _prefs.copyWith(
      categories: updatedCategories,
      cuisines:   updatedCuisines,
    );

    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'preferences': {
        'categories': updatedCategories,
        'cuisines':   updatedCuisines,
        'travelMode': _prefs.travelMode,
        'budgetTier': _prefs.budgetTier.toJson(),
      },
      'favouriteTypeCounts': _favouriteCount,
    });
  }

  // ═════════════════════════════════════════════════════════════════════════
  //
  //  RECOMMENDATION SCORE
  //
  //  Score = 0.35 × InterestMatch
  //        + 0.25 × DistanceScore
  //        + 0.20 × RatingScore
  //        + 0.10 × TimeSuitability
  //        + 0.10 × BudgetSuitability
  //
  // ═════════════════════════════════════════════════════════════════════════

  RecommendationScore recommendationScore({
    required String?      primaryType,
    required List<String> allTypes,
    required double?      rating,
    required double?      distanceMeters,
    required int?         priceLevel,
  }) {
    final interest = _interestMatchScore(primaryType, allTypes);
    final distance = _distanceScore(distanceMeters);
    final ratingS  = _ratingScore(rating);
    final time     = _timeSuitabilityScore(primaryType, allTypes);
    final budget   = _budgetSuitabilityScore(priceLevel);

    final total = (0.35 * interest
                 + 0.25 * distance
                 + 0.20 * ratingS
                 + 0.10 * time
                 + 0.10 * budget).clamp(0.0, 1.0);

    return RecommendationScore(
      total:             total,
      interestMatch:     interest,
      distanceScore:     distance,
      ratingScore:       ratingS,
      timeSuitability:   time,
      budgetSuitability: budget,
    );
  }

  // ─────────────────────────────────────────────
  // 1. Interest Match (0.35)
  //
  // Gate: category/cuisine must reach ≥3 favourites to unlock.
  // Once unlocked, count continues to boost the score:
  //
  //   count < 3   → 0.0  (not unlocked yet)
  //   count = 3   → 0.6  (just unlocked)
  //   count = 5   → 0.8
  //   count = 10+ → 1.0  (loyal fan)
  //
  // Also checks onboarding category/cuisine (binary 1.0 if match).
  // Final score = average of all matched signals.
  // ─────────────────────────────────────────────

  double _interestMatchScore(String? primaryType, List<String> allTypes) {
    const typeToCategory = {
      'restaurant':         'restaurant',
      'park':               'park',
      'tourist_attraction': 'tourist_attraction',
      'shopping_mall':      'shopping_mall',
      'amusement_park':     'amusement_park',
    };
    const typeToCuisine = {
      'chinese_restaurant':   'chinese',
      'malay_restaurant':     'malay',
      'malaysian_restaurant': 'malay',
      'indian_restaurant':    'indian',
      'western_restaurant':   'western',
      'american_restaurant':  'western',
      'japanese_restaurant':  'japanese',
      'korean_restaurant':    'korean',
      'dessert_shop':         'dessert',
      'ice_cream_shop':       'dessert',
      'bakery':               'dessert',
      'cafe':                 'cafe',
      'coffee_shop':          'cafe',
    };

    // Converts a favourite count → 0.0–1.0
    // Below gate → 0.0.  At gate → 0.6.  Max (10) → 1.0.
    double countToScore(int count) {
      if (count < _minCountToLearn) return 0.0;
      // Linear from 0.6 at count=3 to 1.0 at count=10
      const maxCount = 10;
      final clamped  = count.clamp(_minCountToLearn, maxCount);
      return 0.6 + 0.4 * (clamped - _minCountToLearn) / (maxCount - _minCountToLearn);
    }

    final scores  = <double>[];

    // ── Category signal ──
    final category = typeToCategory[primaryType ?? ''];
    if (category != null) {
      // Onboarding match
      if (_prefs.categories.contains(category)) scores.add(1.0);
      // Favourite count boost (additive signal)
      final cnt = _favouriteCount['cat_$category'] ?? 0;
      final cs  = countToScore(cnt);
      if (cs > 0) scores.add(cs);
    }

    // ── Cuisine signal ──
    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null) {
        if (_prefs.cuisines.contains(cuisine)) scores.add(1.0);
        final cnt = _favouriteCount['cui_$cuisine'] ?? 0;
        final cs  = countToScore(cnt);
        if (cs > 0) scores.add(cs);
        break; // one cuisine signal per place
      }
    }

    if (scores.isEmpty) return 0.5; // no signal → neutral
    return (scores.reduce((a, b) => a + b) / scores.length).clamp(0.0, 1.0);
  }

  // ─────────────────────────────────────────────
  // 2. Distance Score (0.25)
  //
  // Linear decay:  0 m → 1.0,  5 km → 0.0
  // ─────────────────────────────────────────────

  double _distanceScore(double? distanceMeters) {
    if (distanceMeters == null || distanceMeters <= 0) return 0.5;
    return (1.0 - distanceMeters / 5000.0).clamp(0.0, 1.0);
  }

  // ─────────────────────────────────────────────
  // 3. Rating Score (0.20)
  //
  // (rating - 2.0) / 3.0
  // 2.0 → 0.0 | 3.5 → 0.50 | 4.5 → 0.83 | 5.0 → 1.0
  // ─────────────────────────────────────────────

  double _ratingScore(double? rating) { 
    if (rating == null) return 0.5;
    return ((rating - 2.0) / 3.0).clamp(0.0, 1.0);
  }

  // ─────────────────────────────────────────────
  // 4. Time Suitability (0.10)
  // ─────────────────────────────────────────────

  double _timeSuitabilityScore(String? primaryType, List<String> allTypes) {
    final hour = DateTime.now().hour;

    const suitability = <String, Map<String, double>>{
      'morning':   {'cafe': 1.0, 'restaurant': 0.6, 'park': 0.8, 'tourist_attraction': 0.7},
      'lunch':     {'restaurant': 1.0, 'cafe': 0.5, 'shopping_mall': 0.4},
      'afternoon': {'tourist_attraction': 1.0, 'park': 1.0, 'shopping_mall': 0.9, 'amusement_park': 0.8, 'restaurant': 0.3},
      'evening':   {'restaurant': 1.0, 'shopping_mall': 0.7, 'amusement_park': 0.8},
      'night':     {'amusement_park': 1.0, 'restaurant': 0.7},
    };

    final String period;
    if      (hour >= 6  && hour < 11) period = 'morning';
    else if (hour >= 11 && hour < 14) period = 'lunch';
    else if (hour >= 14 && hour < 17) period = 'afternoon';
    else if (hour >= 17 && hour < 20) period = 'evening';
    else                               period = 'night';

    final map = suitability[period]!;
    if (primaryType != null && map.containsKey(primaryType)) return map[primaryType]!;
    for (final t in allTypes) {
      if (map.containsKey(t)) return map[t]!;
    }
    return 0.3;
  }

  // ─────────────────────────────────────────────
  // 5. Budget Suitability (0.10)
  //
  // Uses user's budgetTier (set in onboarding) vs Google priceLevel 1–4
  //
  //              PL1   PL2   PL3   PL4
  // budget       1.0   0.8   0.3   0.0
  // mid-range    0.6   1.0   1.0   0.5
  // premium      0.2   0.6   1.0   1.0
  // ─────────────────────────────────────────────

  double _budgetSuitabilityScore(int? priceLevel) {
    if (priceLevel == null) return 1.0; // unknown → don't penalize

    const scores = <String, List<double>>{
      //           PL1   PL2   PL3   PL4
      'budget':   [1.0,  0.8,  0.3,  0.0],
      'midRange': [0.6,  1.0,  1.0,  0.5],
      'premium':  [0.2,  0.6,  1.0,  1.0],
    };

    final tier = _prefs.budgetTier.toJson(); // 'budget' | 'midRange' | 'premium'
    final idx  = (priceLevel - 1).clamp(0, 3);
    return scores[tier]![idx];
  }

  // ─────────────────────────────────────────────
  // Legacy — keeps existing call sites working
  // ─────────────────────────────────────────────

  double scorePlaceModel({
    required String?      primaryType,
    required List<String> allTypes,
    double?               distanceMeters,
    double?               rating,
    int?                  priceLevel,
  }) =>
      recommendationScore(
        primaryType:    primaryType,
        allTypes:       allTypes,
        rating:         rating,
        distanceMeters: distanceMeters,
        priceLevel:     priceLevel,
      ).total;

  // ─────────────────────────────────────────────
  // Recommend reason  (unchanged)
  // ─────────────────────────────────────────────

  String? getRecommendReason({
    required String?      primaryType,
    required List<String> allTypes,
  }) {
    const typeToCuisine = {
      'chinese_restaurant': 'Chinese', 'malay_restaurant': 'Malay',
      'malaysian_restaurant': 'Malay', 'indian_restaurant': 'Indian',
      'western_restaurant': 'Western', 'american_restaurant': 'Western',
      'japanese_restaurant': 'Japanese', 'korean_restaurant': 'Korean',
      'dessert_shop': 'Dessert', 'ice_cream_shop': 'Dessert',
      'bakery': 'Dessert', 'cafe': 'Cafe', 'coffee_shop': 'Cafe',
    };
    const typeToCategory  = {
      'restaurant': 'restaurant', 'park': 'park',
      'tourist_attraction': 'tourist_attraction',
      'shopping_mall': 'shopping_mall', 'amusement_park': 'amusement_park',
    };
    const categoryToLabel = {
      'restaurant': 'Food', 'park': 'Nature',
      'tourist_attraction': 'Historical places',
      'shopping_mall': 'Shopping', 'amusement_park': 'Entertainment',
    };

    final hour = DateTime.now().hour;
    if (hour >= 6  && hour < 11 &&
        (primaryType == 'cafe' ||
         allTypes.any((t) => t == 'cafe' || t == 'coffee_shop'))) {
      return 'Good morning ☕ Start your day here';
    }
    if (hour >= 11 && hour < 14 && primaryType == 'restaurant') {
      return 'Lunch time 🍽️ Try this place';
    }
    if (hour >= 17 && hour < 20 && primaryType == 'restaurant') {
      return 'Dinner time 🌆 Great for tonight';
    }
    if ((hour >= 20 || hour < 2) && primaryType == 'amusement_park') {
      return 'Night out 🌙 Fun nearby';
    }

    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null && _prefs.cuisines.contains(cuisine.toLowerCase())) {
        return 'Because you like $cuisine food';
      }
    }
    final category = typeToCategory[primaryType ?? ''];
    if (category != null && _prefs.categories.contains(category)) {
      return 'Because you like ${categoryToLabel[category] ?? category}';
    }
    return null;
  }

}