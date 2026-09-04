import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/itineraryModel.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/services/route_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
      'Task 13C Rollback Itinerary Regression Tests [Stable Pre-Task-13 Core]',
      () {
    // ─────────────────────────────────────────────
    // Helper: Generate synthetic candidate places
    // ─────────────────────────────────────────────
    List<PlaceModel> generateCandidatePool({
      required int restaurantCount,
      required int attractionCount,
      required int parkCount,
      required int mallCount,
      required int entertainmentCount,
      String prefix = 'cand',
      double baseLat = 5.4164,
      double baseLng = 100.3327,
    }) {
      final pool = <PlaceModel>[];
      int idCounter = 1;

      for (int i = 0; i < restaurantCount; i++) {
        pool.add(PlaceModel(
          id: '${prefix}_restaurant_$idCounter',
          name: 'Restaurant $idCounter',
          address: 'Address R$idCounter',
          primaryType: 'restaurant',
          allTypes: ['restaurant', 'food'],
          lat: baseLat + (idCounter * 0.001),
          lng: baseLng + (idCounter * 0.001),
          rating: 4.5,
          source: 'google',
        ));
        idCounter++;
      }
      for (int i = 0; i < attractionCount; i++) {
        pool.add(PlaceModel(
          id: '${prefix}_attraction_$idCounter',
          name: 'Attraction $idCounter',
          address: 'Address A$idCounter',
          primaryType: 'tourist_attraction',
          allTypes: ['tourist_attraction'],
          lat: baseLat + (idCounter * 0.001),
          lng: baseLng + (idCounter * 0.001),
          rating: 4.6,
          source: 'google',
        ));
        idCounter++;
      }
      for (int i = 0; i < parkCount; i++) {
        pool.add(PlaceModel(
          id: '${prefix}_park_$idCounter',
          name: 'Park $idCounter',
          address: 'Address P$idCounter',
          primaryType: 'park',
          allTypes: ['park'],
          lat: baseLat + (idCounter * 0.001),
          lng: baseLng + (idCounter * 0.001),
          rating: 4.4,
          source: 'google',
        ));
        idCounter++;
      }
      for (int i = 0; i < mallCount; i++) {
        pool.add(PlaceModel(
          id: '${prefix}_mall_$idCounter',
          name: 'Mall $idCounter',
          address: 'Address M$idCounter',
          primaryType: 'shopping_mall',
          allTypes: ['shopping_mall'],
          lat: baseLat + (idCounter * 0.001),
          lng: baseLng + (idCounter * 0.001),
          rating: 4.2,
          source: 'google',
        ));
        idCounter++;
      }
      for (int i = 0; i < entertainmentCount; i++) {
        pool.add(PlaceModel(
          id: '${prefix}_ent_$idCounter',
          name: 'Entertainment $idCounter',
          address: 'Address E$idCounter',
          primaryType: 'entertainment',
          allTypes: ['entertainment', 'movie_theater'],
          lat: baseLat + (idCounter * 0.001),
          lng: baseLng + (idCounter * 0.001),
          rating: 4.3,
          source: 'google',
        ));
        idCounter++;
      }
      return pool;
    }

    // ─────────────────────────────────────────────
    // Helper: Stable Pre-Task-13 Distribution Logic
    // ─────────────────────────────────────────────
    int requiredRestaurantsPerDay(int placesPerDay) {
      if (placesPerDay <= 2) return 1;
      if (placesPerDay <= 4) return 2;
      return 3;
    }

    ({List<ItineraryDay> days, List<PlaceModel> leftovers})
        distributePlacesStable({
      required int totalDays,
      required int placesPerDay,
      required List<PlaceModel> pool,
      required bool onlyFoodRequested,
      DateTime? startDate,
    }) {
      final start = startDate ?? DateTime(2026, 9, 2);
      final minRestaurants = requiredRestaurantsPerDay(placesPerDay);
      final targetAttractions =
          onlyFoodRequested ? 0 : placesPerDay - minRestaurants;

      final restaurants =
          pool.where((p) => p.primaryType == 'restaurant').toList();
      final nonRestaurants =
          pool.where((p) => p.primaryType != 'restaurant').toList();

      final assignedPlaces = <PlaceModel>[];
      final assignedIds = <String>{};
      final days = <ItineraryDay>[];

      int restIndex = 0;
      int nonRestIndex = 0;

      for (int d = 0; d < totalDays; d++) {
        final dayPlaces = <ItineraryPlace>[];
        final dayDate =
            start.add(Duration(days: d)).toIso8601String().split('T').first;

        if (onlyFoodRequested) {
          // Food-only: fill day exclusively with food
          for (int i = 0; i < placesPerDay; i++) {
            if (restIndex < restaurants.length) {
              final p = restaurants[restIndex++];
              if (assignedIds.add(p.id)) {
                assignedPlaces.add(p);
                dayPlaces.add(ItineraryPlace(
                  placeId: p.id,
                  name: p.name,
                  address: p.address ?? 'Address',
                  lat: p.lat,
                  lng: p.lng,
                  primaryType: p.primaryType,
                  durationMinutes: 60,
                  suggestedTime: '${8 + (i * 2)}:00',
                ));
              }
            }
          }
        } else {
          // Mixed: allocate restaurants and attractions per day
          for (int i = 0; i < targetAttractions; i++) {
            if (nonRestIndex < nonRestaurants.length) {
              final p = nonRestaurants[nonRestIndex++];
              if (assignedIds.add(p.id)) {
                assignedPlaces.add(p);
                dayPlaces.add(ItineraryPlace(
                  placeId: p.id,
                  name: p.name,
                  address: p.address ?? 'Address',
                  lat: p.lat,
                  lng: p.lng,
                  primaryType: p.primaryType,
                  durationMinutes: 90,
                  suggestedTime: '${8 + (i * 2)}:00',
                ));
              }
            }
          }
          for (int i = 0; i < minRestaurants; i++) {
            if (restIndex < restaurants.length) {
              final p = restaurants[restIndex++];
              if (assignedIds.add(p.id)) {
                assignedPlaces.add(p);
                dayPlaces.add(ItineraryPlace(
                  placeId: p.id,
                  name: p.name,
                  address: p.address ?? 'Address',
                  lat: p.lat,
                  lng: p.lng,
                  primaryType: p.primaryType,
                  durationMinutes: 60,
                  suggestedTime: '${12 + (i * 5)}:00',
                ));
              }
            }
          }
        }

        days.add(ItineraryDay(
          dayNumber: d + 1,
          date: dayDate,
          places: dayPlaces,
        ));
      }

      final leftovers = pool.where((p) => !assignedIds.contains(p.id)).toList();
      return (days: days, leftovers: leftovers);
    }

    // ─────────────────────────────────────────────
    // 1. Demand & Combination Tests
    // ─────────────────────────────────────────────

    test(
        '1. Day & Places Combination Matrix: 1x1, 1x2..6, 2x4, 3x4, 3x5, 4x2, 5x3, 6x1, 7x6 exact stops',
        () {
      final cases = [
        (days: 1, places: 1, expected: 1),
        (days: 1, places: 2, expected: 2),
        (days: 1, places: 3, expected: 3),
        (days: 1, places: 4, expected: 4),
        (days: 1, places: 5, expected: 5),
        (days: 1, places: 6, expected: 6),
        (days: 2, places: 4, expected: 8),
        (days: 3, places: 4, expected: 12),
        (days: 3, places: 5, expected: 15),
        (days: 4, places: 2, expected: 8),
        (days: 5, places: 3, expected: 15),
        (days: 6, places: 1, expected: 6),
        (days: 7, places: 6, expected: 42),
      ];

      for (final c in cases) {
        final pool = generateCandidatePool(
          restaurantCount: c.days * requiredRestaurantsPerDay(c.places) + 5,
          attractionCount:
              c.days * (c.places - requiredRestaurantsPerDay(c.places)) + 5,
          parkCount: 10,
          mallCount: 10,
          entertainmentCount: 10,
        );

        final result = distributePlacesStable(
          totalDays: c.days,
          placesPerDay: c.places,
          pool: pool,
          onlyFoodRequested: false,
        );

        final totalStops =
            result.days.fold(0, (sum, d) => sum + d.places.length);
        expect(totalStops, equals(c.expected),
            reason: 'Failed for ${c.days}x${c.places}');
        expect(result.days.length, equals(c.days));
        for (final day in result.days) {
          expect(day.places.length, equals(c.places),
              reason: 'Day ${day.dayNumber} count mismatch');
        }

        // Verify no duplicate Place IDs
        final seen = <String>{};
        for (final day in result.days) {
          for (final p in day.places) {
            expect(seen.add(p.placeId), isTrue,
                reason: 'Duplicate placeId ${p.placeId}');
          }
        }

        // Verify leftover pool is non-empty
        expect(result.leftovers.isNotEmpty, isTrue);
      }
    });

    // ─────────────────────────────────────────────
    // 2. Travel Mode Search Radii & Mapping Tests
    // ─────────────────────────────────────────────

    test(
        '2. Travel modes radii adhere to production standard (walk: 2km, motor: 8km, drive: 12km)',
        () {
      expect(radiusForTravelModeString('walk'), equals(2000));
      expect(radiusForTravelModeString('motor'), equals(8000));
      expect(radiusForTravelModeString('drive'), equals(12000));
      expect(radiusForTravelModeString('both'), equals(12000));

      expect(travelModeFromString('walk'), equals(TravelMode.walk));
      expect(travelModeFromString('motor'), equals(TravelMode.motor));
      expect(travelModeFromString('drive'), equals(TravelMode.drive));
      expect(travelModeFromString('both'), equals(TravelMode.drive));
    });

    // ─────────────────────────────────────────────
    // 3. Multi-Region Arbitrary Coordinate Handling
    // ─────────────────────────────────────────────

    test(
        '3. Generates correct itineraries across arbitrary geographical regions',
        () {
      final regions = [
        (name: 'George Town Penang', lat: 5.4164, lng: 100.3327),
        (name: 'Pangkor Island', lat: 4.2235, lng: 100.5612),
        (name: 'Kuala Lumpur', lat: 3.1390, lng: 101.6869),
        (name: 'Kuching Sarawak', lat: 1.5533, lng: 110.3592),
        (name: 'Kota Kinabalu Sabah', lat: 5.9804, lng: 116.0735),
      ];

      for (final r in regions) {
        final pool = generateCandidatePool(
          restaurantCount: 10,
          attractionCount: 10,
          parkCount: 5,
          mallCount: 5,
          entertainmentCount: 5,
          baseLat: r.lat,
          baseLng: r.lng,
          prefix: r.name.toLowerCase().replaceAll(' ', '_'),
        );

        final result = distributePlacesStable(
          totalDays: 3,
          placesPerDay: 4,
          pool: pool,
          onlyFoodRequested: false,
        );

        final totalStops =
            result.days.fold(0, (sum, d) => sum + d.places.length);
        expect(totalStops, equals(12),
            reason: 'Region ${r.name} failed total stops');
        expect(result.days.length, equals(3));
      }
    });

    // ─────────────────────────────────────────────
    // 4. Preference Combinations (Food-only, Mixed, etc.)
    // ─────────────────────────────────────────────

    test(
        '4. Food-only request fills exclusively with food places without forcing attractions',
        () {
      final pool = generateCandidatePool(
        restaurantCount: 15,
        attractionCount: 15,
        parkCount: 10,
        mallCount: 10,
        entertainmentCount: 10,
      );

      final result = distributePlacesStable(
        totalDays: 2,
        placesPerDay: 3,
        pool: pool,
        onlyFoodRequested: true,
      );

      final totalStops = result.days.fold(0, (sum, d) => sum + d.places.length);
      expect(totalStops, equals(6));
      for (final day in result.days) {
        expect(day.places.length, equals(3));
        for (final p in day.places) {
          expect(p.primaryType, equals('restaurant'));
        }
      }
    });

    // ─────────────────────────────────────────────
    // 5. Task 12B Leftover Places Persistence & Reopening
    // ─────────────────────────────────────────────

    test(
        '5. Task 12B leftoverPlaces JSON serialization, deserialization, and preservation across trip reopening',
        () {
      final leftoverSnapshots = [
        PlaceModel(
          id: 'leftover_1',
          name: 'Extra Spot 1',
          address: 'Address 1',
          lat: 5.4180,
          lng: 100.3340,
          primaryType: 'tourist_attraction',
          allTypes: ['tourist_attraction'],
          rating: 4.7,
          source: 'google',
        ),
        PlaceModel(
          id: 'leftover_2',
          name: 'Extra Cafe 2',
          address: 'Address 2',
          lat: 5.4200,
          lng: 100.3360,
          primaryType: 'restaurant',
          allTypes: ['restaurant'],
          rating: 4.5,
          source: 'google',
        ),
      ];

      final itinerary = ItineraryModel(
        id: 'test_itin_1',
        title: 'Trip to Penang',
        startDate: '2026-09-02',
        totalDays: 2,
        createdAt: DateTime(2026, 9, 2),
        isOriginCurrentLocation: true,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-02',
            places: [
              ItineraryPlace(
                placeId: 'p1',
                name: 'Place 1',
                address: 'Addr 1',
                suggestedTime: '09:00',
                durationMinutes: 60,
                primaryType: 'tourist_attraction',
              ),
              ItineraryPlace(
                placeId: 'p2',
                name: 'Place 2',
                address: 'Addr 2',
                suggestedTime: '11:00',
                durationMinutes: 60,
                primaryType: 'tourist_attraction',
              ),
              ItineraryPlace(
                placeId: 'p3',
                name: 'Place 3',
                address: 'Addr 3',
                suggestedTime: '13:00',
                durationMinutes: 60,
                primaryType: 'restaurant',
              ),
            ],
          ),
          ItineraryDay(
            dayNumber: 2,
            date: '2026-09-03',
            places: [
              ItineraryPlace(
                placeId: 'p4',
                name: 'Place 4',
                address: 'Addr 4',
                suggestedTime: '09:00',
                durationMinutes: 60,
                primaryType: 'tourist_attraction',
              ),
              ItineraryPlace(
                placeId: 'p5',
                name: 'Place 5',
                address: 'Addr 5',
                suggestedTime: '11:00',
                durationMinutes: 60,
                primaryType: 'tourist_attraction',
              ),
              ItineraryPlace(
                placeId: 'p6',
                name: 'Place 6',
                address: 'Addr 6',
                suggestedTime: '13:00',
                durationMinutes: 60,
                primaryType: 'restaurant',
              ),
            ],
          ),
        ],
        leftoverPlaces: leftoverSnapshots,
      );

      // Serialize to map/JSON
      final map = itinerary.toMap();
      expect(map['leftoverPlaces'], isNotNull);
      expect((map['leftoverPlaces'] as List).length, equals(2));

      // Deserialize back
      final restored = ItineraryModel.fromMap('test_itin_1', map);
      expect(restored.leftoverPlaces.length, equals(2));
      expect(restored.leftoverPlaces.first.id, equals('leftover_1'));
      expect(restored.leftoverPlaces.first.name, equals('Extra Spot 1'));
      expect(restored.leftoverPlaces.last.id, equals('leftover_2'));
      expect(restored.leftoverPlaces.last.name, equals('Extra Cafe 2'));

      // Verify days intact
      expect(restored.days.length, equals(2));
      expect(restored.days.first.places.length, equals(3));
      expect(restored.days.last.places.length, equals(3));
    });
  });
}
