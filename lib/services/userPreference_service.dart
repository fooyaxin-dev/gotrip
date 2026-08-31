import 'dart:async';

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
  final String       topPriority;

  UserPreferences({
    required this.categories,
    required this.cuisines,
    required this.travelMode,
    required this.budgetTier,
    required this.onboardingDone,
    this.topPriority = 'interest',
  });

  factory UserPreferences.empty() => UserPreferences(
    categories:     [],
    cuisines:       [],
    travelMode:     'walk',
    budgetTier:     BudgetTier.budget,
    onboardingDone: false,
    topPriority:    'interest',
  );

  factory UserPreferences.fromMap(Map<String, dynamic> map) {
    final prefs = map['preferences'] as Map<String, dynamic>? ?? {};
    return UserPreferences(
      categories:     List<String>.from(prefs['categories'] ?? []),
      cuisines:       List<String>.from(prefs['cuisines']   ?? []),
      travelMode:     prefs['travelMode']  as String? ?? 'walk',
      budgetTier:     BudgetTierX.fromJson(prefs['budgetTier'] as String?),
      onboardingDone: map['onboardingDone'] as bool?  ?? false,
      topPriority:    prefs['topPriority'] as String? ?? 'interest',
    );
  }

  Map<String, dynamic> toMap() => {
    'onboardingDone': true,
    'preferences': {
      'categories': categories,
      'cuisines':   cuisines,
      'travelMode': travelMode,
      'budgetTier': budgetTier.toJson(),
      'topPriority': topPriority,
    },
  };

  UserPreferences copyWith({
    List<String>? categories,
    List<String>? cuisines,
    String?       travelMode,
    BudgetTier?   budgetTier,
    bool?         onboardingDone,
    String?       topPriority,
  }) => UserPreferences(
    categories:     categories     ?? this.categories,
    cuisines:       cuisines       ?? this.cuisines,
    travelMode:     travelMode     ?? this.travelMode,
    budgetTier:     budgetTier     ?? this.budgetTier,
    onboardingDone: onboardingDone ?? this.onboardingDone,
    topPriority:    topPriority    ?? this.topPriority,
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
  final Map<String, double> _timeAffinity      = {};
  final Map<String, double> _passiveCount = {};

  // All learning signals mutate shared in-memory maps and then persist those
  // maps to Firestore. Serialising the complete operations prevents an older
  // async write from finishing after, and overwriting, a newer signal.
  Future<void> _learningQueue = Future<void>.value();

  Future<void> _enqueueLearningForCurrentUser(
    Future<void> Function() operation,
  ) {
    final requestedUid = FirebaseAuth.instance.currentUser?.uid;
    if (requestedUid == null) return Future<void>.value();

    final completer = Completer<void>();

    _learningQueue = _learningQueue.then((_) async {
      try {
        // A queued signal belongs to the account that triggered it. Never let
        // a logout/login between queueing and execution write it to another
        // user's preference document.
        if (FirebaseAuth.instance.currentUser?.uid != requestedUid) {
          print('⚠️ Preference signal skipped: account changed while queued');
          completer.complete();
          return;
        }

        await operation();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  }

  // 🆕 各来源 × 各数据类型的基础权重
  static const double _wPostTag      = 0.5;  // 发帖时的 tag/topic
  static const double _wLikeLocation = 0.7;  // 点赞帖子挂的地点
  static const double _wLikeTag      = 0.3;  // 点赞帖子的 tag/topic
  static const double _wSearchLocation = 0.5; // 搜索点开帖子挂的地点
  static const double _wSearchTag      = 0.2; // 搜索点开帖子的 tag/topic
    
    
  static const int _minCountToLearn = 3;
  static const double _minCountToLearnTime = 1.0; 

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
  //  Load  ← 同时加载 favouriteTypeCounts / passiveSignalCount / timeAffinity
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

      // 🆕 Load passiveSignalCount（取代原本的 searchScoreBuffer）
      final passiveMap =
          doc.data()!['passiveSignalCount'] as Map<String, dynamic>? ?? {};
      _passiveCount.clear();
      passiveMap.forEach((k, v) => _passiveCount[k] = (v as num).toDouble());

      final timeMap =
          doc.data()!['timeAffinity'] as Map<String, dynamic>? ?? {};
      _timeAffinity.clear();
      timeMap.forEach((k, v) => _timeAffinity[k] = (v as num).toDouble());

      preferencesChanged.value++;

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
    _passiveCount.clear();   // 🔧 取代 _searchScoreBuffer.clear()
    _timeAffinity.clear();
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'preferences.categories':  [],
      'preferences.cuisines':    [],
      'preferences.travelMode':  'walk',
      'preferences.budgetTier':  'budget',
      'preferences.topPriority': 'interest',
      'favouriteTypeCounts':   {},
      'passiveSignalCount':    {},   // 🔧 取代 'searchScoreBuffer': {}
      'timeAffinity':          {},
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
  }) => _enqueueLearningForCurrentUser(
    () => _updateFromFavouriteInternal(
      primaryType: primaryType,
      allTypes: allTypes,
      isFavouriting: isFavouriting,
    ),
  );

  Future<void> _updateFromFavouriteInternal({
    required String       primaryType,
    required List<String> allTypes,
    required bool         isFavouriting,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final List<String> involvedKeys = [];
    if (CategoryMapper.isLearnableCategory(primaryType)) {
      involvedKeys.add('cat_$primaryType');
      if (isFavouriting) {
        _recordTimeAffinity(primaryType, weight: 1.0); // 🆕
      }
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
      'preferences.categories': updatedCategories,
      'preferences.cuisines':   updatedCuisines,
      'favouriteTypeCounts':    _favouriteCount,
    });

    await _saveTimeAffinity(uid); // 🆕

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

  // ─────────────────────────────────────────────
  // Update from Post
  // 发帖 = 直接整数 +1（location），删帖 = -1
  // tag/topic 作为较弱的辅助信号，走 _passiveCount，不参与 gate
  // ─────────────────────────────────────────────

  Future<void> updateFromPost({
    required List<String> placeTypes,
    required List<String> postTags,
    required String?      postTopic,
    required SentimentLabel sentimentLabel,
    required int sentimentMatchedTokens,
    int postRating = 0,
  }) => _enqueueLearningForCurrentUser(
    () => _updateFromPostInternal(
      placeTypes: placeTypes,
      postTags: postTags,
      postTopic: postTopic,
      sentimentLabel: sentimentLabel,
      sentimentMatchedTokens: sentimentMatchedTokens,
      postRating: postRating,
    ),
  );

  Future<void> _updateFromPostInternal({
    required List<String> placeTypes,
    required List<String> postTags,
    required String?      postTopic,
    required SentimentLabel sentimentLabel,
    required int sentimentMatchedTokens,
    int postRating = 0,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (placeTypes.isEmpty && postTags.isEmpty && postTopic == null) return;

    final bool hasRating   = postRating > 0;
    final bool ratingPos   = postRating >= 4;
    final bool ratingNeg   = postRating <= 2;

    final bool sentimentConfident = sentimentMatchedTokens >= 2;
    final bool sentimentPos = sentimentConfident && sentimentLabel == SentimentLabel.positive;
    final bool sentimentNeg = sentimentConfident && sentimentLabel == SentimentLabel.negative;

    bool isPositive;
    bool isNegative;
    int  weight;

    if (hasRating) {
      if (!ratingPos && !ratingNeg) {
        print('🧠 updateFromPost: skipped (rating=3, neutral)');
        return;
      }
      isPositive = ratingPos;
      isNegative = ratingNeg;
      final agrees = (isPositive && sentimentPos) || (isNegative && sentimentNeg);
      weight = agrees ? 2 : 1;
    } else {
      if (!sentimentPos && !sentimentNeg) {
        print('🧠 updateFromPost: skipped (no rating, sentiment weak)');
        return;
      }
      isPositive = sentimentPos;
      isNegative = sentimentNeg;
      weight = 1;
    }

    // ── strongKeys：location → _favouriteCount，可 gate ──
    // 🔧 CHANGED: 不再自己维护只认 5 个字面量的 typeToCategory，
    // 改用 CategoryMapper.toPrimaryType(placeTypes) 算出真正的桶名，
    // 这样 cafe/museum/chinese_restaurant 这类帖子也能被正确学到。
    final List<String> strongKeys = [];
    if (placeTypes.isNotEmpty) {
      final resolvedCategory = CategoryMapper.toPrimaryType(placeTypes);
      if (CategoryMapper.isLearnableCategory(resolvedCategory)) {
        strongKeys.add('cat_$resolvedCategory');
        if (isPositive) _recordTimeAffinity(resolvedCategory, weight: weight.toDouble());
      }
    }
    for (final t in placeTypes) {
      final cuisine = _typeToCuisine[t];
      if (cuisine != null) { strongKeys.add('cui_$cuisine'); break; }
    }

    // ── weakKeys：tag/topic → _passiveCount，不 gate ──
    final List<String> weakKeys = [];
    for (final tag in postTags) {
      final cat = _tagToCategory[tag.toLowerCase()];
      if (cat != null) weakKeys.add('cat_$cat');
    }
    if (postTopic != null) {
      final cat = _topicToCategory[postTopic];
      if (cat != null) weakKeys.add('cat_$cat');
    }

    if (strongKeys.isEmpty && weakKeys.isEmpty) {
      print('🧠 updateFromPost: skipped (no recognized signal)');
      return;
    }

    for (final key in strongKeys) {
      _favouriteCount[key] = isPositive
          ? (_favouriteCount[key] ?? 0) + weight
          : ((_favouriteCount[key] ?? 0) - weight).clamp(0, 999);
    }
    for (final key in weakKeys) {
      final delta = _wPostTag * weight;
      _passiveCount[key] = isPositive
          ? (_passiveCount[key] ?? 0) + delta
          : ((_passiveCount[key] ?? 0) - delta).clamp(0, 999);
    }

    final updatedCategories = List<String>.from(_prefs.categories);
    final updatedCuisines   = List<String>.from(_prefs.cuisines);
    _applyGate(updatedCategories, updatedCuisines); // 只吃 _favouriteCount，weakKeys 不影响 gate

    _prefs = _prefs.copyWith(categories: updatedCategories, cuisines: updatedCuisines);

    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'preferences.categories': updatedCategories,
      'preferences.cuisines':   updatedCuisines,
      'favouriteTypeCounts':    _favouriteCount,
      'passiveSignalCount':     _passiveCount,
    });

    await _saveTimeAffinity(uid);

    print('🧠 updateFromPost: strong=$strongKeys weak=$weakKeys '
        'categories=$updatedCategories cuisines=$updatedCuisines');
  }
  
// ─────────────────────────────────────────────
  // Update from Like post
  // location 信号 +0.7 / -0.7，tag/topic 信号 +0.3 / -0.3，
  // 全部写入 _passiveCount，不参与 gate（不能单靠点赞让偏好转正）
  // ─────────────────────────────────────────────

  Future<void> updateFromLike({
    required List<String>   placeTypes,
    required List<String>   postTags,
    required String?        postTopic,
    required bool           isLiking,
    required SentimentLabel sentimentLabel,
    required int            sentimentMatchedTokens,
  }) => _enqueueLearningForCurrentUser(
    () => _updateFromLikeInternal(
      placeTypes: placeTypes,
      postTags: postTags,
      postTopic: postTopic,
      isLiking: isLiking,
      sentimentLabel: sentimentLabel,
      sentimentMatchedTokens: sentimentMatchedTokens,
    ),
  );

  Future<void> _updateFromLikeInternal({
    required List<String>   placeTypes,
    required List<String>   postTags,
    required String?        postTopic,
    required bool           isLiking,
    required SentimentLabel sentimentLabel,
    required int             sentimentMatchedTokens,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (placeTypes.isEmpty && postTags.isEmpty && postTopic == null) return;

    if (sentimentLabel != SentimentLabel.positive) {
      print('🧠 updateFromLike: skipped (sentiment not positive)');
      return;
    }
    if (sentimentMatchedTokens < 2) {
      print('🧠 updateFromLike: skipped (low confidence)');
      return;
    }

    final locationKeys = <String>{};
    for (final t in placeTypes) {
      final cat = CategoryMapper.toPrimaryType([t]);
      if (CategoryMapper.isLearnableCategory(cat)) locationKeys.add('cat_$cat');
      final cuisine = _typeToCuisine[t];
      if (cuisine != null) locationKeys.add('cui_$cuisine');
    }

    final tagKeys = <String>{};
    for (final tag in postTags) {
      final cat = _tagToCategory[tag.toLowerCase()];
      if (cat != null) tagKeys.add('cat_$cat');
    }
    if (postTopic != null) {
      final cat = _topicToCategory[postTopic];
      if (cat != null) tagKeys.add('cat_$cat');
    }

    if (locationKeys.isEmpty && tagKeys.isEmpty) return;

    for (final key in locationKeys) {
      final delta = _wLikeLocation;
      _passiveCount[key] = isLiking
          ? (_passiveCount[key] ?? 0) + delta
          : ((_passiveCount[key] ?? 0) - delta).clamp(0, 999);
      if (isLiking && key.startsWith('cat_')) {
        _recordTimeAffinity(key.substring(4), weight: delta);
      }
    }
    for (final key in tagKeys) {
      final delta = _wLikeTag;
      _passiveCount[key] = isLiking
          ? (_passiveCount[key] ?? 0) + delta
          : ((_passiveCount[key] ?? 0) - delta).clamp(0, 999);
    }

    await _savePassiveCount(uid);
    await _saveTimeAffinity(uid);

    print('✅ updateFromLike: location=$locationKeys tags=$tagKeys isLiking=$isLiking');
  }

// ─────────────────────────────────────────────
  // Update from Search (点击搜索结果里的帖子)
  // location 信号 +0.5，tag/topic 信号 +0.2，
  // 全部写入 _passiveCount，不参与 gate
  // ─────────────────────────────────────────────

  Future<void> updateFromSearch({
    required List<String> placeTypes,
    required List<String> postTags,
    required String?      postTopic,
  }) => _enqueueLearningForCurrentUser(
    () => _updateFromSearchInternal(
      placeTypes: placeTypes,
      postTags: postTags,
      postTopic: postTopic,
    ),
  );

  Future<void> _updateFromSearchInternal({
    required List<String> placeTypes,  // 🆕
    required List<String> postTags,
    required String?      postTopic,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (placeTypes.isEmpty && postTags.isEmpty && postTopic == null) return;

    final locationKeys = <String>{};
    for (final t in placeTypes) {
      final cat = CategoryMapper.toPrimaryType([t]);
      if (CategoryMapper.isLearnableCategory(cat)) locationKeys.add('cat_$cat');
      final cuisine = _typeToCuisine[t];
      if (cuisine != null) locationKeys.add('cui_$cuisine');
    }

    final tagKeys = <String>{};
    for (final tag in postTags) {
      final cat = _tagToCategory[tag.toLowerCase()];
      if (cat != null) tagKeys.add('cat_$cat');
    }
    if (postTopic != null) {
      final cat = _topicToCategory[postTopic];
      if (cat != null) tagKeys.add('cat_$cat');
    }

    if (locationKeys.isEmpty && tagKeys.isEmpty) return;

    for (final key in locationKeys) {
      _passiveCount[key] = (_passiveCount[key] ?? 0) + _wSearchLocation;
      if (key.startsWith('cat_')) {
        _recordTimeAffinity(key.substring(4), weight: _wSearchLocation);
      }
    }
    for (final key in tagKeys) {
      _passiveCount[key] = (_passiveCount[key] ?? 0) + _wSearchTag;
    }

    await _savePassiveCount(uid);
    await _saveTimeAffinity(uid);

    print('✅ updateFromSearch: location=$locationKeys tags=$tagKeys');
  }


  // ─────────────────────────────────────────────
  // Update from Place View (点开某个 place detail)
  // 最高频、最轻信号 — 只用来学 time affinity，
  // 不学 category/cuisine（点进去看不代表真的喜欢，
  // category 学习还是交给 favourite/post/like 这些
  // 更明确的信号，避免被无关兴趣的点击污染）
  // ─────────────────────────────────────────────

  Future<void> updateFromPlaceView({
    required String?      primaryType,
    required List<String> allTypes,
  }) => _enqueueLearningForCurrentUser(
    () => _updateFromPlaceViewInternal(
      primaryType: primaryType,
      allTypes: allTypes,
    ),
  );

  Future<void> _updateFromPlaceViewInternal({
    required String?      primaryType,
    required List<String> allTypes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // 🔧 FIX: primaryType 传进来的是 Google raw type（如 'western_restaurant'），
    // 不是 CategoryMapper 认的桶名（如 'restaurant'）。之前直接拿 raw type
    // 去问 isLearnableCategory，永远匹配不上，导致所有细分类型全部被跳过。
    // 现在改成跟 updateFromPost 一样，先用 CategoryMapper.toPrimaryType()
    // 把 raw types 解析成桶名，再判断能不能学。
    final allRawTypes = [
      if (primaryType != null) primaryType,
      ...allTypes,
    ];
    if (allRawTypes.isEmpty) {
      print('👁️ updateFromPlaceView: skipped (no types)');
      return;
    }

    final resolvedCategory = CategoryMapper.toPrimaryType(allRawTypes);

    if (!CategoryMapper.isLearnableCategory(resolvedCategory)) {
      print('👁️ updateFromPlaceView: skipped ($primaryType → $resolvedCategory, not learnable)');
      return;
    }

    print('👁️ updateFromPlaceView: recording $resolvedCategory (raw: $primaryType)');
    _recordTimeAffinity(resolvedCategory, weight: 0.3);
    await _saveTimeAffinity(uid);
  }

  Future<void> _savePassiveCount(String uid) async {
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'passiveSignalCount': _passiveCount,
    });
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

  // ─────────────────────────────────────────────
  // Time affinity — 记录用户在某个时段对某个 category
  // 表现出的兴趣，权重依信号强弱而不同
  // ─────────────────────────────────────────────

  String _currentPeriod() {
    final hour = DateTime.now().hour;
    if (hour >= 6  && hour < 11) return 'morning';
    if (hour >= 11 && hour < 14) return 'lunch';
    if (hour >= 14 && hour < 17) return 'afternoon';
    if (hour >= 17 && hour < 20) return 'evening';
    return 'night';
  }

  void _recordTimeAffinity(String category, {required double weight}) {
    final period = _currentPeriod();
    final key = 'timeAffinity_${category}_$period';
    _timeAffinity[key] = (_timeAffinity[key] ?? 0.0) + weight;
    print('⏰ _recordTimeAffinity: $key += $weight → now ${_timeAffinity[key]!.toStringAsFixed(2)} '
        '(need $_minCountToLearnTime to unlock personal score)');
  }

  Future<void> _saveTimeAffinity(String uid) async {
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'timeAffinity': _timeAffinity,
    });
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
    WeatherCondition?     weather,
    String?               travelMode,
    bool                  useCurrentTime = true,
  }) {
    final interest = _interestMatchScore(primaryType, allTypes);
    final distance = _distanceScore(
      distanceMeters,
      travelMode: travelMode,
    );
    final ratingS  = _ratingScore(rating);
    final time = useCurrentTime
        ? _timeSuitabilityScore(primaryType, allTypes)
        : 0.5;
    final budget   = _budgetSuitabilityScore(priceLevel);
    final weatherS = _weatherScore(weather, primaryType, allTypes);

    final w = _resolveWeights(); // 🆕

    final total = (
        (w['interest'] ?? 0.30) * interest
      + (w['distance'] ?? 0.20) * distance
      + 0.15 * weatherS   // weather 固定，不受用户排序影响
      + (w['rating']   ?? 0.15) * ratingS
      + 0.10 * time       // time 固定，不受用户排序影响
      + (w['budget']   ?? 0.10) * budget
    ).clamp(0.0, 1.0);

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

    final specific = CategoryMapper.isOutdoorBySpecificType(allTypes);
    final isOutdoor = specific ??
        (primaryType != null && CategoryMapper.outdoorFallbackBuckets.contains(primaryType));

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

    double passiveScore(double count) {
      const maxPassive = 8.0;
      return 0.2 * count.clamp(0, maxPassive) / maxPassive;
    }

    final scores = <double>[];

    if (primaryType != null && CategoryMapper.isLearnableCategory(primaryType)) {
      if (_prefs.categories.contains(primaryType)) scores.add(1.0);
      final cnt = _favouriteCount['cat_$primaryType'] ?? 0;
      final cs  = countToScore(cnt);
      if (cs > 0) scores.add(cs);

      final passiveCnt = _passiveCount['cat_$primaryType'] ?? 0.0;
      if (passiveCnt > 0) scores.add(0.5 + passiveScore(passiveCnt)); // 🔧 passiveBoost → passiveScore
    }

    for (final t in allTypes) {
      final cuisine = _typeToCuisine[t];
      if (cuisine != null) {
        if (_prefs.cuisines.contains(cuisine)) scores.add(1.0);
        final cnt = _favouriteCount['cui_$cuisine'] ?? 0;
        final cs  = countToScore(cnt);
        if (cs > 0) scores.add(cs);

        final passiveCnt = _passiveCount['cui_$cuisine'] ?? 0.0;
        if (passiveCnt > 0) scores.add(0.5 + passiveScore(passiveCnt)); // 🔧 同上
        break;
      }
    }

    if (scores.isEmpty) return 0.5;
    return (scores.reduce((a, b) => a + b) / scores.length).clamp(0.0, 1.0);
  }
  
  double _distanceScore(
    double? distanceMeters, {
    String? travelMode,
  }) {
    if (distanceMeters == null || distanceMeters <= 0) return 0.5;

    final resolvedTravelMode = travelMode ?? _prefs.travelMode;
    final baseline = _distanceBaselineForMode(resolvedTravelMode);
    final score = (1.0 - distanceMeters / baseline).clamp(0.0, 1.0);

    print('📏 _distanceScore: mode=$resolvedTravelMode, baseline=${baseline}m, '
        'dist=${distanceMeters.toStringAsFixed(0)}m → score=${score.toStringAsFixed(2)}');
    return score;
  }

  double _distanceBaselineForMode(String mode) {
    switch (mode) {
      case 'walk':
        return 2000.0;

      case 'motor':
        return 8000.0;

      case 'drive':
        return 12000.0;

      case 'both':
        return 12000.0;

      default:
        return 12000.0;
    }
  }

  double _ratingScore(double? rating) {
    if (rating == null) return 0.5;
    return ((rating - 2.0) / 3.0).clamp(0.0, 1.0);
  }

  double _timeSuitabilityScore(String? primaryType, List<String> allTypes) {
    final period = _currentPeriod();

    final personal = _personalTimeScore(primaryType, allTypes, period);
    if (personal != null) {
      print('🎯 PERSONAL time score [$primaryType/$period] = ${personal.toStringAsFixed(2)}');
      return personal;
    }

    // global fallback 先不打印，太吵
    return _globalTimeSuitability(primaryType, allTypes, period);
  }

  double? _personalTimeScore(
    String? primaryType,
    List<String> allTypes,
    String period,
  ) {
    final candidates = <String>[
      if (primaryType != null) primaryType,
      ...allTypes,
    ];
    for (final t in candidates) {
      final key   = 'timeAffinity_${t}_$period';
      final score = _timeAffinity[key] ?? 0.0;
      if (score >= _minCountToLearnTime) {
        const maxScore = 15.0;
        final clamped = score.clamp(_minCountToLearnTime, maxScore);
        final result = 0.6 + 0.4 * (clamped - _minCountToLearnTime) /
            (maxScore - _minCountToLearnTime);
        print('   ✓ found unlocked key "$key" = ${score.toStringAsFixed(2)} → score ${result.toStringAsFixed(2)}');
        return result;
      } else if (score > 0) {
        print('   … key "$key" = ${score.toStringAsFixed(2)} '
            '(need ${(_minCountToLearnTime - score).toStringAsFixed(2)} more to unlock)');
      }
    }
    return null;
  }

  double _globalTimeSuitability(String? primaryType, List<String> allTypes, String period) {
    final specificMap = CategoryMapper.specificTimeSuitability[period]!;
    for (final t in allTypes) {
      if (specificMap.containsKey(t)) return specificMap[t]!;
    }

    final bucketMap = CategoryMapper.bucketTimeSuitability[period]!;
    if (primaryType != null && bucketMap.containsKey(primaryType)) {
      return bucketMap[primaryType]!;
    }
    for (final t in allTypes) {
      if (bucketMap.containsKey(t)) return bucketMap[t]!;
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

  // ─────────────────────────────────────────────
// Weight personalization — 用户在 onboarding 选的
// "最看重什么"，决定这 4 项的权重分配。
// weather/time 不给用户选，保持固定权重。
// ─────────────────────────────────────────────

  Map<String, double> _resolveWeights() {
    // 默认顺序（现有写死权重的原始排序）
    const defaultOrder  = ['interest', 'distance', 'rating', 'budget'];
    const weightSlots   = [0.30, 0.20, 0.15, 0.10]; // 按顺序分配

    final chosen = _prefs.topPriority;
    final order = List<String>.from(defaultOrder);

    // 把用户选中的那项挪到最前面，其余保持原有相对顺序
    if (order.contains(chosen)) {
      order.remove(chosen);
      order.insert(0, chosen);
    }

    final weights = <String, double>{};
    for (int i = 0; i < order.length; i++) {
      weights[order[i]] = weightSlots[i];
    }
    return weights;
  }


  double scorePlaceModel({
    required String?      primaryType,
    required List<String> allTypes,
    double?               distanceMeters,
    double?               rating,
    int?                  priceLevel,
    WeatherCondition?     weather,
    String?               travelMode,
    bool                  useCurrentTime = true,
  }) =>
      recommendationScore(
        primaryType:    primaryType,
        allTypes:       allTypes,
        rating:         rating,
        distanceMeters: distanceMeters,
        priceLevel:     priceLevel,
        weather:        weather,
        travelMode:     travelMode,
        useCurrentTime: useCurrentTime,
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

  void clearLocalSession() {
    _prefs = UserPreferences.empty();

    _favouriteCount.clear();
    _passiveCount.clear();
    _timeAffinity.clear();

    preferencesChanged.value++;
  }

}


