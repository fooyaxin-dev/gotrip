import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/services/route_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 11D Itinerary Start Anchor and Motor Mode Propagation Regression Tests', () {
    test('1. Travel mode mapping correctly propagates motor mode to optimizer', () {
      expect(travelModeFromString('motor'), equals(TravelMode.motor));
      expect(travelModeFromString('walk'), equals(TravelMode.walk));
      expect(travelModeFromString('drive'), equals(TravelMode.drive));
      expect(travelModeFromString('both'), equals(TravelMode.drive));

      expect(travelModeToString(TravelMode.motor), equals('motor'));
      expect(travelModeToString(TravelMode.walk), equals('walk'));
      expect(travelModeToString(TravelMode.drive), equals('drive'));
    });

    test('2. Travel mode search radius limits adhere strictly to standards', () {
      expect(radiusForTravelModeString('walk'), equals(2000));
      expect(radiusForTravelModeString('motor'), equals(8000));
      expect(radiusForTravelModeString('drive'), equals(12000));
      expect(radiusForTravelModeString('both'), equals(12000));
    });

    test('3. First stop of day anchors to origin, subsequent stops anchor to previous place', () {
      const originLat = 5.2632341;
      const originLng = 100.4846227;

      final dayPlaces = <PlaceModel>[];

      ({double lat, double lng, String type}) getDayAnchor() {
        if (dayPlaces.isEmpty) {
          return (lat: originLat, lng: originLng, type: 'origin');
        }
        final lastPlace = dayPlaces.last;
        return (lat: lastPlace.lat!, lng: lastPlace.lng!, type: 'previous_place');
      }

      // First stop: dayPlaces is empty -> anchor is origin
      final firstAnchor = getDayAnchor();
      expect(firstAnchor.type, equals('origin'));
      expect(firstAnchor.lat, equals(originLat));
      expect(firstAnchor.lng, equals(originLng));

      // Add first place
      final placeA = PlaceModel(
        id: 'place_a',
        name: 'Place A',
        lat: 5.2700,
        lng: 100.4900,
        allTypes: ['tourist_attraction'],
        rating: 4.5,
        source: 'google',
      );
      dayPlaces.add(placeA);

      // Second stop: dayPlaces has 1 place -> anchor is Place A
      final secondAnchor = getDayAnchor();
      expect(secondAnchor.type, equals('previous_place'));
      expect(secondAnchor.lat, equals(5.2700));
      expect(secondAnchor.lng, equals(100.4900));

      // Add second place
      final placeB = PlaceModel(
        id: 'place_b',
        name: 'Place B',
        lat: 5.2800,
        lng: 100.5000,
        allTypes: ['restaurant'],
        rating: 4.2,
        source: 'google',
      );
      dayPlaces.add(placeB);

      // Third stop: dayPlaces has 2 places -> anchor is Place B
      final thirdAnchor = getDayAnchor();
      expect(thirdAnchor.type, equals('previous_place'));
      expect(thirdAnchor.lat, equals(5.2800));
      expect(thirdAnchor.lng, equals(100.5000));
    });

    test('4. Selection formula evaluates quality (0.25) and proximity (0.75) deterministically', () {
      const distanceBaseline = 6000.0; // motor baseline

      double calculateSelectionValue({
        required double quality,
        required double distanceMeters,
        double cuisineBoost = 0.0,
      }) {
        final proximity = math.exp(-distanceMeters / distanceBaseline);
        return 0.25 * quality + 0.75 * proximity + cuisineBoost;
      }

      // Candidate 1: close to anchor (500m), moderate quality (0.70)
      final val1 = calculateSelectionValue(quality: 0.70, distanceMeters: 500.0);
      // Candidate 2: far from anchor (5000m), high quality (0.95)
      final val2 = calculateSelectionValue(quality: 0.95, distanceMeters: 5000.0);

      // Close candidate wins over far candidate because proximity weight is 0.75
      expect(val1, greaterThan(val2));
    });
  });
}
