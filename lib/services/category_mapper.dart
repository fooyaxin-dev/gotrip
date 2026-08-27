class CategoryMapper {
  CategoryMapper._();

  // ─────────────────────────────────────────────
  // Raw Google type groups
  // ─────────────────────────────────────────────

  static const lodgingTypes = [
    'hotel',
    'lodging',
    'resort_hotel',
    'motel',
    'guest_house',
    'hostel',
    'bed_and_breakfast',
    'extended_stay_hotel',
    'inn',
  ];

  static const restaurantTypes = [
    'restaurant',
    'cafe',
    'coffee_shop',
    'bakery',
    'bar',
    'fast_food_restaurant',
    'food_court',
    'dessert_shop',
    'meal_takeaway',
    'meal_delivery',
    'chinese_restaurant',
    'malaysian_restaurant',
    'malay_restaurant',
    'indian_restaurant',
    'western_restaurant',
    'american_restaurant',
    'japanese_restaurant',
    'korean_restaurant',
    'thai_restaurant',
    'italian_restaurant',
    'vietnamese_restaurant',
    'seafood_restaurant',
    'vegetarian_restaurant',
    'buffet_restaurant',
    'steak_house',
    'sushi_restaurant',
    'pizza_restaurant',
    'ramen_restaurant',
  ];

  static const transitTypes = [
    'subway_station',
    'bus_station',
    'bus_stop',
    'transit_station',
    'light_rail_station',
    'taxi_stand',
    'train_station',
  ];

  static const serviceTypes = [
    'hospital',
    'doctor',
    'medical_clinic',
    'bank',
    'atm',
    'post_office',
  ];

  static const shoppingTypes = [
    'shopping_mall',
    'supermarket',
    'grocery_store',
    'department_store',
    'clothing_store',
    'electronics_store',
    'pharmacy',
    'book_store',
    'convenience_store',
    'market',
  ];

  static const entertainmentTypes = [
    'movie_theater',
    'amusement_park',
    'bowling_alley',
    'karaoke',
    'video_arcade',
    'night_club',
    'amusement_center',
    'concert_hall',
    'gym',
    'fitness_center',
    'spa',
  ];

  static const entertainmentTypesForItinerary = [
    'movie_theater',
    'amusement_park',
    'bowling_alley',
    'karaoke',
    'video_arcade',
    'amusement_center',
  ];

  static const attractionTypes = [
    'tourist_attraction',
    'historical_landmark',
    'monument',
    'museum',
    'art_gallery',
  ];

  static const natureTypes = [
    'park',
    'national_park',
    'botanical_garden',
    'garden',
    'hiking_area',
    'beach',
  ];

  // ─────────────────────────────────────────────
  // Canonical primary category
  // ─────────────────────────────────────────────

  /// Google raw types -> canonical primaryType.
  ///
  /// This is the single source of truth for category classification.
  static String toPrimaryType(
    List<String> googleTypes,
  ) {
    if (googleTypes.any(lodgingTypes.contains)) {
      return 'other';
    }

    if (googleTypes.any(restaurantTypes.contains)) {
      return 'restaurant';
    }

    if (googleTypes.any(transitTypes.contains)) {
      return 'transit';
    }

    if (googleTypes.any(serviceTypes.contains)) {
      return 'service';
    }

    if (googleTypes.any(shoppingTypes.contains)) {
      return 'shopping_mall';
    }

    if (googleTypes.any(entertainmentTypes.contains)) {
      return 'entertainment';
    }

    if (googleTypes.any(attractionTypes.contains)) {
      return 'tourist_attraction';
    }

    if (googleTypes.any(natureTypes.contains)) {
      return 'park';
    }

    return 'other';
  }

  /// Resolves a place into the canonical app category.
  ///
  /// Prefer allTypes because it contains the detailed Google types.
  /// primaryType is only used as a fallback for older/incomplete data.
  static String resolvePrimaryType(
    String? primaryType,
    List<String> allTypes,
  ) {
    if (allTypes.isNotEmpty) {
      return toPrimaryType(allTypes);
    }

    if (primaryType == null ||
        primaryType.trim().isEmpty) {
      return 'other';
    }

    if (primaryType == 'restaurant' ||
        restaurantTypes.contains(primaryType)) {
      return 'restaurant';
    }

    if (primaryType == 'park' ||
        natureTypes.contains(primaryType)) {
      return 'park';
    }

    if (primaryType == 'tourist_attraction' ||
        attractionTypes.contains(primaryType)) {
      return 'tourist_attraction';
    }

    if (primaryType == 'shopping_mall' ||
        shoppingTypes.contains(primaryType)) {
      return 'shopping_mall';
    }

    if (primaryType == 'entertainment' ||
        entertainmentTypes.contains(primaryType)) {
      return 'entertainment';
    }

    if (primaryType == 'transit' ||
        transitTypes.contains(primaryType)) {
      return 'transit';
    }

    if (primaryType == 'service' ||
        serviceTypes.contains(primaryType)) {
      return 'service';
    }

    return 'other';
  }

  // ─────────────────────────────────────────────
  // Convenience checks
  // ─────────────────────────────────────────────

  static bool isRestaurant(
    String? primaryType,
    List<String> allTypes,
  ) {
    return resolvePrimaryType(
          primaryType,
          allTypes,
        ) ==
        'restaurant';
  }

  static bool isNature(
    String? primaryType,
    List<String> allTypes,
  ) {
    return resolvePrimaryType(
          primaryType,
          allTypes,
        ) ==
        'park';
  }

  static bool isAttraction(
    String? primaryType,
    List<String> allTypes,
  ) {
    return resolvePrimaryType(
          primaryType,
          allTypes,
        ) ==
        'tourist_attraction';
  }

  static bool isShopping(
    String? primaryType,
    List<String> allTypes,
  ) {
    return resolvePrimaryType(
          primaryType,
          allTypes,
        ) ==
        'shopping_mall';
  }

  static bool isEntertainment(
    String? primaryType,
    List<String> allTypes,
  ) {
    return resolvePrimaryType(
          primaryType,
          allTypes,
        ) ==
        'entertainment';
  }

  // ─────────────────────────────────────────────
  // Learnable categories
  // ─────────────────────────────────────────────

  static const learnableCategories = {
    'restaurant',
    'park',
    'tourist_attraction',
    'shopping_mall',
    'entertainment',
  };

  static bool isLearnableCategory(
    String primaryType,
  ) {
    return learnableCategories.contains(
      primaryType,
    );
  }

  // ─────────────────────────────────────────────
  // Display category
  // ─────────────────────────────────────────────

  static String toDisplayCategory(
    String type,
  ) {
    if (type == 'restaurant' ||
        restaurantTypes.contains(type)) {
      return 'Food';
    }

    if (type == 'park' ||
        natureTypes.contains(type)) {
      return 'Nature';
    }

    if (type == 'tourist_attraction' ||
        attractionTypes.contains(type)) {
      return 'Attraction';
    }

    if (type == 'shopping_mall' ||
        shoppingTypes.contains(type)) {
      return 'Shopping';
    }

    if (type == 'transit' ||
        transitTypes.contains(type)) {
      return 'Transport';
    }

    if (type == 'entertainment' ||
        entertainmentTypes.contains(type)) {
      return 'Entertainment';
    }

    if (type == 'service' ||
        serviceTypes.contains(type)) {
      return 'Service';
    }

    return 'Others';
  }

  static String toAchievementCategory(
    String type,
  ) {
    if (type == 'restaurant' ||
        restaurantTypes.contains(type)) {
      return 'Food';
    }

    if (type == 'park' ||
        natureTypes.contains(type)) {
      return 'Nature';
    }

    if (type == 'tourist_attraction' ||
        attractionTypes.contains(type)) {
      return 'Attraction';
    }

    return 'Other';
  }

  // ─────────────────────────────────────────────
  // Outdoor / Indoor
  // ─────────────────────────────────────────────

  static const Set<String> outdoorTypes = {
    ...natureTypes,
    'historical_landmark',
    'monument',
    'amusement_park',
    'stadium',
  };

  static const Set<String> indoorTypes = {
    ...restaurantTypes,
    ...shoppingTypes,
    'museum',
    'art_gallery',
    'movie_theater',
    'bowling_alley',
    'karaoke',
    'video_arcade',
    'night_club',
    'amusement_center',
    'concert_hall',
    'gym',
    'fitness_center',
    'spa',
    'hindu_temple',
    'buddhist_temple',
    'shrine',
    'mosque',
    'surau',
    'church',
  };

  static bool? isOutdoorBySpecificType(
    List<String> allTypes,
  ) {
    for (final type in allTypes) {
      if (outdoorTypes.contains(type)) {
        return true;
      }

      if (indoorTypes.contains(type)) {
        return false;
      }
    }

    return null;
  }

  static const Set<String> outdoorFallbackBuckets = {
    'park',
  };

  // ─────────────────────────────────────────────
  // Time suitability
  // ─────────────────────────────────────────────

  static const Map<
      String,
      Map<String, double>> specificTimeSuitability = {
    'morning': {
      'cafe': 1.0,
      'coffee_shop': 1.0,
      'movie_theater': 0.2,
      'karaoke': 0.2,
    },
    'lunch': {
      'cafe': 0.5,
      'coffee_shop': 0.5,
    },
    'afternoon': {
      'museum': 1.0,
      'art_gallery': 1.0,
      'movie_theater': 0.6,
    },
    'evening': {
      'movie_theater': 0.9,
      'karaoke': 0.8,
    },
    'night': {
      'movie_theater': 1.0,
      'karaoke': 1.0,
      'bowling_alley': 0.9,
      'gym': 0.1,
      'fitness_center': 0.1,
      'spa': 0.2,
    },
  };

  static const Map<
      String,
      Map<String, double>> bucketTimeSuitability = {
    'morning': {
      'restaurant': 0.6,
      'park': 0.8,
      'tourist_attraction': 0.7,
    },
    'lunch': {
      'restaurant': 1.0,
      'shopping_mall': 0.4,
    },
    'afternoon': {
      'tourist_attraction': 1.0,
      'park': 1.0,
      'shopping_mall': 0.9,
      'entertainment': 0.8,
      'restaurant': 0.3,
    },
    'evening': {
      'restaurant': 1.0,
      'shopping_mall': 0.7,
      'entertainment': 0.8,
    },
    'night': {
      'entertainment': 1.0,
      'restaurant': 0.7,
    },
  };
}