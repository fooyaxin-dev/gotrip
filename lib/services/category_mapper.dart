// lib/services/category_mapper.dart
//
// 唯一的地点分类来源——以 Nearby 页面为准，全 app 统一。
// 7 个可见桶 + 1 个排除桶：
//   restaurant / park / tourist_attraction / shopping_mall /
//   entertainment / transit / service / other

class CategoryMapper {
  CategoryMapper._();

  static const lodgingTypes = [
    'hotel', 'lodging', 'resort_hotel', 'motel', 'guest_house',
    'hostel', 'bed_and_breakfast', 'extended_stay_hotel', 'inn',
  ];

  static const restaurantTypes = [
    'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
    'fast_food_restaurant', 'food_court', 'dessert_shop',
    'meal_takeaway', 'meal_delivery',
    'chinese_restaurant', 'malaysian_restaurant', 'malay_restaurant',
    'indian_restaurant', 'western_restaurant', 'american_restaurant',
    'japanese_restaurant', 'korean_restaurant', 'thai_restaurant',
    'italian_restaurant', 'vietnamese_restaurant', 'seafood_restaurant',
    'vegetarian_restaurant', 'buffet_restaurant', 'steak_house',
    'sushi_restaurant', 'pizza_restaurant', 'ramen_restaurant',
  ];

  static const transitTypes = [
    'subway_station', 'bus_station', 'bus_stop', 'transit_station',
    'light_rail_station', 'taxi_stand', 'train_station',
  ];

  static const serviceTypes = [
    'hospital', 'doctor', 'medical_clinic', 'bank', 'atm', 'post_office',
  ];

  static const shoppingTypes = [
    'shopping_mall', 'supermarket', 'grocery_store', 'department_store',
    'clothing_store', 'electronics_store', 'pharmacy', 'book_store',
    'convenience_store', 'market',
  ];

  static const entertainmentTypes = [
    'movie_theater', 'amusement_park', 'bowling_alley', 'karaoke',
    'video_arcade', 'night_club', 'amusement_center', 'concert_hall',
    'gym', 'fitness_center', 'spa',
  ];

  static const entertainmentTypesForItinerary = [
    'movie_theater', 'amusement_park', 'bowling_alley',
    'karaoke', 'video_arcade', 'amusement_center',
  ];

  static const attractionTypes = [
    'tourist_attraction', 'historical_landmark', 'monument',
    'museum', 'art_gallery',
  ];

  static const natureTypes = [
    'park', 'national_park', 'botanical_garden', 'garden',
    'hiking_area', 'beach',
  ];

  /// Google 原始 types → primaryType。全 app 唯一入口。
  static String toPrimaryType(List<String> googleTypes) {
    if (googleTypes.any(lodgingTypes.contains))       return 'other';
    if (googleTypes.any(restaurantTypes.contains))    return 'restaurant';
    if (googleTypes.any(transitTypes.contains))       return 'transit';
    if (googleTypes.any(serviceTypes.contains))       return 'service';
    if (googleTypes.any(shoppingTypes.contains))      return 'shopping_mall';
    if (googleTypes.any(entertainmentTypes.contains)) return 'entertainment';
    if (googleTypes.any(attractionTypes.contains))    return 'tourist_attraction';
    if (googleTypes.any(natureTypes.contains))        return 'park';
    return 'other';
  }

  static const learnableCategories = {
    'restaurant', 'park', 'tourist_attraction', 'shopping_mall', 'entertainment',
  };
  static bool isLearnableCategory(String primaryType) =>
      learnableCategories.contains(primaryType);

  static String toDisplayCategory(String type) {
    if (type == 'restaurant'         || restaurantTypes.contains(type)) return 'Food';
    if (type == 'park'               || natureTypes.contains(type))     return 'Nature';
    if (type == 'tourist_attraction' || attractionTypes.contains(type)) return 'Attraction';
    if (type == 'shopping_mall'      || shoppingTypes.contains(type))   return 'Shopping';
    if (type == 'transit'            || transitTypes.contains(type))    return 'Transport';
    return 'Others';
  }

