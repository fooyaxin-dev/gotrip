// services/user_preference_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class UserPreferences {
  final List<String> categories;
  final List<String> cuisines;
  final String travelMode;
  final bool onboardingDone;

  UserPreferences({
    required this.categories,
    required this.cuisines,
    required this.travelMode,
    required this.onboardingDone,
  });

  factory UserPreferences.empty() => UserPreferences(
    categories:     [],
    cuisines:       [],
    travelMode:     'walk',
    onboardingDone: false,
  );

  factory UserPreferences.fromMap(Map<String, dynamic> map) {
    final prefs = map['preferences'] as Map<String, dynamic>? ?? {};
    return UserPreferences(
      categories:     List<String>.from(prefs['categories'] ?? []),
      cuisines:       List<String>.from(prefs['cuisines']   ?? []),
      travelMode:     prefs['travelMode'] as String?        ?? 'walk',
      onboardingDone: map['onboardingDone'] as bool?        ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
    'onboardingDone': true,
    'preferences': {
      'categories': categories,
      'cuisines':   cuisines,
      'travelMode': travelMode,
    },
  };

  UserPreferences copyWith({
    List<String>? categories,
    List<String>? cuisines,
    String? travelMode,
    bool? onboardingDone,
  }) {
    return UserPreferences(
      categories:     categories     ?? this.categories,
      cuisines:       cuisines       ?? this.cuisines,
      travelMode:     travelMode     ?? this.travelMode,
      onboardingDone: onboardingDone ?? this.onboardingDone,
    );
  }
}

class UserPreferenceService {
  static final UserPreferenceService instance = UserPreferenceService._();
  UserPreferenceService._();

  UserPreferences _prefs = UserPreferences.empty();
  UserPreferences get current => _prefs;

  final ValueNotifier<int> preferencesChanged = ValueNotifier(0);

  final Map<String, int> _favouriteCount = {};
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

      final countMap = doc.data()!['favouriteTypeCounts'] as Map<String, dynamic>? ?? {};
      _favouriteCount.clear();
      countMap.forEach((k, v) => _favouriteCount[k] = (v as num).toInt());

