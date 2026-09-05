import '../models/placeModel.dart';
import 'category_mapper.dart';

/// Single source of truth for deciding whether a place is eligible for
/// AUTOMATIC travel recommendation.
///
/// Policy rule:
///   suspicious business/corporate name
///   AND no authoritative visitor-relevant Google type
///   => exclude from automatic recommendations
///
/// A place with a suspicious corporate name but a clear visitor-relevant type
/// (e.g. `ABC Restaurant Sdn. Bhd.`) must remain eligible.
///
/// A normal place without corporate keywords (e.g. `Uncle Bob's Corner`)
/// is never excluded merely because it has generic types like `store`.
class RecommendationEligibilityPolicy {
  RecommendationEligibilityPolicy._();

  static final RegExp _punctuationRegex = RegExp(r'[^\w\s]');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');
  static final RegExp _compressedStripRegex = RegExp(r'[\W_]');

  /// Normalizes a place name for corporate keyword matching:
  /// - converts to lowercase
  /// - replaces punctuation with whitespace
  /// - collapses repeated whitespace
  static String normalizeName(String name) {
    return name
        .toLowerCase()
        .replaceAll(_punctuationRegex, ' ')
        .replaceAll(_whitespaceRegex, ' ')
        .trim();
  }

  /// Recognizes the intended corporate/business keywords with word boundaries:
  /// - sdn bhd / sdn. bhd. / sdnbhd
  /// - berhad / group berhad
  /// - enterprise / enterprises
  /// - trading
  /// - holdings
  /// - management
  /// - solution / solutions
  /// - consultant / consultancy
  /// - agency / agencies
  /// - services
  /// - network
  static final List<RegExp> _corporatePatterns = [
    RegExp(r'\bsdn\s*bhd\b', caseSensitive: false),
    RegExp(r'\bsdnbhd\b', caseSensitive: false),
    RegExp(r'\b(group\s+)?berhad\b', caseSensitive: false),
    RegExp(r'\benterprises?\b', caseSensitive: false),
    RegExp(r'\btrading\b', caseSensitive: false),
    RegExp(r'\bholdings\b', caseSensitive: false),
    RegExp(r'\bmanagement\b', caseSensitive: false),
    RegExp(r'\bsolutions?\b', caseSensitive: false),
    RegExp(r'\bconsultan(t|cy)\b', caseSensitive: false),
    RegExp(r'\bagenc(y|ies)\b', caseSensitive: false),
    RegExp(r'\bservices\b', caseSensitive: false),
    RegExp(r'\bnetworks?\b', caseSensitive: false),
  ];

  /// Checks whether [name] contains suspicious corporate or business keywords.
  static bool hasSuspiciousCorporateName(String name) {
    if (name.trim().isEmpty) return false;

    final normalized = normalizeName(name);
    for (final pattern in _corporatePatterns) {
      if (pattern.hasMatch(normalized)) return true;
    }

    // Also check punctuation/space-stripped string for merged compounds (e.g. "sdnbhd")
    final compressed = name.toLowerCase().replaceAll(_compressedStripRegex, '');
    if (compressed.contains('sdnbhd')) {
      return true;
    }

    return false;
  }

  /// Authoritative visitor-relevant Google types that rescue a place with
  /// a corporate name suffix.
  ///
  /// Generic types like `store`, `establishment`, `point_of_interest`,
  /// `corporate_office`, `wholesaler` alone are intentionally NOT in this set.
  static final Set<String> authoritativeVisitorTypes = {
    // Food and drink
    ...CategoryMapper.restaurantTypes,

    // Attractions and culture
    'tourist_attraction',
    'museum',
    'art_gallery',
    'cultural_landmark',
    'historical_landmark',
    'monument',
    'performing_arts_theater',
    'event_venue',
    'visitor_center',

    // Nature and recreation
    'park',
    'national_park',
    'zoo',
    'aquarium',
    'amusement_park',
    'water_park',
    'botanical_garden',
    'garden',
    'hiking_area',
    'beach',

    // Shopping and entertainment destinations
    'shopping_mall',
    'market',
    'movie_theater',
    'bowling_alley',
    'night_club',
    'amusement_center',
    'karaoke',
    'video_arcade',
    'concert_hall',
  };

  /// Evaluates whether [place] has at least one authoritative visitor-relevant
  /// Google type in `place.allTypes`.
  ///
  /// Uses canonical types directly rather than display category mappings.
  static bool hasAuthoritativeVisitorType(PlaceModel place) {
    return place.allTypes.any(authoritativeVisitorTypes.contains);
  }

  /// Main entrypoint: evaluates whether [place] is eligible for automatic
  /// recommendation.
  ///
  /// Excludes places that have a suspicious corporate/business name AND lack
  /// an authoritative visitor-relevant type.
  static bool isEligibleForAutomaticRecommendation(PlaceModel place) {
    if (hasSuspiciousCorporateName(place.name)) {
      if (!hasAuthoritativeVisitorType(place)) {
        return false;
      }
    }
    return true;
  }
}