  static String toAchievementCategory(String type) {
    if (type == 'restaurant'         || restaurantTypes.contains(type)) return 'Food';
    if (type == 'park'               || natureTypes.contains(type))     return 'Nature';
    if (type == 'tourist_attraction' || attractionTypes.contains(type)) return 'Attraction';
    return 'Other';
  }

  // ═══════════════════════════════════════════════════════════════════
  // 🆕 Outdoor / Indoor 判断 —— 给 weather score 用，具体类型级别，
  // 比 primaryType 粗桶精确（entertainment/tourist_attraction 桶本身
  // 混装了室内室外，不能整桶当 outdoor 或 indoor）。
  // ═══════════════════════════════════════════════════════════════════

  static const Set<String> outdoorTypes = {
    ...natureTypes,                         // park/national_park/garden/beach/hiking_area
    'historical_landmark', 'monument',      // attractionTypes 里的户外部分
    'amusement_park',                       // entertainmentTypes 里唯一 outdoor 的
    'stadium',
  };

  static const Set<String> indoorTypes = {
    ...restaurantTypes,
    ...shoppingTypes,
    'museum', 'art_gallery',                // attractionTypes 里的室内部分
    'movie_theater', 'bowling_alley', 'karaoke', 'video_arcade',
    'night_club', 'amusement_center', 'concert_hall',
    'gym', 'fitness_center', 'spa',         // entertainmentTypes 剩余部分
    'hindu_temple', 'buddhist_temple', 'shrine', 'mosque', 'surau', 'church',
  };

  /// 返回 true=outdoor, false=indoor, null=没查到具体类型
  /// （查不到时调用方应 fallback 到 outdoorFallbackBuckets）
  static bool? isOutdoorBySpecificType(List<String> allTypes) {
    for (final t in allTypes) {
      if (outdoorTypes.contains(t)) return true;
      if (indoorTypes.contains(t)) return false;
    }
    return null;
  }

  /// primaryType 粗桶 fallback——只留 park，本身比较可靠；
  /// tourist_attraction / entertainment 桶不能再无脑当 outdoor。
  static const Set<String> outdoorFallbackBuckets = {'park'};

  // ═══════════════════════════════════════════════════════════════════
  // 🆕 Time suitability —— 给 time score 用，具体类型优先于粗桶，
  // 避免像 cafe 被 restaurant 桶抢答（cafe 的 primaryType 也是
  // 'restaurant'，如果先查桶会导致 cafe 专属分数变成死代码）。
  // ═══════════════════════════════════════════════════════════════════

  static const Map<String, Map<String, double>> specificTimeSuitability = {
    'morning':   {'cafe': 1.0, 'coffee_shop': 1.0, 'movie_theater': 0.2, 'karaoke': 0.2},
    'lunch':     {'cafe': 0.5, 'coffee_shop': 0.5},
    'afternoon': {'museum': 1.0, 'art_gallery': 1.0, 'movie_theater': 0.6},
    'evening':   {'movie_theater': 0.9, 'karaoke': 0.8},
    'night':     {
      'movie_theater': 1.0, 'karaoke': 1.0, 'bowling_alley': 0.9,
      'gym': 0.1, 'fitness_center': 0.1, 'spa': 0.2,
    },
  };

  static const Map<String, Map<String, double>> bucketTimeSuitability = {
    'morning':   {'restaurant': 0.6, 'park': 0.8, 'tourist_attraction': 0.7},
    'lunch':     {'restaurant': 1.0, 'shopping_mall': 0.4},
    'afternoon': {'tourist_attraction': 1.0, 'park': 1.0, 'shopping_mall': 0.9, 'entertainment': 0.8, 'restaurant': 0.3},
    'evening':   {'restaurant': 1.0, 'shopping_mall': 0.7, 'entertainment': 0.8},
    'night':     {'entertainment': 1.0, 'restaurant': 0.7},
  };
}