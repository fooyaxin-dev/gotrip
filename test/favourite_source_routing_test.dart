import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/modules/main/favourite.dart';
import 'package:gotrip/modules/place/favouriteButton.dart';

void main() {
  group('Favourite Source-Aware Routing and Classifier Production Tests', () {
    test('1. Explicit source: landmark routes to Landmark Result', () {
      final doc = {
        'placeId': 'landmark_wat_arun',
        'source': 'landmark',
        'name': 'Wat Arun',
        'lat': 13.7437,
        'lng': 100.4889,
      };

      final dest = FavouriteRouter.classifyDestination(doc);
      expect(dest, equals(FavouriteDestination.landmarkResult));
    });

    test('2. Explicit source: place routes to Place Detail', () {
      final doc = {
        'placeId': 'ChIJ2V-iqT72zTERqZ475Vv1wR4',
        'source': 'place',
        'name': 'Petronas Twin Towers',
        'lat': 3.1579,
        'lng': 101.7116,
      };

      final dest = FavouriteRouter.classifyDestination(doc);
      expect(dest, equals(FavouriteDestination.placeDetail));
    });

    test('3. Explicit source: geoapify routes to Place Detail', () {
      final doc = {
        'placeId': 'geo_5103a89e924a',
        'source': 'geoapify',
        'name': 'Merdeka Square',
        'lat': 3.149,
        'lng': 101.693,
      };

      final dest = FavouriteRouter.classifyDestination(doc);
      expect(dest, equals(FavouriteDestination.placeDetail));
    });

    test(
        '4. Missing source + exact name slug routes as legacy Landmark (e.g. Wat Arun)',
        () {
      final doc = {
        'placeId': 'wat_arun_ratchawararam_ratchawaramahawihan',
        // source is missing
        'name': 'Wat Arun Ratchawararam Ratchawaramahawihan',
        'lat': 13.7437,
        'lng': 100.4889,
      };

      final dest = FavouriteRouter.classifyDestination(doc);
      expect(dest, equals(FavouriteDestination.landmarkResult));
    });

    test('5. Missing source + Google Place ID routes as normal Place Detail',
        () {
      final doc = {
        'placeId': 'ChIJ2V-iqT72zTERqZ475Vv1wR4',
        // source is missing
        'name': 'Petronas Twin Towers',
        'lat': 3.1579,
        'lng': 101.7116,
      };

      final dest = FavouriteRouter.classifyDestination(doc);
      expect(dest, equals(FavouriteDestination.placeDetail));
    });

    test('6. Google Place ID containing underscore is not misclassified', () {
      final doc = {
        'placeId': 'ChIJ_abc_123_xyz',
        // source is missing, name does not match slug
        'name': 'Some Special Cafe',
      };

      final dest = FavouriteRouter.classifyDestination(doc);
      expect(dest, equals(FavouriteDestination.placeDetail));
    });

    test(
        '7. Empty or malformed landmark name is handled safely without throwing',
        () {
      final doc1 = {'placeId': '', 'name': ''};
      expect(FavouriteRouter.classifyDestination(doc1),
          equals(FavouriteDestination.placeDetail));

      final doc2 = {'placeId': 'landmark_unknown', 'name': 'Unknown'};
      expect(FavouriteRouter.classifyDestination(doc2),
          equals(FavouriteDestination.landmarkResult));
    });

    test('8. Canonical landmark slug generator matches Task 10B3 specification',
        () {
      expect(
        FavouriteRouter.canonicalLandmarkSlug('Wat Arun (Temple of Dawn)!'),
        equals('wat_arun_temple_of_dawn'),
      );
      expect(
        FavouriteRouter.canonicalLandmarkSlug(
            '  Sultan Abdul Samad Building  '),
        equals('sultan_abdul_samad_building'),
      );
      expect(
        FavouriteRouter.canonicalLandmarkSlug('---___KLCC Park___---'),
        equals('klcc_park'),
      );
    });

    test(
        '9. FavouriteButton defaults to source: place with optional googlePlaceId: null',
        () {
      const button = FavouriteButton(
        placeId: 'ChIJ123',
        name: 'Test Place',
        address: 'Test Address',
      );

      expect(button.source, equals('place'));
      expect(button.googlePlaceId, isNull);
    });

    test(
        '10. FavouriteButton accepts source: landmark and explicit googlePlaceId',
        () {
      const button = FavouriteButton(
        placeId: 'wat_arun',
        source: 'landmark',
        googlePlaceId: 'ChIJ_wat_arun_real_id',
        name: 'Wat Arun',
        address: 'Bangkok',
      );

      expect(button.source, equals('landmark'));
      expect(button.googlePlaceId, equals('ChIJ_wat_arun_real_id'));
    });
  });
}
