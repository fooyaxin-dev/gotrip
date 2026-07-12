// services/user_preference_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'sentiment_service.dart';
import 'weather_service.dart';

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

  String toJson() => name;

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
  final double weatherScore; 

  const RecommendationScore({
    required this.total,
    required this.interestMatch,
    required this.distanceScore,
    required this.ratingScore,
    required this.timeSuitability,
    required this.budgetSuitability,
    required this.weatherScore,
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

  final Map<String, int>    _favouriteCount    = {};
  final Map<String, double> _searchScoreBuffer = {}; // 小数累积 buffer

  static const int _minCountToLearn = 3;

  // ─────────────────────────────────────────────
  // shared tag/topic → category maps
  // (defined once, reused across all update methods)
  // ─────────────────────────────────────────────

  static const _tagToCategory = <String, String>{
    'food':        'restaurant',
    'travel':      'tourist_attraction',
    'photography': 'tourist_attraction',
    'fitness':     'amusement_park',
    'nature':      'park',
    'shopping':    'shopping_mall',
  };

  static const _topicToCategory = <String, String>{
    '#foodie':      'restaurant',
    '#malaysia':    'tourist_attraction',
    '#KLCC':        'tourist_attraction',
    '#penang':      'tourist_attraction',
    '#niceView':    'park',
    '#happyTravel': 'tourist_attraction',
    '#travelvlog':  'tourist_attraction',
    '#journey':     'tourist_attraction',
    '#transport':   'tourist_attraction',
  };

  // ─────────────────────────────────────────────
  // Load  ← 现在同时加载 searchScoreBuffer
  // ─────────────────────────────────────────────

  Future<UserPreferences> load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return UserPreferences.empty();
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(uid).get();
      if (!doc.exists) return UserPreferences.empty();

      _prefs = UserPreferences.fromMap(doc.data()!);

      // ── Load favouriteTypeCounts ──
      final countMap =
          doc.data()!['favouriteTypeCounts'] as Map<String, dynamic>? ?? {};
      _favouriteCount.clear();
      countMap.forEach((k, v) => _favouriteCount[k] = (v as num).toInt());

      // ── Load searchScoreBuffer ── ← 新增，App 重启后 buffer 不会丢失
      final bufferMap =
          doc.data()!['searchScoreBuffer'] as Map<String, dynamic>? ?? {};
      _searchScoreBuffer.clear();
      bufferMap.forEach((k, v) => _searchScoreBuffer[k] = (v as num).toDouble());

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
    _searchScoreBuffer.clear(); // ← 同时清空 buffer
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'preferences': {
        'categories': [],
        'cuisines':   [],
        'travelMode': 'walk',
        'budgetTier': 'budget',
      },
      'favouriteTypeCounts': {},
      'searchScoreBuffer':   {}, // ← 同时清空 Firestore 里的 buffer
    });
    preferencesChanged.value++;
  }

  // ─────────────────────────────────────────────
  // Update from favourite (place)
  // 直接整数 +1 / -1，最强信号
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

  // ─────────────────────────────────────────────
  // Update from Post
  // 发帖 = 直接整数 +1，删帖 = -1
  // ─────────────────────────────────────────────

  Future<void> updateFromPost({
    required List<String> placeTypes,    // post.placeTypes（Google types）
    required SentimentLabel sentimentLabel,
    required int sentimentMatchedTokens, // 用来判断是否低置信度
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
  
    // 没挂地点 / 没有 types，没有学习的对象
    if (placeTypes.isEmpty) return;
  
    // 只有正面情感才计入学习
    if (sentimentLabel != SentimentLabel.positive) {
      print('🧠 updateFromPost: skipped (sentiment=${sentimentLabel.toJson()}, '
          'not positive — no learning signal)');
      return;
    }
  
    // 低置信度结果（命中词太少）不可靠，跳过
    if (sentimentMatchedTokens < 2) {
      print('🧠 updateFromPost: skipped (low confidence, '
          'only $sentimentMatchedTokens sentiment words matched)');
      return;
    }
  
    // ── 复用跟 updateFromFavourite 完全一样的 type→category / type→cuisine 映射 ──
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
  
    // primaryType 不直接给到这个方法（post 存的是 placeTypes 这个 List），
    // 所以这里改成遍历 placeTypes 找第一个匹配的 category
    for (final t in placeTypes) {
      final category = typeToCategory[t];
      if (category != null) {
        involvedKeys.add('cat_$category');
        break; // 一个 post 只算一次 category 信号，避免重复加权
      }
    }
    for (final t in placeTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null) {
        involvedKeys.add('cui_$cuisine');
        break; // 一个 post 只算一次 cuisine 信号
      }
    }
  
    if (involvedKeys.isEmpty) {
      print('🧠 updateFromPost: skipped (no recognized category/cuisine in placeTypes)');
      return;
    }
  
    // ── 用「post 正面体验」给计数 +1（跟 favourite 共用同一套 _favouriteCount） ──
    for (final key in involvedKeys) {
      _favouriteCount[key] = (_favouriteCount[key] ?? 0) + 1;
    }
  
    // ── 重新跑一遍 gate 检查（跟 updateFromFavourite 同样的逻辑）──
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
  
    print('🧠 updateFromPost: learned from positive post — keys=$involvedKeys, '
        'updated categories=$updatedCategories, cuisines=$updatedCuisines');
  }
  
  // ─────────────────────────────────────────────
  // Update from Like post  ← 新增
  // Like = +0.7 via buffer，Unlike = -0.7
  // 权重比搜索(0.5)强，比收藏地点(1.0整数)弱
  // ─────────────────────────────────────────────

  Future<void> updateFromLike({
    required List<String>   postTags,
    required String?        postTopic,
    required bool           isLiking,
    required SentimentLabel sentimentLabel,       // ← 新增
    required int             sentimentMatchedTokens, // ← 新增
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    if (postTags.isEmpty && postTopic == null) return;

    // 只有 positive 且置信度够高才计入学习，跟 updateFromPost 一致
    if (sentimentLabel != SentimentLabel.positive) {
      print('🧠 updateFromLike: skipped (sentiment=${sentimentLabel.toJson()}, not positive)');
      return;
    }
    if (sentimentMatchedTokens < 2) {
      print('🧠 updateFromLike: skipped (low confidence, only $sentimentMatchedTokens words)');
      return;
    }

    final involvedKeys = <String>{};
    for (final tag in postTags) {
      final cat = _tagToCategory[tag.toLowerCase()];
      if (cat != null) involvedKeys.add('cat_$cat');
    }
    if (postTopic != null) {
      final cat = _topicToCategory[postTopic];
      if (cat != null) involvedKeys.add('cat_$cat');
    }

    if (involvedKeys.isEmpty) return;

    for (final key in involvedKeys) {
      if (isLiking) {
        _searchScoreBuffer[key] = (_searchScoreBuffer[key] ?? 0.0) + 0.7;
      } else {
        _searchScoreBuffer[key] = (_searchScoreBuffer[key] ?? 0.0) - 0.7;
        if (_searchScoreBuffer[key]! < 0) _searchScoreBuffer[key] = 0.0;
      }
    }

    await _flushBuffer(uid);

    print('✅ updateFromLike: tags=$postTags topic=$postTopic isLiking=$isLiking '
        '(sentiment gate passed)');
  }

  // ─────────────────────────────────────────────
  // Update from Search (点击搜索结果里的帖子)
  // 最弱信号 +0.5 via buffer
  // ─────────────────────────────────────────────

  Future<void> updateFromSearch({
    required List<String> postTags,
    required String?      postTopic,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    if (postTags.isEmpty && postTopic == null) return;

    final involvedKeys = <String>{};
    for (final tag in postTags) {
      final cat = _tagToCategory[tag.toLowerCase()];
      if (cat != null) involvedKeys.add('cat_$cat');
    }
    if (postTopic != null) {
      final cat = _topicToCategory[postTopic];
      if (cat != null) involvedKeys.add('cat_$cat');
    }

    if (involvedKeys.isEmpty) return;

    // 点击帖子 +0.5
    for (final key in involvedKeys) {
      _searchScoreBuffer[key] = (_searchScoreBuffer[key] ?? 0.0) + 0.5;
    }

    await _flushBuffer(uid);

    print('✅ updateFromSearch: tags=$postTags topic=$postTopic');
  }

  // ─────────────────────────────────────────────
  // _flushBuffer — 把 buffer 里达到整数的分数
  // 转进 _favouriteCount，更新 Firestore
  // 所有用到 buffer 的方法都调这个，避免重复代码
  // ─────────────────────────────────────────────

  Future<void> _flushBuffer(String uid) async {
    final Map<String, dynamic> firestoreUpdates = {};
    final updatedCategories = List<String>.from(_prefs.categories);
    final updatedCuisines   = List<String>.from(_prefs.cuisines);

    _searchScoreBuffer.forEach((key, score) {
      final wholePoints = score.floor();
      if (wholePoints > 0) {
        _favouriteCount[key] = (_favouriteCount[key] ?? 0) + wholePoints;
        _searchScoreBuffer[key] = score - wholePoints; // 只保留小数

        firestoreUpdates['favouriteTypeCounts.$key'] = _favouriteCount[key];
      }
    });

    // Gate 判断
    _applyGate(updatedCategories, updatedCuisines);

    // preferences 有变化才更新
    if (updatedCategories.length != _prefs.categories.length ||
        updatedCuisines.length   != _prefs.cuisines.length) {
      _prefs = _prefs.copyWith(
        categories: updatedCategories,
        cuisines:   updatedCuisines,
      );
      firestoreUpdates['preferences.categories'] = updatedCategories;
      firestoreUpdates['preferences.cuisines']   = updatedCuisines;
      preferencesChanged.value++;
    }

    // 永远保存最新 buffer 状态
    firestoreUpdates['searchScoreBuffer'] = _searchScoreBuffer;

    if (firestoreUpdates.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update(firestoreUpdates);
    }
  }

  // ─────────────────────────────────────────────
  // _applyGate — 根据 _favouriteCount 更新
  // categories 和 cuisines list
  // ─────────────────────────────────────────────

  void _applyGate(
    List<String> updatedCategories,
    List<String> updatedCuisines,
  ) {
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
  }

  /// ═══════════════════════════════════════════════════════════════════
  // RECOMMENDATION SCORE
  //
  // Score = 0.30 × InterestMatch
  //       + 0.20 × DistanceScore
  //       + 0.15 × WeatherScore
  //       + 0.15 × RatingScore
  //       + 0.10 × TimeSuitability
  //       + 0.10 × BudgetSuitability
  //
  // Open/Close is NOT part of this formula — it's a hard filter applied
  // before scoring (closed places should be excluded from the candidate
  // list entirely, not merely down-weighted).
  // ═══════════════════════════════════════════════════════════════════

  RecommendationScore recommendationScore({
    required String?      primaryType,
    required List<String> allTypes,
    required double?      rating,
    required double?      distanceMeters,
    required int?         priceLevel,
    WeatherCondition?     weather,   // ← 新增，nullable = 没拿到天气数据时不惩罚
  }) {
    final interest = _interestMatchScore(primaryType, allTypes);
    final distance = _distanceScore(distanceMeters);
    final ratingS  = _ratingScore(rating);
    final time     = _timeSuitabilityScore(primaryType, allTypes);
    final budget   = _budgetSuitabilityScore(priceLevel);
    final weatherS = _weatherScore(weather, primaryType, allTypes);

    final total = (0.30 * interest
                + 0.20 * distance
                + 0.15 * weatherS
                + 0.15 * ratingS
                + 0.10 * time
                + 0.10 * budget).clamp(0.0, 1.0);

    return RecommendationScore(
      total:             total,
      interestMatch:     interest,
      distanceScore:     distance,
      ratingScore:       ratingS,
      timeSuitability:   time,
      budgetSuitability: budget,
      weatherScore:      weatherS,
    );
  }

  double _weatherScore(
    WeatherCondition? weather,
    String? primaryType,
    List<String> allTypes,
  ) {
    // No weather data available → neutral-high, don't penalize
    if (weather == null) return 0.8;

    const outdoorTypes = {
      'park', 'tourist_attraction', 'amusement_park',
    };
    final isOutdoor = (primaryType != null && outdoorTypes.contains(primaryType))
        || allTypes.any((t) => outdoorTypes.contains(t));

    switch (weather) {
      case WeatherCondition.rain:
      case WeatherCondition.storm:
        return isOutdoor ? 0.2 : 1.0;
      case WeatherCondition.extreme:
        return isOutdoor ? 0.1 : 0.9;
      case WeatherCondition.cloudy:
        return isOutdoor ? 0.8 : 0.9;
      case WeatherCondition.clear:
        return isOutdoor ? 1.0 : 0.8;
    }
  }
  
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

    double countToScore(int count) {
      if (count < _minCountToLearn) return 0.0;
      const maxCount = 10;
      final clamped  = count.clamp(_minCountToLearn, maxCount);
      return 0.6 + 0.4 * (clamped - _minCountToLearn) / (maxCount - _minCountToLearn);
    }

    final scores = <double>[];

    final category = typeToCategory[primaryType ?? ''];
    if (category != null) {
      if (_prefs.categories.contains(category)) scores.add(1.0);
      final cnt = _favouriteCount['cat_$category'] ?? 0;
      final cs  = countToScore(cnt);
      if (cs > 0) scores.add(cs);
    }

    for (final t in allTypes) {
      final cuisine = typeToCuisine[t];
      if (cuisine != null) {
        if (_prefs.cuisines.contains(cuisine)) scores.add(1.0);
        final cnt = _favouriteCount['cui_$cuisine'] ?? 0;
        final cs  = countToScore(cnt);
        if (cs > 0) scores.add(cs);
        break;
      }
    }

    if (scores.isEmpty) return 0.5;
    return (scores.reduce((a, b) => a + b) / scores.length).clamp(0.0, 1.0);
  }

  double _distanceScore(double? distanceMeters) {
    if (distanceMeters == null || distanceMeters <= 0) return 0.5;
    return (1.0 - distanceMeters / 15000.0).clamp(0.0, 1.0);
  }

  double _ratingScore(double? rating) {
    if (rating == null) return 0.5;
    return ((rating - 2.0) / 3.0).clamp(0.0, 1.0);
  }

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

  double _budgetSuitabilityScore(int? priceLevel) {
    if (priceLevel == null) return 1.0;

    const scores = <String, List<double>>{
      'budget':   [1.0, 0.8, 0.3, 0.0],
      'midRange': [0.6, 1.0, 1.0, 0.5],
      'premium':  [0.2, 0.6, 1.0, 1.0],
    };

    final tier = _prefs.budgetTier.toJson();
    final idx  = (priceLevel - 1).clamp(0, 3);
    return scores[tier]![idx];
  }

  double scorePlaceModel({
    required String?      primaryType,
    required List<String> allTypes,
    double?               distanceMeters,
    double?               rating,
    int?                  priceLevel,
    WeatherCondition?     weather,
  }) =>
      recommendationScore(
        primaryType:    primaryType,
        allTypes:       allTypes,
        rating:         rating,
        distanceMeters: distanceMeters,
        priceLevel:     priceLevel,
        weather:        weather,
      ).total;

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
    const typeToCategory = {
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
    if (hour >= 6 && hour < 11 &&
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