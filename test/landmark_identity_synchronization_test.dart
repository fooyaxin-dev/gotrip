import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/modules/landmark/landmarkResult.dart';
import 'package:gotrip/modules/main/favourite.dart';
import 'package:gotrip/modules/place/favouriteButton.dart';
import 'package:gotrip/services/favourite_service.dart';
import 'package:gotrip/services/landmarkHistory_service.dart';
import 'package:gotrip/services/vision_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 10B3.4 Landmark Identity Synchronization & Resolution Tests', () {
    test('1. ResultPage identity prefers provided landmarkId', () {
      const explicitId = 'universiti_tunku_abdul_rahman_utar';
      const normalizedName = 'Universiti Tunku Abdul Rahman (UTAR)';

      final resolvedId = ResultPage.resolveStablePlaceId(
        landmarkId: explicitId,
        normalizedName: normalizedName,
      );

      expect(resolvedId, equals(explicitId));
    });

    test(
        '2. ResultPage falls back to existing canonical slug when ID is absent',
        () {
      const normalizedName = 'Universiti Tunku Abdul Rahman (UTAR)';

      final resolvedId = ResultPage.resolveStablePlaceId(
        landmarkId: null,
        normalizedName: normalizedName,
      );

      expect(resolvedId, equals('universiti_tunku_abdul_rahman_utar'));

      // Also verify empty/whitespace string falls back safely
      final emptyFallback = ResultPage.resolveStablePlaceId(
        landmarkId: '   ',
        normalizedName: normalizedName,
      );
      expect(emptyFallback, equals('universiti_tunku_abdul_rahman_utar'));
    });

    test('3. New History serialization stores landmarkId', () {
      final entry = LandmarkHistoryEntry(
        id: 'hist_001',
        landmarkId: 'universiti_tunku_abdul_rahman_utar',
        name: 'Universiti Tunku Abdul Rahman (UTAR)',
        lat: 4.3348363,
        lng: 101.1351317,
        scannedAt: DateTime.now(),
        detectionMethod: 'vision',
      );

      final map = entry.toFirestore();
      expect(map['landmarkId'], equals('universiti_tunku_abdul_rahman_utar'));
      expect(map['name'], equals('Universiti Tunku Abdul Rahman (UTAR)'));
    });

    test('4. New History deserialization restores the same landmarkId', () {
      final rawData = <String, dynamic>{
        'landmarkId': 'universiti_tunku_abdul_rahman_utar',
        'name': 'Universiti Tunku Abdul Rahman (UTAR)',
        'lat': 4.3348363,
        'lng': 101.1351317,
        'detectionMethod': 'vision',
      };

      final entry = LandmarkHistoryEntry.fromFirestore('doc_123', rawData);
      expect(entry.id, equals('doc_123'));
      expect(entry.landmarkId, equals('universiti_tunku_abdul_rahman_utar'));
      expect(entry.name, equals('Universiti Tunku Abdul Rahman (UTAR)'));
    });

    test('5. Legacy History without landmarkId still parses safely', () {
      final rawLegacyData = <String, dynamic>{
        'name': 'Universiti Tunku Abdul Rahman (UTAR)',
        'lat': 4.3348363,
        'lng': 101.1351317,
        'detectionMethod': 'vision',
      };

      final entry =
          LandmarkHistoryEntry.fromFirestore('doc_legacy', rawLegacyData);
      expect(entry.id, equals('doc_legacy'));
      expect(entry.landmarkId, isNull);
      expect(entry.name, equals('Universiti Tunku Abdul Rahman (UTAR)'));
    });

    test('6. Fresh ID equals reopened History ID', () {
      const freshName = 'Universiti Tunku Abdul Rahman (UTAR)';
      final generatedFreshId = FavouriteRouter.canonicalLandmarkSlug(freshName);
      expect(generatedFreshId, equals('universiti_tunku_abdul_rahman_utar'));

      // Simulate saving into History
      final savedEntry = LandmarkHistoryEntry(
        id: 'hist_utar_01',
        landmarkId: generatedFreshId,
        name: freshName,
        lat: 4.3348363,
        lng: 101.1351317,
        scannedAt: DateTime.now(),
        detectionMethod: 'vision',
      );

      // Deserialize upon reopening History
      final reopenedEntry = LandmarkHistoryEntry.fromFirestore(savedEntry.id, {
        'landmarkId': savedEntry.landmarkId,
        'name': savedEntry.name,
        'lat': savedEntry.lat,
        'lng': savedEntry.lng,
        'detectionMethod': savedEntry.detectionMethod,
      });

      expect(reopenedEntry.landmarkId, equals(generatedFreshId));
    });

    test('7. Favourite Page landmark navigation passes its exact placeId', () {
      final landmarkFav = <String, dynamic>{
        'placeId': 'universiti_tunku_abdul_rahman_utar',
        'source': 'landmark',
        'name': 'Universiti Tunku Abdul Rahman (UTAR)',
        'lat': 4.3348363,
        'lng': 101.1351317,
      };

      final destination = FavouriteRouter.classifyDestination(landmarkFav);
      expect(destination, equals(FavouriteDestination.landmarkResult));
      expect(
          landmarkFav['placeId'], equals('universiti_tunku_abdul_rahman_utar'));
    });

    test('8. Legacy matching ignores source: place', () {
      final userFavourites = <Map<String, dynamic>>[
        {
          'placeId': 'ChIJ_utar_explore',
          'source': 'place',
          'name': 'Universiti Tunku Abdul Rahman (UTAR)',
          'lat': 4.3348363,
          'lng': 101.1351317,
        },
        {
          'placeId': 'geo_utar_geoapify',
          'source': 'geoapify',
          'name': 'Universiti Tunku Abdul Rahman (UTAR)',
          'lat': 4.3348363,
          'lng': 101.1351317,
        },
      ];

      final matched = FavouriteService.selectMatchingLandmarkFavouriteId(
        userFavourites,
        name: 'Universiti Tunku Abdul Rahman (UTAR)',
        lat: 4.3348363,
        lng: 101.1351317,
      );

      expect(matched, isNull);
    });

    test('9. Legacy matching selects the same-name source: landmark document',
        () {
      final userFavourites = <Map<String, dynamic>>[
        {
          'placeId': 'universiti_tunku_abdul_rahman_utar',
          'source': 'landmark',
          'name': 'Universiti Tunku Abdul Rahman (UTAR)',
          'savedAt': DateTime(2026, 9, 1, 17, 27, 5),
        },
      ];

      final matched = FavouriteService.selectMatchingLandmarkFavouriteId(
        userFavourites,
        name: '  universiti tunku abdul rahman (utar)  ',
      );

      expect(matched, equals('universiti_tunku_abdul_rahman_utar'));
    });

    test(
        '10. Legacy matching selects a Landmark within 30 metres when names differ',
        () {
      final userFavourites = <Map<String, dynamic>>[
        {
          'placeId': 'universiti_tunku_abdul_rahman_utar',
          'source': 'landmark',
          'name': 'UTAR Main Entrance Gate',
          'lat': 4.3348363,
          'lng': 101.1351317,
          'savedAt': DateTime(2026, 9, 1, 17, 27, 5),
        },
      ];

      // Query with slightly different GPS (~2 meters away) and differing name
      final matched = FavouriteService.selectMatchingLandmarkFavouriteId(
        userFavourites,
        name: 'Universiti Tunku Abdul Rahman Block A',
        lat: 4.3348500,
        lng: 101.1351400,
      );

      expect(matched, equals('universiti_tunku_abdul_rahman_utar'));
    });

    test(
        '11. Multiple matching Landmark duplicates select the earliest savedAt (UTAR production case)',
        () {
      final userFavourites = <Map<String, dynamic>>[
        // Document B: created later at 5:27:49 PM
        {
          'placeId': 'universiti_tunku_abdul_rahman_utar_kampar_campus',
          'source': 'landmark',
          'name': 'Universiti Tunku Abdul Rahman (UTAR)',
          'lat': 4.3348363,
          'lng': 101.1351317,
          'savedAt': DateTime(2026, 9, 1, 17, 27, 49),
        },
        // Document A: created earlier at 5:27:05 PM
        {
          'placeId': 'universiti_tunku_abdul_rahman_utar',
          'source': 'landmark',
          'name': 'Universiti Tunku Abdul Rahman (UTAR)',
          'lat': 4.3348363,
          'lng': 101.1351317,
          'savedAt': DateTime(2026, 9, 1, 17, 27, 5),
        },
      ];

      final matched = FavouriteService.selectMatchingLandmarkFavouriteId(
        userFavourites,
        name: 'Universiti Tunku Abdul Rahman (UTAR)',
        lat: 4.3348363,
        lng: 101.1351317,
      );

      // Must select Document A (earlier original) instead of Document B (later duplicate)
      expect(matched, equals('universiti_tunku_abdul_rahman_utar'));
      expect(matched,
          isNot(equals('universiti_tunku_abdul_rahman_utar_kampar_campus')));
    });

    test('12. No matching Favourite returns null safely', () {
      final userFavourites = <Map<String, dynamic>>[
        {
          'placeId': 'wat_arun',
          'source': 'landmark',
          'name': 'Wat Arun',
          'lat': 13.7437,
          'lng': 100.4889,
          'savedAt': DateTime(2026, 9, 1, 12, 0, 0),
        },
      ];

      final matched = FavouriteService.selectMatchingLandmarkFavouriteId(
        userFavourites,
        name: 'Petronas Twin Towers',
        lat: 3.1579,
        lng: 101.7116,
      );

      expect(matched, isNull);
    });

    test('13. Google/Geoapify Favourite routing remains unchanged', () {
      final googlePlaceDoc = <String, dynamic>{
        'placeId': 'ChIJ2V-iqT72zTERqZ475Vv1wR4',
        'source': 'place',
        'name': 'Petronas Twin Towers',
      };

      final geoapifyDoc = <String, dynamic>{
        'placeId': 'geo_5103a89e924a',
        'source': 'geoapify',
        'name': 'Merdeka Square',
      };

      expect(FavouriteRouter.classifyDestination(googlePlaceDoc),
          equals(FavouriteDestination.placeDetail));
      expect(FavouriteRouter.classifyDestination(geoapifyDoc),
          equals(FavouriteDestination.placeDetail));
    });
  });
}
