// services/user_preference_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

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
      categories:     List<String>.from(prefs['categories']  ?? []),
      cuisines:       List<String>.from(prefs['cuisines']    ?? []),
      travelMode:     prefs['travelMode'] as String?         ?? 'walk',
      onboardingDone: map['onboardingDone'] as bool?         ?? false,
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
}

class UserPreferenceService {
  static final UserPreferenceService instance = UserPreferenceService._();
  UserPreferenceService._();

  UserPreferences _prefs = UserPreferences.empty();
  UserPreferences get current => _prefs;

  // ── 收藏频率计数（内存，不存 Firestore）──────
  // key = type string, value = 收藏次数
  final Map<String, int> _favouriteCount = {};
  static const int _minCountToLearn = 3; // 收藏 3 次才学习

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

      // 同时 load 收藏频率
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
  // Save (onboarding / edit preferences)
  // ─────────────────────────────────────────────

  Future<void> save(UserPreferences prefs) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _prefs = prefs;
    await FirebaseFirestore.instance
        .collection('users').doc(uid).update(prefs.toMap());
  }

  // ─────────────────────────────────────────────
  // Reset preferences
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
  }

  // ─────────────────────────────────────────────
  // Update from favourite — 用频率学习
  // ─────────────────────────────────────────────

  Future<void> updateFromFavourite({
    required String primaryType,
    required List<String> allTypes,
    required bool isFavouriting, // true = 收藏, false = 取消收藏
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

    // 收集这个地点涉及的所有 keys
    final List<String> involvedKeys = [];
    final category = typeToCategory[primaryType];
    if (category != null) involvedKeys.add('cat_$category');
    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null) involvedKeys.add('cui_$cuisine');
    }

    if (involvedKeys.isEmpty) return;

    // 更新计数
    for (final key in involvedKeys) {
      if (isFavouriting) {
        _favouriteCount[key] = (_favouriteCount[key] ?? 0) + 1;
      } else {
        final current = _favouriteCount[key] ?? 0;
        _favouriteCount[key] = (current - 1).clamp(0, 999);
      }
    }

    // 根据计数重新计算 preferences
    final updatedCategories = List<String>.from(_prefs.categories);
    final updatedCuisines   = List<String>.from(_prefs.cuisines);

    for (final entry in _favouriteCount.entries) {
      final key   = entry.key;
      final count = entry.value;

      if (key.startsWith('cat_')) {
        final cat = key.substring(4);
        if (count >= _minCountToLearn && !updatedCategories.contains(cat)) {
          updatedCategories.add(cat); // 达到阈值 → 加入
        } else if (count < _minCountToLearn && updatedCategories.contains(cat)) {
          // ✅ 取消收藏导致低于阈值 → 如果不是 onboarding 选的才移除
          // (onboarding 选的优先级更高，不自动移除)
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

    // 存回 Firestore
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
  // Score — 加入距离因素
  // ─────────────────────────────────────────────

  double scorePlaceModel({
    required String? primaryType,
    required List<String> allTypes,
    double? distanceMeters, // ← 新增距离参数
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

    // Cuisine match → +5 each
    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null && _prefs.cuisines.contains(cuisine)) {
        score += 5;
      }
    }

    // ✅ 距离加成：越近分越高（最多 +5）
    if (distanceMeters != null && distanceMeters > 0) {
      final distKm = distanceMeters / 1000;
      final distBonus = (5 / distKm).clamp(0.0, 5.0);
      score += distBonus;
    }

    return score;
  }

  // ─────────────────────────────────────────────
  // Reason string — 解释为什么推荐
  // ─────────────────────────────────────────────

  String? getRecommendReason({
    required String? primaryType,
    required List<String> allTypes,
  }) {
    const typeToCategory = {
      'restaurant':         'restaurant',
      'park':               'park',
      'tourist_attraction': 'tourist_attraction',
      'shopping_mall':      'shopping_mall',
      'amusement_park':     'amusement_park',
    };

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

    const categoryToLabel = {
      'restaurant':         'Food',
      'park':               'Nature',
      'tourist_attraction': 'Historical places',
      'shopping_mall':      'Shopping',
      'amusement_park':     'Entertainment',
    };

    // Check cuisine first (more specific)
    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null && _prefs.cuisines.contains(
          cuisine.toLowerCase())) {
        return 'Because you like $cuisine food';
      }
    }

    // Check category
    final category = typeToCategory[primaryType ?? ''];
    if (category != null && _prefs.categories.contains(category)) {
      final label = categoryToLabel[category] ?? category;
      return 'Because you like $label';
    }

    return null;
  }
}

// ─────────────────────────────────────────────
// Extension for copyWith
// ─────────────────────────────────────────────

extension UserPreferencesX on UserPreferences {
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