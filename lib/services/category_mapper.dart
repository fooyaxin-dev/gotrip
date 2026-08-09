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
    // 🆕 Google 常见的"菜系_restaurant"命名变体 —— 之前没收进来，
    // 会导致这些地点被 toPrimaryType() 误判成 'other'，
    // 连带影响 favourite/post/placeView 的学习和 buildForYouList 的匹配
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

  /// 行程生成专属的候选子集——故意排除 gym/fitness_center/spa/
  /// night_club/concert_hall，这些更像日常场所，不该被排进 Day X 的行程。
  /// Nearby 页面本身仍用完整的 [entertainmentTypes]。
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

  /// 推荐/学习算法认得的 5 个分类（UserPreferenceService 用）。
  /// transit / service / other 不构成任何兴趣信号。
  static const learnableCategories = {
    'restaurant', 'park', 'tourist_attraction', 'shopping_mall', 'entertainment',
  };
  static bool isLearnableCategory(String primaryType) =>
      learnableCategories.contains(primaryType);

  // ── 展示层分类（Dashboard 用）──────────────────────────────────────
  // 兼容两种输入：primaryType 桶名，或收藏记录里存的单个原始 Google type。
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
}