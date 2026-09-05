/// Shared single source of truth for place and destination arrival detection.
///
/// Unifies arrival policy across Itinerary Detail proximity tracking
/// and GPS Navigation turn-by-turn guidance.
class ArrivalPolicy {
  /// Straight-line distance threshold for confirming arrival at a place or destination.
  static const double arrivalRadiusMetres = 15.0;

  /// Maximum allowable reported GPS accuracy (horizontal error) for a qualifying arrival fix.
  static const double maximumArrivalAccuracyMetres = 20.0;

  /// Number of consecutive qualifying location fixes required to confirm arrival.
  static const int requiredConsecutiveFixes = 2;

  /// Determines whether a location fix qualifies toward arrival confirmation.
  ///
  /// A qualifying fix must:
  /// 1. Have straight-line distance to destination <= [arrivalRadiusMetres] (15m).
  /// 2. Have finite reported GPS accuracy.
  /// 3. Have non-negative reported GPS accuracy.
  /// 4. Have reported GPS accuracy <= [maximumArrivalAccuracyMetres] (20m).
  static bool isQualifyingFix({
    required double distanceMetres,
    required double accuracyMetres,
  }) {
    return distanceMetres <= arrivalRadiusMetres &&
        accuracyMetres.isFinite &&
        accuracyMetres >= 0.0 &&
        accuracyMetres <= maximumArrivalAccuracyMetres;
  }
}
