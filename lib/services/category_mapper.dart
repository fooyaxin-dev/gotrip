// lib/services/category_mapper.dart
//
// 唯一的地点分类映射来源 —— Dashboard 和 Achievement 都用这一份，
// 不再各自维护一套容易产生分歧的分类常量。

class CategoryMapper {
  CategoryMapper._();

  static const foodTypes = [
    'restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar',
    'fast_food_restaurant', 'food_court', 'dessert_shop',
  ];
  static const natureTypes = [
    'park', 'national_park', 'botanical_garden', 'garden',
    'hiking_area', 'beach',
  ];
  static const attractionTypes = [
    'tourist_attraction', 'historical_landmark', 'monument',
    'museum', 'art_gallery',
  ];
  static const shoppingTypes = [
    'shopping_mall', 'supermarket', 'grocery_store',
    'department_store', 'clothing_store',
  ];
  static const transportTypes = [
    'subway_station', 'bus_station', 'bus_stop',
    'transit_station', 'train_station',
  ];

  /// 通用分类 —— 给 Dashboard 图表用（Food/Nature/Attraction/Shopping/Transport/Others）
  static String toDisplayCategory(String primaryType) {
    if (foodTypes.contains(primaryType))       return 'Food';
    if (natureTypes.contains(primaryType))     return 'Nature';
    if (attractionTypes.contains(primaryType)) return 'Attraction';
    if (shoppingTypes.contains(primaryType))   return 'Shopping';
    if (transportTypes.contains(primaryType))  return 'Transport';
    return 'Others';
  }

  /// 成就用的三分类 —— 给 AchievementService 用（Food/Nature/Attraction/Other）
  static String toAchievementCategory(String primaryType) {
    if (foodTypes.contains(primaryType))       return 'Food';
    if (natureTypes.contains(primaryType))     return 'Nature';
    if (attractionTypes.contains(primaryType)) return 'Attraction';
    return 'Other';
  }
}