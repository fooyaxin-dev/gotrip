// services/user_preference_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/placeModel.dart';
import 'route_service.dart';
import 'sentiment_service.dart';
import 'weather_service.dart';
import 'category_mapper.dart';

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

// ─────────────────────────────────────────────
// For You — 唯一判定入口（MainPage / RealTimeDetectPage 共用）
// ─────────────────────────────────────────────

class ForYouResult {
  final List<PlaceModel> places;
  final Map<String, double> scores;
  ForYouResult(this.places, this.scores);
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
    'fitness':     'entertainment',
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
  // shared cuisine map (used by favourite/post learning + interest score)
  // ─────────────────────────────────────────────

  static const _typeToCuisine = <String, String>{
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

      // ── Load searchScoreBuffer ──
      final bufferMap =
          doc.data()!['searchScoreBuffer'] as Map<String, dynamic>? ?? {};
      _searchScoreBuffer.clear();
      bufferMap.forEach((k, v) => _searchScoreBuffer[k] = (v as num).toDouble());

      preferencesChanged.value++;   // 🆕 让所有监听者（包括 MainPage）知道数据到位了
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
  //
  // 🔧 CHANGED: primaryType 是否算"可学习分类"，现在统一问
  // CategoryMapper.isLearnableCategory，不再自己维护一份身份映射表——
  // 那份表原本只认 5 个字面量，'amusement_park' 也已经跟着 Nearby 页面
  // 改名成 'entertainment'，两边不会再对不上。
  // ─────────────────────────────────────────────

  Future<void> updateFromFavourite({
    required String       primaryType,
    required List<String> allTypes,
    required bool         isFavouriting,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final List<String> involvedKeys = [];
    if (CategoryMapper.isLearnableCategory(primaryType)) {
      involvedKeys.add('cat_$primaryType');
    }
    for (final t in allTypes) {
      final cuisine = _typeToCuisine[t];
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
    _applyGate(updatedCategories, updatedCuisines);

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
  //
  // 🔧 CHANGED: 以前这里自己维护一份只认 5 个字面量的 typeToCategory，
  // 拿去匹配 placeTypes（真正的 Google raw types，如 'cafe'/'museum'）
  // 几乎永远命不中——那 5 个字面量本身凑巧也是合法的 Google type，
  // 但覆盖不到 cafe/coffee_shop/museum/art_gallery 这些常见类型。
  // 现在改用 CategoryMapper.toPrimaryType(placeTypes) 先算出真正的
  // primaryType，再判断是否可学习，这样 cafe/museum 这类帖子也能
  // 正确被学习到。
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
  
    final List<String> involvedKeys = [];

    final primaryCategory = CategoryMapper.toPrimaryType(placeTypes);
    if (CategoryMapper.isLearnableCategory(primaryCategory)) {
      involvedKeys.add('cat_$primaryCategory');
    }
    for (final t in placeTypes) {
      final cuisine = _typeToCuisine[t];
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
  
    final updatedCategories = List<String>.from(_prefs.categories);
    final updatedCuisines   = List<String>.from(_prefs.cuisines);
    _applyGate(updatedCategories, updatedCuisines);
  
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
      'park', 'tourist_attraction', 'entertainment',
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
  
  // 🔧 CHANGED: 不再自己维护身份映射表，直接问 CategoryMapper 这个
  // primaryType 是否可学习。
  double _interestMatchScore(String? primaryType, List<String> allTypes) {
    double countToScore(int count) {
      if (count < _minCountToLearn) return 0.0;
      const maxCount = 10;
      final clamped  = count.clamp(_minCountToLearn, maxCount);
      return 0.6 + 0.4 * (clamped - _minCountToLearn) / (maxCount - _minCountToLearn);
    }

    final scores = <double>[];

    if (primaryType != null && CategoryMapper.isLearnableCategory(primaryType)) {
      if (_prefs.categories.contains(primaryType)) scores.add(1.0);
      final cnt = _favouriteCount['cat_$primaryType'] ?? 0;
      final cs  = countToScore(cnt);
      if (cs > 0) scores.add(cs);
    }

    for (final t in allTypes) {
      final cuisine = _typeToCuisine[t];
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
    return (1.0 - distanceMeters / 12000.0).clamp(0.0, 1.0);   // 目前用 12000 做满分基准
  }

  double _ratingScore(double? rating) {
    if (rating == null) return 0.5;
    return ((rating - 2.0) / 3.0).clamp(0.0, 1.0);
  }

  // 🔧 CHANGED: 'amusement_park' → 'entertainment'
  double _timeSuitabilityScore(String? primaryType, List<String> allTypes) {
    final hour = DateTime.now().hour;

    const suitability = <String, Map<String, double>>{
      'morning':   {'cafe': 1.0, 'restaurant': 0.6, 'park': 0.8, 'tourist_attraction': 0.7},
      'lunch':     {'restaurant': 1.0, 'cafe': 0.5, 'shopping_mall': 0.4},
      'afternoon': {'tourist_attraction': 1.0, 'park': 1.0, 'shopping_mall': 0.9, 'entertainment': 0.8, 'restaurant': 0.3},
      'evening':   {'restaurant': 1.0, 'shopping_mall': 0.7, 'entertainment': 0.8},
      'night':     {'entertainment': 1.0, 'restaurant': 0.7},
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


    // 🔧 CHANGED: 不再自己维护身份映射表
    bool matchesPreference({
      required String?      primaryType,
      required List<String> allTypes,
    }) {
      if (primaryType != null && CategoryMapper.isLearnableCategory(primaryType)) {
        if (_prefs.categories.contains(primaryType)) return true;
        if ((_favouriteCount['cat_$primaryType'] ?? 0) >= _minCountToLearn) return true;
      }

      for (final t in allTypes) {
        final cuisine = _typeToCuisine[t];
        if (cuisine == null) continue;
        if (_prefs.cuisines.contains(cuisine)) return true;
        if ((_favouriteCount['cui_$cuisine'] ?? 0) >= _minCountToLearn) return true;
      }

      return false;
    }

    ForYouResult buildForYouList({
      required List<PlaceModel>     candidates,
      Map<String, RouteResult>?     routeResults,
      double?                       distanceLimitMeters,
      WeatherCondition?             weather,
      bool                          requirePhoto = false,
    }) {
      final matched = <PlaceModel>[];
      final scores  = <String, double>{};

      for (final p in candidates) {
        final dist = routeResults?[p.id]?.distanceMeters;

        if (distanceLimitMeters != null) {
          if (dist == null || dist > distanceLimitMeters) continue;
        }
        if (requirePhoto && (p.photoUrl == null || p.photoUrl!.isEmpty)) continue;
        if (!matchesPreference(primaryType: p.primaryType, allTypes: p.allTypes)) continue;

        matched.add(p);
        scores[p.id] = scorePlaceModel(
          primaryType:    p.primaryType,
          allTypes:       p.allTypes,
          distanceMeters: dist,
          rating:         p.rating,
          priceLevel:     p.priceLevel,
          weather:        weather,
        );
      }

      matched.sort((a, b) => scores[b.id]!.compareTo(scores[a.id]!));
      return ForYouResult(matched, scores);
    }

  // 🔧 CHANGED: typeToCategory/categoryToLabel 里的 'amusement_park' →
  // 'entertainment'，night 时段判断也跟着改。
  String? getRecommendReason({
    required String?      primaryType,
    required List<String> allTypes,
  }) {
    const categoryToLabel = {
      'restaurant': 'Food', 'park': 'Nature',
      'tourist_attraction': 'Historical places',
      'shopping_mall': 'Shopping', 'entertainment': 'Entertainment',
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
    if ((hour >= 20 || hour < 2) && primaryType == 'entertainment') {
      return 'Night out 🌙 Fun nearby';
    }

    for (final t in allTypes) {
      final cuisine = _typeToCuisine[t];
      if (cuisine != null && _prefs.cuisines.contains(cuisine.toLowerCase())) {
        return 'Because you like $cuisine food';
      }
    }
    if (primaryType != null && _prefs.categories.contains(primaryType)) {
      return 'Because you like ${categoryToLabel[primaryType] ?? primaryType}';
    }
    return null;
  }
}