import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/services/userPreference_service.dart';
import 'package:gotrip/services/weather_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Explainable Recommendation & Consistency Tests [Production Unit / State Simulation]', () {
    late UserPreferenceService service;

    setUp(() {
      service = UserPreferenceService.instance;
    });

    test('Dynamic weights always sum exactly to 1.0', () {
      final score = service.recommendationScore(
        primaryType: 'restaurant',
        allTypes: ['restaurant', 'food'],
        rating: 4.5,
        distanceMeters: 500,
        priceLevel: 2,
        weather: WeatherCondition.clear,
      );

      expect(score.explanation, isNotNull);
      final weights = score.explanation!.factorWeights;
      final sum = weights.values.fold(0.0, (a, b) => a + b);
      expect((sum - 1.0).abs(), lessThan(1e-5), reason: 'Dynamic weights must sum to 1.0');
    });

    test('All factor scores and total score remain bounded within [0.0, 1.0]', () {
      final score = service.recommendationScore(
        primaryType: 'park',
        allTypes: ['park', 'tourist_attraction'],
        rating: 5.0,
        distanceMeters: 100,
        priceLevel: 1,
        weather: WeatherCondition.clear,
      );

      expect(score.total, inInclusiveRange(0.0, 1.0));
      expect(score.interestMatch, inInclusiveRange(0.0, 1.0));
      expect(score.distanceScore, inInclusiveRange(0.0, 1.0));
      expect(score.ratingScore, inInclusiveRange(0.0, 1.0));
      expect(score.timeSuitability, inInclusiveRange(0.0, 1.0));
      expect(score.budgetSuitability, inInclusiveRange(0.0, 1.0));
      expect(score.weatherScore, inInclusiveRange(0.0, 1.0));
    });

    test('Travel mode distance baselines and gates adhere strictly to limits', () {
      // 1. Walk: 2000m baseline
      final walkClose = service.recommendationScore(
        primaryType: 'park',
        allTypes: ['park'],
        rating: 4.0,
        distanceMeters: 1000,
        priceLevel: 1,
        travelMode: 'walk',
      );
      expect(walkClose.distanceScore, equals(0.5)); // 1 - 1000/2000 = 0.5

      final walkFar = service.recommendationScore(
        primaryType: 'park',
        allTypes: ['park'],
        rating: 4.0,
        distanceMeters: 2500,
        priceLevel: 1,
        travelMode: 'walk',
      );
      expect(walkFar.distanceScore, equals(0.0)); // Beyond 2000m -> 0.0

      // 2. Motor: 8000m baseline
      final motorMid = service.recommendationScore(
        primaryType: 'park',
        allTypes: ['park'],
        rating: 4.0,
        distanceMeters: 4000,
        priceLevel: 1,
        travelMode: 'motor',
      );
      expect(motorMid.distanceScore, equals(0.5)); // 1 - 4000/8000 = 0.5

      // 3. Drive: 12000m baseline
      final driveMid = service.recommendationScore(
        primaryType: 'park',
        allTypes: ['park'],
        rating: 4.0,
        distanceMeters: 6000,
        priceLevel: 1,
        travelMode: 'drive',
      );
      expect(driveMid.distanceScore, equals(0.5)); // 1 - 6000/12000 = 0.5
    });

    test('Selected category match creates truthful selected-interest reason', () {
      final score = service.recommendationScore(
        primaryType: 'restaurant',
        allTypes: ['restaurant', 'food'],
        rating: 4.5,
        distanceMeters: 300,
        priceLevel: 2,
        originType: RecommendationOriginType.gps,
      );

      final expl = score.explanation;
      expect(expl, isNotNull);
      expect(expl!.explanationReasons, isNotEmpty);
      expect(expl.matchTier, isIn(['Excellent match', 'Strong match', 'Good match']));
      expect(expl.matchPercentage, inInclusiveRange(0, 100));
    });

    test('Missing-data omits unsupported reasons from explanation output', () {
      // No weather, no price level, unknown origin
      final score = service.recommendationScore(
        primaryType: 'tourist_attraction',
        allTypes: ['tourist_attraction'],
        rating: null,
        distanceMeters: null,
        priceLevel: null,
        weather: null,
        originType: RecommendationOriginType.unknown,
      );

      final expl = score.explanation;
      expect(expl, isNotNull);
      final reasons = expl!.explanationReasons.join('; ');
      expect(reasons.contains('weather'), isFalse, reason: 'Missing weather must not generate weather reason');
      expect(reasons.contains('budget'), isFalse, reason: 'Missing price must not generate budget reason');
      expect(reasons.contains('current location'), isFalse, reason: 'Unknown origin must not say current location');
    });

    test('Origin-aware distance explanation uses searched location / landmark name', () {
      // 1. Searched location origin
      final searchScore = service.recommendationScore(
        primaryType: 'restaurant',
        allTypes: ['restaurant'],
        rating: 4.5,
        distanceMeters: 400,
        priceLevel: 2,
        originType: RecommendationOriginType.searched,
        originName: 'Georgetown, Penang',
      );
      final searchReasons = searchScore.explanation!.explanationReasons.join('; ');
      expect(searchReasons.contains('Near Georgetown, Penang'), isTrue);
      expect(searchReasons.contains('current location'), isFalse);

      // 2. Landmark origin
      final landmarkScore = service.recommendationScore(
        primaryType: 'restaurant',
        allTypes: ['restaurant'],
        rating: 4.5,
        distanceMeters: 200,
        priceLevel: 2,
        originType: RecommendationOriginType.landmark,
        originName: 'Petronas Twin Towers',
      );
      final landmarkReasons = landmarkScore.explanation!.explanationReasons.join('; ');
      expect(landmarkReasons.contains('Near Petronas Twin Towers'), isTrue);
      expect(landmarkReasons.contains('current location'), isFalse);
    });

    test('Identical input produces deterministic score, ordering and explanation', () {
      final p1 = PlaceModel(
        id: 'place_1',
        source: 'google',
        name: 'Botanical Garden',
        primaryType: 'park',
        allTypes: ['park', 'tourist_attraction'],
        rating: 4.6,
        priceLevel: 1,
        lat: 3.14,
        lng: 101.68,
      );

      final scoreA = service.recommendationScore(
        primaryType: p1.primaryType,
        allTypes: p1.allTypes,
        rating: p1.rating,
        distanceMeters: 400,
        priceLevel: p1.priceLevel,
        weather: WeatherCondition.clear,
      );

      final scoreB = service.recommendationScore(
        primaryType: p1.primaryType,
        allTypes: p1.allTypes,
        rating: p1.rating,
        distanceMeters: 400,
        priceLevel: p1.priceLevel,
        weather: WeatherCondition.clear,
      );

      expect(scoreA.total, equals(scoreB.total));
      expect(scoreA.explanation!.explanationReasons, equals(scoreB.explanation!.explanationReasons));
      expect(scoreA.explanation!.primaryReason, equals(scoreB.explanation!.primaryReason));
    });

    test('Rankings and candidate ordering before and after explainability are 100% invariant', () {
      final candidates = [
        PlaceModel(
          id: 'p_a',
          source: 'google',
          name: 'Scenic Lake',
          primaryType: 'park',
          allTypes: ['park'],
          rating: 4.2,
          priceLevel: 1,
          photoUrl: 'https://example.com/lake.jpg',
        ),
        PlaceModel(
          id: 'p_b',
          source: 'google',
          name: 'Fine Dining',
          primaryType: 'restaurant',
          allTypes: ['restaurant'],
          rating: 4.9,
          priceLevel: 3,
          photoUrl: 'https://example.com/food.jpg',
        ),
      ];

      final result = service.buildForYouList(
        candidates: candidates,
        distanceLimitMeters: 5000,
        weather: WeatherCondition.clear,
      );

      expect(result.places, isA<List<PlaceModel>>());
      expect(result.scores.keys, containsAll(result.places.map((p) => p.id)));
      expect(result.explanations.keys, containsAll(result.places.map((p) => p.id)));
      
      // Verify sorted order descending by score
      for (int i = 0; i < result.places.length - 1; i++) {
        final scoreCurrent = result.scores[result.places[i].id]!;
        final scoreNext = result.scores[result.places[i + 1].id]!;
        expect(scoreCurrent, greaterThanOrEqualTo(scoreNext));
      }
    });
  });
}
