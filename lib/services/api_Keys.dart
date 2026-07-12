class ApiKeys {
  static const String googleMaps = String.fromEnvironment('GOOGLE_MAPS_KEY');
  static const String googlePlacesNew = String.fromEnvironment('GOOGLE_PLACES_NEW_KEY');
  static const String googleVision = String.fromEnvironment('GOOGLE_VISION_KEY');
  static const String gemini = String.fromEnvironment('GEMINI_API_KEY');
  static const String geoapify = String.fromEnvironment('GEOAPIFY_KEY');
  static const String algoliaAppId = String.fromEnvironment('ALGOLIA_APP_ID');
  static const String algoliaSearchKey = String.fromEnvironment('ALGOLIA_SEARCH_KEY');
  // Admin key暂时还留这里，等你决定要不要搬到后端
  static const String algoliaAdminKey = String.fromEnvironment('ALGOLIA_ADMIN_KEY');
}
