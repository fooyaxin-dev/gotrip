class CategoryImageHelper {

  static String getAssetPath(String? primaryType, List<String> allTypes) {
    switch (primaryType) {
      case 'restaurant':    return _getFoodAsset(allTypes);
      case 'park':          return _getNatureAsset(allTypes);
      case 'entertainment': return _getEntertainAsset(allTypes);
      case 'shopping_mall': return _getShoppingAsset(allTypes);
      case 'transit':       return _getTransportAsset(allTypes);
      case 'service':       return _getServiceAsset(allTypes);
      default:              return 'assets/images/category/food/food_all.png';
    }
  }

  // ── Food ──────────────────────────────────────────────────────────────────
  static String _getFoodAsset(List<String> types) {
    if (types.contains('chinese_restaurant'))   return 'assets/images/category/food/food_chinese.png';
    if (types.contains('malaysian_restaurant')) return 'assets/images/category/food/food_malay.png';
    if (types.contains('indian_restaurant'))    return 'assets/images/category/food/food_indian.png';
    if (types.contains('japanese_restaurant'))  return 'assets/images/category/food/food_japanese.png';
    if (types.contains('korean_restaurant'))    return 'assets/images/category/food/food_korean.png';
    if (types.contains('western_restaurant') ||
        types.contains('american_restaurant'))  return 'assets/images/category/food/food_western.png';
    if (types.contains('dessert_shop')      ||
        types.contains('ice_cream_shop')    ||
        types.contains('bakery'))               return 'assets/images/category/food/food_dessert.png';
    if (types.contains('cafe')              ||
        types.contains('coffee_shop'))          return 'assets/images/category/food/food_cafe.png';
    return 'assets/images/category/food/food_all.png';
  }

  // ── Nature ────────────────────────────────────────────────────────────────
  static String _getNatureAsset(List<String> types) {
    if (types.contains('beach'))                return 'assets/images/category/nature/park_beach.png';
    if (types.contains('hiking_area')       ||
        types.contains('national_park'))        return 'assets/images/category/nature/park_hiking.png';
    if (types.contains('botanical_garden'))     return 'assets/images/category/nature/park_garden.png';
    if (types.contains('museum')            ||
        types.contains('art_gallery'))          return 'assets/images/category/nature/park_museum.png';
    if (types.contains('mosque'))               return 'assets/images/category/nature/park_mosque.png';
    if (types.contains('hindu_temple')      ||
        types.contains('buddhist_temple')   ||
        types.contains('shrine'))               return 'assets/images/category/nature/park_temple.png';
    if (types.contains('church'))               return 'assets/images/category/nature/park_all.png'; // no church img → fallback
    if (types.contains('tourist_attraction') ||
        types.contains('historical_landmark')||
        types.contains('monument'))             return 'assets/images/category/nature/park_landmark.png';
    if (types.contains('park'))                 return 'assets/images/category/nature/park_park.png';
    return 'assets/images/category/nature/park_all.png';
  }

  // ── Entertainment ─────────────────────────────────────────────────────────
  static String _getEntertainAsset(List<String> types) {
    if (types.contains('movie_theater'))        return 'assets/images/category/entertain/entertainment_cinema.png';
    if (types.contains('karaoke'))              return 'assets/images/category/entertain/entertainment_karaoke.png';
    if (types.contains('bowling_alley'))        return 'assets/images/category/entertain/entertainment_bowling.png';
    if (types.contains('video_arcade')      ||
        types.contains('amusement_center'))     return 'assets/images/category/entertain/entertainment_gaming.png';
    if (types.contains('amusement_park')    ||
        types.contains('theme_park'))           return 'assets/images/category/entertain/entertainment_theme_park.png';
    if (types.contains('sports_complex')    ||
        types.contains('stadium')           ||
        types.contains('fitness_center')    ||
        types.contains('gym'))                  return 'assets/images/category/entertain/entertainment_sports.png';
    if (types.contains('spa')               ||
        types.contains('beauty_salon'))         return 'assets/images/category/entertain/entertainment_spa.png';
    return 'assets/images/category/entertain/entertainment_all.png';
  }

  // ── Shopping ──────────────────────────────────────────────────────────────
  static String _getShoppingAsset(List<String> types) {
    if (types.contains('supermarket')       ||
        types.contains('grocery_store'))        return 'assets/images/category/shopping/shopping_supermarket.png';
    if (types.contains('pharmacy')          ||
        types.contains('drugstore'))            return 'assets/images/category/shopping/shopping_pharmacy.png';
    if (types.contains('clothing_store')    ||
        types.contains('shoe_store'))           return 'assets/images/category/shopping/shopping_fashion.png';
    if (types.contains('electronics_store') ||
        types.contains('cell_phone_store'))     return 'assets/images/category/shopping/shopping_electronics.png';
    if (types.contains('market')            ||
        types.contains('flea_market'))          return 'assets/images/category/shopping/shopping_market.png';
    if (types.contains('shopping_mall')     ||
        types.contains('department_store'))     return 'assets/images/category/shopping/shopping_mall.png';
    return 'assets/images/category/shopping/shopping_all.png';
  }

  // ── Transport ─────────────────────────────────────────────────────────────
  static String _getTransportAsset(List<String> types) {
    if (types.contains('subway_station')    ||
        types.contains('light_rail_station')||
        types.contains('transit_station')   ||
        types.contains('train_station'))        return 'assets/images/category/transport/transit_lrt_mrt.png';
    if (types.contains('bus_station')       ||
        types.contains('bus_stop'))             return 'assets/images/category/transport/transit_bus.png';
    if (types.contains('taxi_stand'))           return 'assets/images/category/transport/transit_taxi.png';
    return 'assets/images/category/transport/transit_all.png';
  }

  // ── Service ───────────────────────────────────────────────────────────────
  static String _getServiceAsset(List<String> types) {
    if (types.contains('hospital')          ||
        types.contains('medical_clinic')    ||
        types.contains('doctor'))               return 'assets/images/category/service/service_hospital.png';
    if (types.contains('bank')              ||
        types.contains('atm'))                  return 'assets/images/category/service/service_bank.png';
    if (types.contains('post_office'))          return 'assets/images/category/service/service_post.png';
    return 'assets/images/category/service/service_all.png';
  }
}