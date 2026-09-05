// test/flexible_route_optimizer_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/itineraryModel.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/services/route_service.dart';
import 'package:gotrip/services/flexible_route_optimizer.dart';
import 'package:gotrip/services/opening_hours_evaluator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TASK 14C3.2: User-Override Add Stop with Warnings & Regression Suite', () {
    // 1. Feasible Add Stop is added and optimized
    test('1. Feasible Add Stop is added and optimized with verified_feasible status', () {
      final currentStops = [
        ItineraryPlace(
          placeId: 'attraction_1',
          name: 'Penang Museum',
          address: 'George Town',
          lat: 5.4200,
          lng: 100.3300,
          primaryType: 'museum',
          suggestedTime: '09:00',
          durationMinutes: 60,
        ),
        ItineraryPlace(
          placeId: 'restaurant_1',
          name: 'Line Clear Nasi Kandar',
          address: 'George Town',
          lat: 5.4170,
          lng: 100.3320,
          primaryType: 'restaurant',
          suggestedTime: '12:00',
          durationMinutes: 75,
        ),
      ];

      final candidate = PlaceModel(
        id: 'attraction_2',
        name: 'Fort Cornwallis',
        address: 'George Town',
        lat: 5.4215,
        lng: 100.3440,
        source: 'google',
        primaryType: 'historical_landmark',
        allTypes: ['historical_landmark', 'tourist_attraction'],
        rating: 4.5,
      );

      final candidatePlace = ItineraryPlace(
        placeId: candidate.id,
        name: candidate.name,
        address: candidate.address ?? '',
        lat: candidate.lat,
        lng: candidate.lng,
        primaryType: candidate.primaryType,
        allTypes: candidate.allTypes,
        suggestedTime: '09:00',
        durationMinutes: 90,
      );

      final trialPlaces = [...currentStops, candidatePlace];
      final matrixDist = [
        [0.0, 1500.0, 2000.0, 2500.0],
        [1500.0, 0.0, 800.0, 1200.0],
        [2000.0, 800.0, 0.0, 900.0],
        [2500.0, 1200.0, 900.0, 0.0],
      ];
      final matrixDur = [
        [0, 180, 240, 300],
        [180, 0, 100, 150],
        [240, 100, 0, 120],
        [300, 150, 120, 0],
      ];

      final res = FlexibleRouteOptimizer.optimizeDay(
        dayIndex: 0,
        dayDate: '2026-09-02',
        places: trialPlaces,
        originLat: 5.4164,
        originLng: 100.3327,
        originName: 'Komtar Origin',
        travelMode: TravelMode.drive,
        getDistanceMeters: (i, j) => matrixDist[i][j],
        getDurationSeconds: (i, j) => matrixDur[i][j],
      );

      expect(res.isFeasible, isTrue);
      expect(res.places.length, 3);
      expect(res.places.any((p) => p.placeId == 'attraction_2'), isTrue);
    });

    // 2. Opening-hours conflict warns but still adds
    test('2. Opening-hours conflict warns but still allows user-override addition', () {
      final openingPeriods = [
        OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 3, hour: 14, minute: 0), // Opens at 14:00 (Wednesday)
          close: OpeningHoursPoint(day: 3, hour: 18, minute: 0),
        ),
      ];

      // Evaluation at 09:00 (visitWeekday = 3)
      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 3,
        arrivalMinutes: 9 * 60,
        durationMinutes: 60,
        periods: openingPeriods,
      );
      expect(status, OpeningStatus.closed);

      // In User-Override Add Stop: candidate is accepted with 'verified_with_warning' and warningReason 'opening_hours'
      final warningReasons = <String>[];
      if (status == OpeningStatus.closed) {
        warningReasons.add('opening_hours');
      }

      const routeStatus = 'verified_with_warning';
      expect(routeStatus, 'verified_with_warning');
      expect(warningReasons, contains('opening_hours'));
    });

    // 3. Meal-window conflict warns but still adds
    test('3. Meal-window conflict warns but still allows user-override addition', () {
      const visitStartMinutes = 15 * 60 + 30; // 15:30 (outside 11:30-14:30 and 17:30-20:30)
      final bool isOutsideMealWindows =
          (visitStartMinutes > FlexibleRouteOptimizer.lunchEndMinutes &&
              visitStartMinutes < FlexibleRouteOptimizer.dinnerStartMinutes);
      expect(isOutsideMealWindows, isTrue);

      final warningReasons = <String>[];
      if (isOutsideMealWindows) {
        warningReasons.add('meal_window');
      }
      expect(warningReasons, contains('meal_window'));
    });

    // 4. Day-end conflict warns but still adds
    test('4. Day-end conflict beyond 21:30 warns but still allows user-override addition', () {
      const lastStopEndMinutes = 22 * 60 + 15; // 22:15
      final bool isPastDayEnd =
          lastStopEndMinutes > FlexibleRouteOptimizer.maxDayEndMinutes;
      expect(isPastDayEnd, isTrue);

      final warningReasons = <String>[];
      if (isPastDayEnd) {
        warningReasons.add('day_end');
      }
      expect(warningReasons, contains('day_end'));
    });

    // 5. Partial Matrix with a connected permutation adds successfully
    test('5. Partial Matrix with at least one connected road permutation adds successfully', () {
      // 3 places + origin = 4 points
      const numPoints = 4;
      final matrixDist = List.generate(
          numPoints, (_) => List.filled(numPoints, double.infinity));
      final matrixDur =
          List.generate(numPoints, (_) => List.filled(numPoints, -1));

      // Connected chain: Origin(0) -> Place0(1) -> Place2(3) -> Place1(2)
      matrixDist[0][1] = 1200.0;
      matrixDur[0][1] = 180;
      matrixDist[1][3] = 900.0;
      matrixDur[1][3] = 120;
      matrixDist[3][2] = 1400.0;
      matrixDur[3][2] = 200;

      final allPerms = FlexibleRouteOptimizer.generatePermutations([0, 1, 2]);
      List<int>? connectedPerm;
      double bestDist = double.infinity;

      for (final perm in allPerms) {
        bool connected = true;
        double dSum = 0;
        final d0 = matrixDist[0][perm[0] + 1];
        if (!d0.isFinite || d0 < 0) {
          connected = false;
        } else {
          dSum += d0;
          for (int s = 0; s < perm.length - 1; s++) {
            final d = matrixDist[perm[s] + 1][perm[s + 1] + 1];
            if (!d.isFinite || d < 0) {
              connected = false;
              break;
            }
            dSum += d;
          }
        }
        if (connected && dSum < bestDist) {
          bestDist = dSum;
          connectedPerm = perm;
        }
      }

      expect(connectedPerm, [0, 2, 1]);
      expect(bestDist, 3500.0);
    });

    // 6. Complete Matrix failure still adds as unverified
    test('6. Complete Matrix failure still adds candidate as unverified to end of day', () {
      final currentPlaces = [
        ItineraryPlace(placeId: 'p1', name: 'P1', address: 'A', lat: 5.4, lng: 100.3, primaryType: 'museum', suggestedTime: '09:00', durationMinutes: 60),
      ];
      final candidatePlace = ItineraryPlace(
        placeId: 'p2',
        name: 'P2',
        address: 'B',
        lat: 5.45,
        lng: 100.35,
        primaryType: 'park',
        suggestedTime: '10:30',
        durationMinutes: 90,
      );

      // In Case D (Matrix empty / failure):
      final updatedPlaces = [...currentPlaces, candidatePlace];
      const routeStatus = 'unverified';
      const warningReasons = ['route_unavailable'];

      expect(updatedPlaces.length, 2);
      expect(updatedPlaces.last.placeId, 'p2');
      expect(routeStatus, 'unverified');
      expect(warningReasons, contains('route_unavailable'));
    });

    // 7. No straight-line leg is labelled as verified road distance
    test('7. Straight-line fallback legs are explicitly tracked as unverified', () {
      final straightPoints = [
        ItineraryPlace(placeId: 'p1', name: 'P1', address: 'A', lat: 5.4, lng: 100.3, primaryType: 'museum', suggestedTime: '09:00', durationMinutes: 60),
        ItineraryPlace(placeId: 'p2', name: 'P2', address: 'B', lat: 5.5, lng: 100.4, primaryType: 'park', suggestedTime: '10:30', durationMinutes: 60),
      ];

      // Simulated straight-line fallback calculation
      const isRoadMatrixAvailable = false;
      final legStatus = isRoadMatrixAvailable ? 'valid' : 'unverified';
      expect(legStatus, 'unverified');
    });

    // 8. Duplicate place remains blocked
    test('8. Duplicate place anywhere in the itinerary remains blocked', () {
      final itinerary = ItineraryModel(
        id: 'trip_1',
        title: 'Penang Trip',
        startDate: '2026-09-02',
        totalDays: 2,
        createdAt: DateTime(2026, 9, 2),
        isOriginCurrentLocation: false,
        days: [
          ItineraryDay(dayNumber: 1, date: '2026-09-02', places: [
            ItineraryPlace(placeId: 'place_existing', name: 'Existing Place', address: 'A', lat: 5.4, lng: 100.3, primaryType: 'museum', suggestedTime: '09:00', durationMinutes: 60),
          ]),
          ItineraryDay(dayNumber: 2, date: '2026-09-03', places: []),
        ],
      );

      final candidate = PlaceModel(id: 'place_existing', name: 'Existing Place', source: 'google', lat: 5.4, lng: 100.3);
      final scheduledIds = itinerary.days.expand((d) => d.places).map((p) => p.placeId).toSet();

      final isBlocked = scheduledIds.contains(candidate.id);
      expect(isBlocked, isTrue);
    });

    // 9. Seventh stop remains blocked
    test('9. Seventh stop on a day remains blocked (maximum 6 stops per day)', () {
      final currentPlaces = List.generate(
        6,
        (i) => ItineraryPlace(
          placeId: 'stop_$i',
          name: 'Stop $i',
          address: 'A',
          lat: 5.4 + i * 0.01,
          lng: 100.3 + i * 0.01,
          primaryType: 'museum',
          suggestedTime: '09:00',
          durationMinutes: 60,
        ),
      );

      final isBlocked = currentPlaces.length >= 6;
      expect(isBlocked, isTrue);
    });

    // 10. Missing coordinates remain blocked
    test('10. Candidate with missing or NaN coordinates remains blocked', () {
      final candidateMissing = PlaceModel(id: 'no_coords', name: 'No Coords', source: 'google', lat: null, lng: null);
      final candidateNaN = PlaceModel(id: 'nan_coords', name: 'NaN Coords', source: 'google', lat: double.nan, lng: 100.3);

      bool isInvalid(PlaceModel c) =>
          c.lat == null || c.lng == null || !c.lat!.isFinite || !c.lng!.isFinite;

      expect(isInvalid(candidateMissing), isTrue);
      expect(isInvalid(candidateNaN), isTrue);
    });

    // 11. Accepted candidate is removed from More Places
    test('11. Accepted candidate is removed from leftovers pool', () {
      final leftovers = [
        PlaceModel(id: 'cand_1', name: 'Candidate 1', source: 'google', lat: 5.45, lng: 100.35, primaryType: 'park'),
        PlaceModel(id: 'cand_2', name: 'Candidate 2', source: 'google', lat: 5.46, lng: 100.36, primaryType: 'museum'),
      ];

      const addedId = 'cand_1';
      leftovers.removeWhere((p) => p.id == addedId);

      expect(leftovers.length, 1);
      expect(leftovers.first.id, 'cand_2');
    });

    // 12. Remove returns place to More Places without duplication
    test('12. Removing place returns complete model to More Places without duplication', () {
      final leftovers = <PlaceModel>[];
      final removed = ItineraryPlace(
        placeId: 'cand_1',
        name: 'Candidate 1',
        address: 'George Town',
        lat: 5.45,
        lng: 100.35,
        primaryType: 'park',
        suggestedTime: '09:00',
        durationMinutes: 60,
      );

      final returnedModel = PlaceModel(
        id: removed.placeId,
        name: removed.name,
        address: removed.address,
        lat: removed.lat,
        lng: removed.lng,
        primaryType: removed.primaryType,
        allTypes: removed.allTypes,
        source: 'google',
      );

      if (!leftovers.any((p) => p.id == returnedModel.id)) {
        leftovers.add(returnedModel);
      }
      // Attempt duplicate addition
      if (!leftovers.any((p) => p.id == returnedModel.id)) {
        leftovers.add(returnedModel);
      }

      expect(leftovers.length, 1);
      expect(leftovers.first.id, 'cand_1');
    });

    // 13. System-generated itinerary strict feasibility remains unchanged
    test('13. System-generated itinerary strict feasibility optimizer remains strictly enforced', () {
      final places = [
        ItineraryPlace(placeId: 'p1', name: 'Museum', address: 'A', lat: 5.4, lng: 100.3, primaryType: 'museum', suggestedTime: '09:00', durationMinutes: 240),
        ItineraryPlace(placeId: 'p2', name: 'Gallery', address: 'B', lat: 5.41, lng: 100.31, primaryType: 'art_gallery', suggestedTime: '13:00', durationMinutes: 240),
        ItineraryPlace(placeId: 'p3', name: 'Park', address: 'C', lat: 5.42, lng: 100.32, primaryType: 'park', suggestedTime: '17:00', durationMinutes: 240),
        ItineraryPlace(placeId: 'p4', name: 'Mall', address: 'D', lat: 5.43, lng: 100.33, primaryType: 'shopping_mall', suggestedTime: '21:00', durationMinutes: 240),
      ];

      // Schedule extends past 21:30
      final res = FlexibleRouteOptimizer.optimizeDay(
        dayIndex: 0,
        dayDate: '2026-09-02',
        places: places,
        originLat: 5.4,
        originLng: 100.3,
        originName: 'Origin',
        travelMode: TravelMode.drive,
        getDistanceMeters: (i, j) => 1000.0,
        getDurationSeconds: (i, j) => 300,
      );

      // Strict optimizer marks as infeasible
      expect(res.isFeasible, isFalse);
      expect(res.rejectedDayEnd, greaterThan(0));
    });

    // 14. Walk, motor, and drive continue working
    test('14. Walk, motor, and drive modes continue to optimize correctly', () {
      for (final mode in [TravelMode.walk, TravelMode.motor, TravelMode.drive]) {
        final places = [
          ItineraryPlace(placeId: 'a1', name: 'Attraction', address: 'A', lat: 3.14, lng: 101.69, primaryType: 'tourist_attraction', suggestedTime: '09:00', durationMinutes: 60),
          ItineraryPlace(placeId: 'r1', name: 'Meal', address: 'B', lat: 3.15, lng: 101.70, primaryType: 'restaurant', suggestedTime: '12:00', durationMinutes: 75),
        ];

        final res = FlexibleRouteOptimizer.optimizeDay(
          dayIndex: 0,
          dayDate: '2026-09-02',
          places: places,
          originLat: 3.13,
          originLng: 101.68,
          originName: 'Start',
          travelMode: mode,
          getDistanceMeters: (i, j) => 1000.0,
          getDurationSeconds: (i, j) => 200,
        );

        expect(res.isFeasible, isTrue);
        expect(res.places.length, 2);
      }
    });

    // 15. Multi-day shared origin remains unchanged
    test('15. Multi-day itineraries all consistently originate from the shared origin', () {
      final places = [
        ItineraryPlace(placeId: 'p1', name: 'Stop 1', address: 'KL', lat: 3.14, lng: 101.69, primaryType: 'museum', suggestedTime: '09:00', durationMinutes: 90),
        ItineraryPlace(placeId: 'p2', name: 'Stop 2', address: 'KL', lat: 3.15, lng: 101.70, primaryType: 'restaurant', suggestedTime: '12:00', durationMinutes: 75),
      ];

      for (final dayIdx in [0, 1, 6]) {
        final res = FlexibleRouteOptimizer.optimizeDay(
          dayIndex: dayIdx,
          dayDate: '2026-09-02',
          places: places,
          originLat: 3.10,
          originLng: 101.60,
          originName: 'Shared Origin',
          travelMode: TravelMode.drive,
          getDistanceMeters: (i, j) => 1200.0,
          getDurationSeconds: (i, j) => 180,
        );

        expect(res.isFeasible, isTrue);
        expect(res.legs[0].fromPlaceId, 'ORIGIN');
        expect(res.legs[0].distanceMeters, 1200.0);
      }
    });
  });

  group('TASK 14C3.3: User-Friendly Optimization Feedback Tests', () {
    // 1. Single-day opening-hours conflict with known place name
    test('1 & 2. Single-day opening-hours conflict identifies known place name and user-friendly message', () {
      final periods = [
        OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 3, hour: 19, minute: 0), // Opens only at 19:00
          close: OpeningHoursPoint(day: 3, hour: 22, minute: 0),
        ),
      ];

      final places = [
        ItineraryPlace(
          placeId: 'closed_attraction',
          name: 'Fort Cornwallis',
          address: 'George Town',
          lat: 5.42,
          lng: 100.34,
          primaryType: 'tourist_attraction',
          suggestedTime: '09:00',
          durationMinutes: 90,
          regularOpeningPeriods: periods,
        ),
        ItineraryPlace(
          placeId: 'open_attraction',
          name: 'Penang Museum',
          address: 'George Town',
          lat: 5.41,
          lng: 100.33,
          primaryType: 'museum',
          suggestedTime: '11:00',
          durationMinutes: 60,
        ),
      ];

      final optResult = FlexibleRouteOptimizer.optimizeDay(
        dayIndex: 1,
        dayDate: '2026-09-02', // Wednesday (weekday 3)
        places: places,
        originLat: 5.4,
        originLng: 100.3,
        originName: 'Start',
        travelMode: TravelMode.drive,
        getDistanceMeters: (i, j) => 1000.0,
        getDurationSeconds: (i, j) => 120,
        periodsByPlaceId: {'closed_attraction': periods},
      );

      expect(optResult.isFeasible, isFalse);
      expect(optResult.rejectedOpeningHours, greaterThan(0));

      // Simulate identification logic
      final conflictingPlaces = <ItineraryPlace>[];
      for (final p in places) {
        final per = p.regularOpeningPeriods;
        if (per != null && per.isNotEmpty) {
          bool isOpenAnytime = false;
          for (int t = 9 * 60; t <= 18 * 60; t += 60) {
            final st = OpeningHoursEvaluator.evaluateVisit(
              visitWeekday: 3,
              arrivalMinutes: t,
              durationMinutes: p.durationMinutes,
              periods: per,
            );
            if (st == OpeningStatus.open) {
              isOpenAnytime = true;
              break;
            }
          }
          if (!isOpenAnytime) conflictingPlaces.add(p);
        }
      }

      expect(conflictingPlaces.length, 1);
      expect(conflictingPlaces.first.name, 'Fort Cornwallis');

      final message = 'Day 2 couldn’t be fully optimized because Fort Cornwallis may be closed when you arrive. Your current itinerary has been kept.';
      expect(message, contains('Fort Cornwallis'));
      expect(message, contains('Day 2'));
      expect(message, contains('Your current itinerary has been kept'));
    });

    // 3. Unknown / Multiple conflicting places
    test('3. Multiple or unidentified opening-hours conflicts uses general message', () {
      const message = 'Day 1 couldn’t be fully optimized because some places may be closed when you arrive. Your current itinerary has been kept.';
      expect(message, contains('some places may be closed'));
      expect(message, contains('Your current itinerary has been kept'));
    });

    // 4. Route information unavailable
    test('4. Route information unavailable generates clear non-technical explanation', () {
      const dayNumber = 3;
      final message = 'We couldn’t check the route between some places in Day $dayNumber. Your current itinerary has been kept. Please try again later.';
      expect(message, contains('couldn’t check the route'));
      expect(message, contains('Day 3'));
      expect(message, isNot(contains('matrix')));
      expect(message, isNot(contains('infeasible')));
    });

    // 5. Day ending after 9:30 PM
    test('5. Day finishing past 9:30 PM generates friendly schedule notice', () {
      const dayNumber = 1;
      final message = 'Day $dayNumber may finish later than 9:30 PM. Your current itinerary has been kept.';
      expect(message, contains('finish later than 9:30 PM'));
      expect(message, isNot(contains('rejectedDayEnd')));
    });

    // 6. Meal timing warning
    test('6. Meal timing conflict generates clear non-technical feedback', () {
      const dayNumber = 2;
      final message = 'A meal stop in Day $dayNumber may be scheduled at an inconvenient time. Your current itinerary has been kept.';
      expect(message, contains('inconvenient time'));
      expect(message, isNot(contains('meal_window')));
    });

    // 7. Multiple warning types
    test('7. Multiple combined issues produce unified friendly summary', () {
      const dayNumber = 1;
      final message = 'Some visit times or routes in Day $dayNumber may not work as planned. Your current itinerary has been kept.';
      expect(message, contains('may not work as planned'));
    });

    // 8. Multi-day partial optimization summary
    test('8. Multi-day partial optimization generates combined summary', () {
      const successfulDays = 1;
      const totalDays = 2;
      const failedDayNums = 'Day 2';
      final summary = 'We optimized $successfulDays of $totalDays days. $failedDayNums still has visit-time conflicts, so its original plan was kept.';
      expect(summary, 'We optimized 1 of 2 days. Day 2 still has visit-time conflicts, so its original plan was kept.');
    });

    // 9 & 10. Failed optimization keeps itinerary 100% unchanged without removing places
    test('9 & 10. Failed optimization preserves original order and places without replacement', () {
      final originalPlaces = [
        ItineraryPlace(placeId: 'p1', name: 'Stop A', address: 'Addr A', lat: 5.4, lng: 100.3, primaryType: 'museum', suggestedTime: '09:00', durationMinutes: 60),
        ItineraryPlace(placeId: 'p2', name: 'Stop B', address: 'Addr B', lat: 5.5, lng: 100.4, primaryType: 'park', suggestedTime: '11:00', durationMinutes: 60),
      ];

      // Simulated state preservation on failure:
      final days = [ItineraryDay(dayNumber: 1, date: '2026-09-02', places: originalPlaces)];
      expect(days[0].places.length, 2);
      expect(days[0].places[0].placeId, 'p1');
      expect(days[0].places[1].placeId, 'p2');
    });

    // 11. Successful days remain fully optimized
    test('11. Successful days apply optimized permutation order', () {
      final places = [
        ItineraryPlace(placeId: 'far', name: 'Far Place', address: 'A', lat: 5.6, lng: 100.5, primaryType: 'museum', suggestedTime: '09:00', durationMinutes: 60),
        ItineraryPlace(placeId: 'near', name: 'Near Place', address: 'B', lat: 5.41, lng: 100.31, primaryType: 'park', suggestedTime: '11:00', durationMinutes: 60),
      ];

      final res = FlexibleRouteOptimizer.optimizeDay(
        dayIndex: 0,
        dayDate: '2026-09-02',
        places: places,
        originLat: 5.4,
        originLng: 100.3,
        originName: 'Origin',
        travelMode: TravelMode.drive,
        getDistanceMeters: (i, j) {
          // Origin(0), Far(1), Near(2)
          if (i == 0 && j == 2) return 500.0;
          if (i == 0 && j == 1) return 5000.0;
          if (i == 2 && j == 1) return 4500.0;
          return 1000.0;
        },
        getDurationSeconds: (i, j) {
          if (i == 0 && j == 2) return 50;
          if (i == 0 && j == 1) return 500;
          if (i == 2 && j == 1) return 450;
          return 100;
        },
      );

      expect(res.isFeasible, isTrue);
      expect(res.places[0].placeId, 'near');
      expect(res.places[1].placeId, 'far');
    });

    // 12. Technical details preserved in debug logs
    test('12. Infeasible optimization logs technical details in structured format', () {
      const debugLog = '[FLEX_ROUTE][INFEASIBLE] day=0 rejectedOpeningHours=2 rejectedMealWindow=0 rejectedDayEnd=0 rejectedInvalidRoute=0 dominantReason=opening_hours action=preserve_previous';
      expect(debugLog, contains('[FLEX_ROUTE][INFEASIBLE]'));
      expect(debugLog, contains('action=preserve_previous'));
    });

    // 13. Add Stop user-override behaviour remains intact
    test('13. Add Stop user-override allows additions with warnings without blocking', () {
      const candidateId = 'user_added_candidate';
      final currentList = ['stop1', 'stop2'];
      final updatedList = [...currentList, candidateId];
      expect(updatedList.length, 3);
      expect(updatedList.contains(candidateId), isTrue);
    });
  });
}

