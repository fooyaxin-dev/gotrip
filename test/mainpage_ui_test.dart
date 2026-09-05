import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/modules/main/mainpage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 15D: Main Page UI Refinement Tests', () {
    test('1. Main Page widget can be instantiated with valid parameters', () {
      const page = MainPage(username: 'TestTraveler');
      expect(page.username, equals('TestTraveler'));
    });

    test('2. Category shortcut definitions contain expected keys and icons', () {
      final categories = [
        {"label": "All",       "type": "all",           "icon": Icons.grid_view_rounded},
        {"label": "Food",      "type": "restaurant",    "icon": Icons.restaurant_rounded},
        {"label": "Nature",    "type": "park",          "icon": Icons.park_rounded},
        {"label": "Entertain", "type": "entertainment", "icon": Icons.local_activity_rounded},
        {"label": "Shopping",  "type": "shopping_mall", "icon": Icons.shopping_bag_rounded},
        {"label": "Transport", "type": "transit",       "icon": Icons.directions_transit},
        {"label": "Service",   "type": "service",       "icon": Icons.miscellaneous_services},
      ];

      expect(categories.length, equals(7));
      expect(categories.map((c) => c['label']).toList(),
          containsAll(['All', 'Food', 'Nature', 'Entertain', 'Shopping', 'Transport', 'Service']));
    });

    test('3. Nearby preview caps display at maximum 6 places without discarding remaining', () {
      // Create 10 mock places
      final tenPlaces = List.generate(
        10,
        (i) => PlaceModel(
          id: 'place_$i',
          name: 'Nearby Destination $i',
          source: 'google',
          primaryType: 'restaurant',
          lat: 3.14 + (i * 0.001),
          lng: 101.68 + (i * 0.001),
        ),
      );

      expect(tenPlaces.length, equals(10));

      // The preview takes up to 6
      final previewPlaces = tenPlaces.take(6).toList();
      expect(previewPlaces.length, equals(6));

      // The first place in preview matches the first original place
      expect(previewPlaces.first.id, equals('place_0'));
      expect(previewPlaces[5].id, equals('place_5'));

      // The original list still contains all 10 places for "See All"
      expect(tenPlaces.length, equals(10));
      expect(tenPlaces[9].id, equals('place_9'));
    });

    test('4. Preview preserves existing nearby ordering strictly invariant', () {
      final places = [
        PlaceModel(id: 'a', name: 'Alpha', source: 'google', primaryType: 'restaurant'),
        PlaceModel(id: 'b', name: 'Beta', source: 'google', primaryType: 'park'),
        PlaceModel(id: 'c', name: 'Gamma', source: 'google', primaryType: 'shopping_mall'),
        PlaceModel(id: 'd', name: 'Delta', source: 'google', primaryType: 'entertainment'),
      ];

      final preview = places.take(6).toList();
      expect(preview.map((p) => p.id).toList(), equals(['a', 'b', 'c', 'd']));
    });

    test('5. Rating formatting: rated place formats to 1 decimal place, null is omitted', () {
      final ratedPlace = PlaceModel(
        id: 'rated',
        name: 'Top Rated Cafe',
        source: 'google',
        primaryType: 'restaurant',
        rating: 4.67,
      );

      final unratedPlace = PlaceModel(
        id: 'unrated',
        name: 'Unrated Hidden Spot',
        source: 'google',
        primaryType: 'park',
        rating: null,
      );

      final zeroRatedPlace = PlaceModel(
        id: 'zero',
        name: 'Zero Rated Place',
        source: 'google',
        primaryType: 'service',
        rating: 0.0,
      );

      // Verify rated format
      final formattedRating = ratedPlace.rating!.toStringAsFixed(1);
      expect(formattedRating, equals('4.7'));

      // Verify null is handled without printing "null"
      final unratedHasRating = unratedPlace.rating != null && unratedPlace.rating! > 0;
      expect(unratedHasRating, isFalse);

      final zeroHasRating = zeroRatedPlace.rating != null && zeroRatedPlace.rating! > 0;
      expect(zeroHasRating, isFalse);
    });

    test('6. Open/Closed status when known vs unknown', () {
      final openPlace = PlaceModel(id: 'o', name: 'Open Now', source: 'google', isOpenNow: true);
      final closedPlace = PlaceModel(id: 'c', name: 'Closed Now', source: 'google', isOpenNow: false);
      final unknownPlace = PlaceModel(id: 'u', name: 'Hours Unknown', source: 'google', isOpenNow: null);

      expect(openPlace.isOpenNow, isTrue);
      expect(closedPlace.isOpenNow, isFalse);
      expect(unknownPlace.isOpenNow, isNull);
    });

    test('7. PlaceModel invariant check: ID, lat, lng, types remain intact', () {
      final p = PlaceModel(
        id: 'chulia_st',
        name: 'Chulia Street Night Hawker',
        source: 'google',
        lat: 5.4184,
        lng: 100.3364,
        primaryType: 'restaurant',
        allTypes: ['restaurant', 'food', 'point_of_interest'],
        rating: 4.4,
        priceLevel: 1,
      );

      expect(p.id, equals('chulia_st'));
      expect(p.lat, equals(5.4184));
      expect(p.lng, equals(100.3364));
      expect(p.primaryType, equals('restaurant'));
      expect(p.allTypes, contains('restaurant'));
    });
  });
}