      return _prefs;
    } catch (e) {
      print('❌ UserPreferenceService.load error: $e');
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
      },
      'favouriteTypeCounts': {},
    });
    preferencesChanged.value++;
  }

  // ─────────────────────────────────────────────
  // Update from favourite
  // ─────────────────────────────────────────────

  Future<void> updateFromFavourite({
    required String primaryType,
    required List<String> allTypes,
    required bool isFavouriting,
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
        _favouriteCount[key] = ((_favouriteCount[key] ?? 0) - 1).clamp(0, 999);
      }
    }

    final updatedCategories = List<String>.from(_prefs.categories);
    final updatedCuisines   = List<String>.from(_prefs.cuisines);

    for (final entry in _favouriteCount.entries) {
      final key   = entry.key;
      final count = entry.value;

      if (key.startsWith('cat_')) {
        final cat = key.substring(4);
        if (count >= _minCountToLearn && !updatedCategories.contains(cat)) {
          updatedCategories.add(cat);
        }
      }

      if (key.startsWith('cui_')) {
        final cui = key.substring(4);
        if (count >= _minCountToLearn && !updatedCuisines.contains(cui)) {
          updatedCuisines.add(cui);
        }
      }
    }

    _prefs = UserPreferences(
      categories:     updatedCategories,
      cuisines:       updatedCuisines,
      travelMode:     _prefs.travelMode,
      onboardingDone: _prefs.onboardingDone,
    );

    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'preferences': {
        'categories': updatedCategories,
        'cuisines':   updatedCuisines,
        'travelMode': _prefs.travelMode,
      },
      'favouriteTypeCounts': _favouriteCount,
    });
  }

  // ─────────────────────────────────────────────
  // Score
  // ─────────────────────────────────────────────

  double scorePlaceModel({
    required String? primaryType,
    required List<String> allTypes,
    double? distanceMeters,
  }) {
    double score = 0;

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

    // Category match → +10
    final category = typeToCategory[primaryType ?? ''];
    if (category != null && _prefs.categories.contains(category)) {
      score += 10;
    }

    // Cuisine match → +5
    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null && _prefs.cuisines.contains(cuisine)) {
        score += 5;
      }
    }

    // 时间段加成
    score += _getTimeBonus(primaryType, allTypes);

    // 距离加成（最多 +5）
    if (distanceMeters != null && distanceMeters > 0) {
      final distKm   = distanceMeters / 1000;
      final distBonus = (5 / distKm).clamp(0.0, 5.0);
      score += distBonus;
    }

    return score;
  }

  // ─────────────────────────────────────────────
  // Time bonus
  // ─────────────────────────────────────────────

  double _getTimeBonus(String? primaryType, List<String> allTypes) {
    final hour = DateTime.now().hour;

    const timeBonus = <String, Map<String, double>>{
      'morning':   {'cafe': 8.0, 'restaurant': 3.0},
      'lunch':     {'restaurant': 8.0, 'cafe': 2.0},
      'afternoon': {'tourist_attraction': 6.0, 'park': 6.0, 'shopping_mall': 5.0},
      'evening':   {'restaurant': 8.0, 'amusement_park': 5.0},
      'night':     {'amusement_park': 8.0, 'restaurant': 4.0},
    };

    const typeToPrimary = <String, String>{
      'cafe':               'cafe',
      'coffee_shop':        'cafe',
      'restaurant':         'restaurant',
      'tourist_attraction': 'tourist_attraction',
      'park':               'park',
      'shopping_mall':      'shopping_mall',
      'amusement_park':     'amusement_park',
    };

    final String period;
    if      (hour >= 6  && hour < 11) period = 'morning';
    else if (hour >= 11 && hour < 14) period = 'lunch';
    else if (hour >= 14 && hour < 17) period = 'afternoon';
    else if (hour >= 17 && hour < 20) period = 'evening';
    else                               period = 'night';

    final bonusMap = timeBonus[period]!;

    // ✅ 先检查 primaryType
    if (primaryType != null && bonusMap.containsKey(primaryType)) {
      return bonusMap[primaryType]!;
    }

    // ✅ 再检查 allTypes（给 cafe/coffee_shop 用）
    for (final t in allTypes) {
      final mapped = typeToPrimary[t];
      if (mapped != null && bonusMap.containsKey(mapped)) {
        return bonusMap[mapped]!;
      }
    }

    return 0;
  }

  // ─────────────────────────────────────────────
  // Recommend reason
  // ─────────────────────────────────────────────

  String? getRecommendReason({
    required String? primaryType,
    required List<String> allTypes,
  }) {
    const typeToCuisine = {
      'chinese_restaurant':   'Chinese',
      'malay_restaurant':     'Malay',
      'malaysian_restaurant': 'Malay',
      'indian_restaurant':    'Indian',
      'western_restaurant':   'Western',
      'american_restaurant':  'Western',
      'japanese_restaurant':  'Japanese',
      'korean_restaurant':    'Korean',
      'dessert_shop':         'Dessert',
      'ice_cream_shop':       'Dessert',
      'bakery':               'Dessert',
      'cafe':                 'Cafe',
      'coffee_shop':          'Cafe',
    };

    const typeToCategory = {
      'restaurant':         'restaurant',
      'park':               'park',
      'tourist_attraction': 'tourist_attraction',
      'shopping_mall':      'shopping_mall',
      'amusement_park':     'amusement_park',
    };

    const categoryToLabel = {
      'restaurant':         'Food',
      'park':               'Nature',
      'tourist_attraction': 'Historical places',
      'shopping_mall':      'Shopping',
      'amusement_park':     'Entertainment',
    };

    // 时间段原因
    final hour = DateTime.now().hour;
    if (hour >= 6  && hour < 11) {
      if (primaryType == 'cafe' || allTypes.any((t) => t == 'cafe' || t == 'coffee_shop')) {
        return 'Good morning ☕ Start your day here';
      }
    }
    if (hour >= 11 && hour < 14) {
      if (primaryType == 'restaurant') return 'Lunch time 🍽️ Try this place';
    }
    if (hour >= 17 && hour < 20) {
      if (primaryType == 'restaurant') return 'Dinner time 🌆 Great for tonight';
    }
    if (hour >= 20 || hour < 2) {
      if (primaryType == 'amusement_park') return 'Night out 🌙 Fun nearby';
    }

    // Cuisine match
    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null && _prefs.cuisines.contains(cuisine.toLowerCase())) {
        return 'Because you like $cuisine food';
      }
    }

    // Category match
    final category = typeToCategory[primaryType ?? ''];
    if (category != null && _prefs.categories.contains(category)) {
      final label = categoryToLabel[category] ?? category;
      return 'Because you like $label';
    }

    return null;
  }
}