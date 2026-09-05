import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gotrip/models/itineraryModel.dart';
import 'package:gotrip/services/arrival_policy.dart';
import 'package:gotrip/services/location_service.dart';
import 'package:gotrip/services/navigate_service.dart';
import 'package:gotrip/services/route_service.dart';

Position _createPosition({
  required double latitude,
  required double longitude,
  double accuracy = 5.0,
  double speed = 0.0,
  DateTime? timestamp,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp ?? DateTime.now(),
    accuracy: accuracy,
    altitude: 10.0,
    heading: 0.0,
    speed: speed,
    speedAccuracy: 1.0,
    altitudeAccuracy: 1.0,
    headingAccuracy: 1.0,
  );
}

ItineraryPlace _createPlace({
  required String id,
  required String name,
  double? lat,
  double? lng,
  bool isVisited = false,
  DateTime? visitedAt,
}) {
  return ItineraryPlace(
    placeId: id,
    name: name,
    address: 'Test Address',
    suggestedTime: '10:00',
    durationMinutes: 60,
    lat: lat,
    lng: lng,
    isVisited: isVisited,
    visitedAt: visitedAt,
  );
}

ItineraryModel _createItinerary({
  required String id,
  required String title,
  required String date,
  required List<ItineraryPlace> places,
  List<ItineraryDay>? extraDays,
}) {
  return ItineraryModel(
    id: id,
    title: title,
    startDate: date,
    totalDays: 1 + (extraDays?.length ?? 0),
    days: [
      ItineraryDay(
        dayNumber: 1,
        date: date,
        places: places,
      ),
      if (extraDays != null) ...extraDays,
    ],
    createdAt: DateTime(2026, 9, 1),
    isOriginCurrentLocation: false,
  );
}

RouteResult _createRoute({
  required List<LatLng> points,
  List<NavStep>? steps,
}) {
  double totalDist = 0.0;
  for (int i = 0; i < points.length - 1; i++) {
    totalDist += Geolocator.distanceBetween(
      points[i].latitude,
      points[i].longitude,
      points[i + 1].latitude,
      points[i + 1].longitude,
    );
  }

  return RouteResult(
    polylinePoints: points,
    steps: steps ??
        [
          NavStep(
            instruction: 'Arrive at destination',
            maneuver: 'straight',
            distanceMeters: totalDist,
            durationSeconds: 60,
            startLocation: points.first,
            endLocation: points.last,
            polylinePoints: points,
          ),
        ],
    distanceMeters: totalDist,
    durationSeconds: 60,
    bounds: LatLngBounds(
      southwest: points.first,
      northeast: points.last,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final locService = LocationService.instance;
  final fixedDate = DateTime(2026, 9, 5, 10, 0);
  const fixedDateStr = '2026-09-05';

  setUp(() {
    locService.resetForTesting();
    locService.testNowProvider = () => fixedDate;
  });

  tearDown(() {
    locService.resetForTesting();
  });

  group('Shared Arrival Policy Specification Verification', () {
    test('Policy constants match unified requirements', () {
      expect(ArrivalPolicy.arrivalRadiusMetres, equals(15.0));
      expect(ArrivalPolicy.maximumArrivalAccuracyMetres, equals(20.0));
      expect(ArrivalPolicy.requiredConsecutiveFixes, equals(2));
      expect(LocationService.arrivalRadiusMetres, equals(15.0));
      expect(NavigationController.arrivedThresh, equals(15.0));
    });

    test('1. Itinerary arrival does not trigger at 26 metres', () async {
      // Chew Jetty at lat: 5.4164, lng: 100.3327
      final place = _createPlace(
        id: 'place_1',
        name: 'Chew Jetty',
        lat: 5.4164,
        lng: 100.3327,
      );
      final itin = _createItinerary(
        id: 'itin_1',
        title: 'Penang Tour',
        date: fixedDateStr,
        places: [place],
      );
      locService.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(events.add);

      // 26 metres north: delta lat = 0.000234 (~26.0m)
      final pos26m = _createPosition(
        latitude: 5.4164 + 0.000234,
        longitude: 100.3327,
        accuracy: 5.0,
      );

      // Send multiple fixes at 26m
      for (int i = 0; i < 5; i++) {
        locService.simulatePositionChange(pos26m);
      }
      await pumpEventQueue();

      expect(events.isEmpty, isTrue);
      expect(locService.isPlaceArrived('place_1'), isFalse);
      expect(locService.getConsecutiveArrivalFixes('place_1'), equals(0));

      await sub.cancel();
    });

    test('2. GPS Navigation arrival does not trigger at 26 metres', () async {
      const start = LatLng(5.0000, 100.0000);
      const end = LatLng(5.0010, 100.0000); // ~111m away
      final route = _createRoute(points: [start, end]);

      final nav = NavigationController(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // Position ~26m south of destination: 5.0010 - 0.000234 (~26.0m)
      final pos26m = _createPosition(
        latitude: end.latitude - 0.000234,
        longitude: end.longitude,
        accuracy: 5.0,
      );

      for (int i = 0; i < 5; i++) {
        await nav.handlePositionForTesting(pos26m);
      }

      expect(nav.hasArrived, isFalse);
      expect(nav.consecutiveArrivalFixes, equals(0));
      nav.dispose();
    });

    test('3. A single qualifying fix at or below 15 metres does not trigger',
        () async {
      // Itinerary test
      final place = _createPlace(
        id: 'place_single_fix',
        name: 'Town Hall',
        lat: 5.4164,
        lng: 100.3327,
      );
      final itin = _createItinerary(
        id: 'itin_single',
        title: 'Single Fix Trip',
        date: fixedDateStr,
        places: [place],
      );
      locService.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(events.add);

      // ~10m away with good accuracy
      final qualifyingPos = _createPosition(
        latitude: 5.4164 + 0.00009,
        longitude: 100.3327,
        accuracy: 5.0,
      );

      locService.simulatePositionChange(qualifyingPos);
      await pumpEventQueue();

      expect(events.isEmpty, isTrue);
      expect(locService.isPlaceArrived('place_single_fix'), isFalse);
      expect(
          locService.getConsecutiveArrivalFixes('place_single_fix'), equals(1));
      await sub.cancel();

      // GPS Navigation test
      const start = LatLng(5.0000, 100.0000);
      const end = LatLng(5.0010, 100.0000);
      final route = _createRoute(points: [start, end]);

      final nav = NavigationController(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // ~10m from end: delta lat = 0.00009 (~10.0m)
      final navQualifyingPos = _createPosition(
        latitude: end.latitude - 0.00009,
        longitude: end.longitude,
        accuracy: 5.0,
      );

      await nav.handlePositionForTesting(navQualifyingPos);
      expect(nav.hasArrived, isFalse);
      expect(nav.consecutiveArrivalFixes, equals(1));
      nav.dispose();
    });

    test(
        '4. Two consecutive qualifying fixes at or below 15 metres trigger once',
        () async {
      // Itinerary test
      final place = _createPlace(
        id: 'place_two_fix',
        name: 'Fort Cornwallis',
        lat: 5.4164,
        lng: 100.3327,
      );
      final itin = _createItinerary(
        id: 'itin_two',
        title: 'Two Fix Trip',
        date: fixedDateStr,
        places: [place],
      );
      locService.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(events.add);

      final qualifyingPos = _createPosition(
        latitude: 5.4164 + 0.00008, // ~8.9m
        longitude: 100.3327,
        accuracy: 10.0,
      );

      // Fix 1
      locService.simulatePositionChange(qualifyingPos);
      await pumpEventQueue();
      expect(events.length, equals(0));

      // Fix 2 -> Triggers arrival!
      locService.simulatePositionChange(qualifyingPos);
      await pumpEventQueue();
      expect(events.length, equals(1));
      expect(events.first.placeId, equals('place_two_fix'));
      expect(locService.isPlaceArrived('place_two_fix'), isTrue);

      // Fix 3 -> Suppressed (does not fire again)
      locService.simulatePositionChange(qualifyingPos);
      await pumpEventQueue();
      expect(events.length, equals(1));
      await sub.cancel();

      // Navigation test
      const start = LatLng(5.0000, 100.0000);
      const end = LatLng(5.0010, 100.0000);
      final route = _createRoute(points: [start, end]);

      int navArrivalCalls = 0;
      final nav = NavigationController(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
        initialRoute: route,
      );
      nav.onArrived = () => navArrivalCalls++;
      await nav.applyRouteResult(route);

      final navQualifyingPos = _createPosition(
        latitude: end.latitude - 0.00008,
        longitude: end.longitude,
        accuracy: 12.0,
      );

      // Fix 1
      await nav.handlePositionForTesting(navQualifyingPos);
      expect(nav.hasArrived, isFalse);
      expect(navArrivalCalls, equals(0));

      // Fix 2 -> Triggers arrival!
      await nav.handlePositionForTesting(navQualifyingPos);
      expect(nav.hasArrived, isTrue);
      expect(navArrivalCalls, equals(1));

      // Fix 3 -> Does not fire again
      await nav.handlePositionForTesting(navQualifyingPos);
      expect(navArrivalCalls, equals(1));
      nav.dispose();
    });

    test(
        '5. A qualifying fix, followed by a failing fix, followed by another qualifying fix does not trigger because consecutive count was reset',
        () async {
      // Itinerary test
      final place = _createPlace(
        id: 'place_reset_test',
        name: 'Kek Lok Si',
        lat: 5.4164,
        lng: 100.3327,
      );
      final itin = _createItinerary(
        id: 'itin_reset',
        title: 'Reset Trip',
        date: fixedDateStr,
        places: [place],
      );
      locService.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(events.add);

      final qualifyingPos = _createPosition(
        latitude: 5.4164 + 0.00008, // ~8.9m
        longitude: 100.3327,
        accuracy: 8.0,
      );
      final failingPos = _createPosition(
        latitude: 5.4164 + 0.00030, // ~33.3m (failing distance)
        longitude: 100.3327,
        accuracy: 5.0,
      );

      // Fix 1: Qualifying -> count = 1
      locService.simulatePositionChange(qualifyingPos);
      await pumpEventQueue();
      expect(
          locService.getConsecutiveArrivalFixes('place_reset_test'), equals(1));
      expect(events.isEmpty, isTrue);

      // Fix 2: Failing -> count reset to 0
      locService.simulatePositionChange(failingPos);
      await pumpEventQueue();
      expect(
          locService.getConsecutiveArrivalFixes('place_reset_test'), equals(0));
      expect(events.isEmpty, isTrue);

      // Fix 3: Qualifying -> count = 1 (NOT 2)
      locService.simulatePositionChange(qualifyingPos);
      await pumpEventQueue();
      expect(
          locService.getConsecutiveArrivalFixes('place_reset_test'), equals(1));
      expect(events.isEmpty, isTrue);
      expect(locService.isPlaceArrived('place_reset_test'), isFalse);
      await sub.cancel();

      // Navigation test
      const start = LatLng(5.0000, 100.0000);
      const end = LatLng(5.0010, 100.0000);
      final route = _createRoute(points: [start, end]);

      final nav = NavigationController(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      final navQualifyingPos = _createPosition(
        latitude: end.latitude - 0.00008,
        longitude: end.longitude,
        accuracy: 5.0,
      );
      final navFailingPos = _createPosition(
        latitude: end.latitude - 0.00030,
        longitude: end.longitude,
        accuracy: 5.0,
      );

      // Fix 1: Qualifying -> count = 1
      await nav.handlePositionForTesting(navQualifyingPos);
      expect(nav.consecutiveArrivalFixes, equals(1));
      expect(nav.hasArrived, isFalse);

      // Fix 2: Failing -> count = 0
      await nav.handlePositionForTesting(navFailingPos);
      expect(nav.consecutiveArrivalFixes, equals(0));
      expect(nav.hasArrived, isFalse);

      // Fix 3: Qualifying -> count = 1
      await nav.handlePositionForTesting(navQualifyingPos);
      expect(nav.consecutiveArrivalFixes, equals(1));
      expect(nav.hasArrived, isFalse);
      nav.dispose();
    });

    test(
        '6. A fix inside 15 metres with GPS accuracy greater than 20 metres does not trigger',
        () async {
      // Itinerary test
      final place = _createPlace(
        id: 'place_inaccurate',
        name: 'Botanical Gardens',
        lat: 5.4164,
        lng: 100.3327,
      );
      final itin = _createItinerary(
        id: 'itin_inaccurate',
        title: 'Inaccurate Trip',
        date: fixedDateStr,
        places: [place],
      );
      locService.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(events.add);

      // Inside 15m (5m away), but accuracy is 25m (exceeds max 20m)
      final inaccuratePos = _createPosition(
        latitude: 5.4164 + 0.00004,
        longitude: 100.3327,
        accuracy: 25.0,
      );

      // Even multiple fixes with >20m accuracy must never qualify
      for (int i = 0; i < 3; i++) {
        locService.simulatePositionChange(inaccuratePos);
      }
      await pumpEventQueue();

      expect(events.isEmpty, isTrue);
      expect(locService.isPlaceArrived('place_inaccurate'), isFalse);
      expect(
          locService.getConsecutiveArrivalFixes('place_inaccurate'), equals(0));
      await sub.cancel();

      // Navigation test
      const start = LatLng(5.0000, 100.0000);
      const end = LatLng(5.0010, 100.0000);
      final route = _createRoute(points: [start, end]);

      final nav = NavigationController(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      final navInaccuratePos = _createPosition(
        latitude: end.latitude - 0.00004,
        longitude: end.longitude,
        accuracy: 25.0,
      );

      for (int i = 0; i < 3; i++) {
        await nav.handlePositionForTesting(navInaccuratePos);
      }

      expect(nav.hasArrived, isFalse);
      expect(nav.consecutiveArrivalFixes, equals(0));
      nav.dispose();
    });

    test('7. Non-finite accuracy does not trigger', () {
      expect(
        ArrivalPolicy.isQualifyingFix(
          distanceMetres: 5.0,
          accuracyMetres: double.nan,
        ),
        isFalse,
      );
      expect(
        ArrivalPolicy.isQualifyingFix(
          distanceMetres: 5.0,
          accuracyMetres: double.infinity,
        ),
        isFalse,
      );
      expect(
        ArrivalPolicy.isQualifyingFix(
          distanceMetres: 5.0,
          accuracyMetres: -1.0,
        ),
        isFalse,
      );
      expect(
        ArrivalPolicy.isQualifyingFix(
          distanceMetres: 5.0,
          accuracyMetres: 19.9,
        ),
        isTrue,
      );
      expect(
        ArrivalPolicy.isQualifyingFix(
          distanceMetres: 5.0,
          accuracyMetres: 20.0,
        ),
        isTrue,
      );
      expect(
        ArrivalPolicy.isQualifyingFix(
          distanceMetres: 5.0,
          accuracyMetres: 20.1,
        ),
        isFalse,
      );
    });

    test('8. Navigation still requires the final navigation step', () async {
      const p0 = LatLng(5.0000, 100.0000);
      const p1 = LatLng(5.0050, 100.0000);
      const p2 = LatLng(5.0100, 100.0000);

      const step1 = NavStep(
        instruction: 'Continue straight',
        maneuver: 'straight',
        distanceMeters: 556.0,
        durationSeconds: 60,
        startLocation: p0,
        endLocation: p1,
        polylinePoints: [p0, p1],
      );
      const step2 = NavStep(
        instruction: 'Arrive at destination',
        maneuver: 'straight',
        distanceMeters: 556.0,
        durationSeconds: 60,
        startLocation: p1,
        endLocation: p2,
        polylinePoints: [p1, p2],
      );

      final route = RouteResult(
        polylinePoints: [p0, p1, p2],
        steps: [step1, step2],
        distanceMeters: 1112.0,
        durationSeconds: 120,
        bounds: LatLngBounds(southwest: p0, northeast: p2),
      );

      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p2.latitude,
        endLng: p2.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // Verify currently on step 0 (not final step)
      expect(nav.currentStepIndex, equals(0));

      // Deliver GPS fixes that are geographically within 10m of the final destination p2
      // but while step 0 is active
      final posNearDestination = _createPosition(
        latitude: p2.latitude - 0.00008, // ~8.9m from p2
        longitude: p2.longitude,
        accuracy: 5.0,
      );

      // Send 2 fixes
      await nav.handlePositionForTesting(posNearDestination);
      await nav.handlePositionForTesting(posNearDestination);

      // Should NOT trigger arrival because navigation is not at the final step
      expect(nav.hasArrived, isFalse);
      expect(nav.consecutiveArrivalFixes, equals(0));
      nav.dispose();
    });

    test('9. Itinerary still monitors only today’s unvisited places', () {
      final pYesterday = _createPlace(
        id: 'p_yesterday',
        name: 'Yesterday Place',
        lat: 5.4164,
        lng: 100.3327,
      );
      final pTodayVisited = _createPlace(
        id: 'p_today_visited',
        name: 'Today Visited Place',
        lat: 5.4164,
        lng: 100.3327,
        isVisited: true,
      );
      final pTodayNoCoords = _createPlace(
        id: 'p_today_no_coords',
        name: 'Today No Coords Place',
        lat: null,
        lng: null,
      );
      final pTodayUnvisited = _createPlace(
        id: 'p_today_unvisited',
        name: 'Today Unvisited Place',
        lat: 5.4164,
        lng: 100.3327,
        isVisited: false,
      );
      final pTomorrow = _createPlace(
        id: 'p_tomorrow',
        name: 'Tomorrow Place',
        lat: 5.4164,
        lng: 100.3327,
      );

      final itin = ItineraryModel(
        id: 'multi_day_itin',
        title: 'Multi Day Trip',
        startDate: '2026-09-04',
        totalDays: 3,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04', // Yesterday
            places: [pYesterday],
          ),
          ItineraryDay(
            dayNumber: 2,
            date: '2026-09-05', // Today
            places: [pTodayVisited, pTodayNoCoords, pTodayUnvisited],
          ),
          ItineraryDay(
            dayNumber: 3,
            date: '2026-09-06', // Tomorrow
            places: [pTomorrow],
          ),
        ],
        createdAt: DateTime(2026, 9, 1),
        isOriginCurrentLocation: false,
      );

      final shouldTrack = locService.watchItinerary(itin);

      // Only pTodayUnvisited must be monitored!
      expect(shouldTrack, isTrue);
      expect(locService.watchedPlacesCount, equals(1));
    });

    test(
        '10. Arrival for one place does not increment confirmation count for another place',
        () async {
      // Place A at (5.4164, 100.3327)
      final placeA = _createPlace(
        id: 'place_A',
        name: 'Place A',
        lat: 5.4164,
        lng: 100.3327,
      );
      // Place B at ~100m away (5.4173, 100.3327)
      final placeB = _createPlace(
        id: 'place_B',
        name: 'Place B',
        lat: 5.4173,
        lng: 100.3327,
      );

      final itin = _createItinerary(
        id: 'itin_two_places',
        title: 'Two Places Trip',
        date: fixedDateStr,
        places: [placeA, placeB],
      );
      locService.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(events.add);

      // Fix 1 is near Place A (5m from A, 95m from B)
      final posNearA = _createPosition(
        latitude: 5.4164 + 0.00004,
        longitude: 100.3327,
        accuracy: 5.0,
      );
      locService.simulatePositionChange(posNearA);
      await pumpEventQueue();

      expect(locService.getConsecutiveArrivalFixes('place_A'), equals(1));
      expect(locService.getConsecutiveArrivalFixes('place_B'), equals(0));

      // Fix 2 is near Place B (5m from B, 95m from A)
      final posNearB = _createPosition(
        latitude: 5.4173 + 0.00004,
        longitude: 100.3327,
        accuracy: 5.0,
      );
      locService.simulatePositionChange(posNearB);
      await pumpEventQueue();

      // Place A count was reset because fix 2 was ~95m away from A
      expect(locService.getConsecutiveArrivalFixes('place_A'), equals(0));
      // Place B count is now 1 (not 2!)
      expect(locService.getConsecutiveArrivalFixes('place_B'), equals(1));

      // Neither place triggered arrival!
      expect(events.isEmpty, isTrue);
      expect(locService.isPlaceArrived('place_A'), isFalse);
      expect(locService.isPlaceArrived('place_B'), isFalse);

      await sub.cancel();
    });

    test('11. An already-arrived/visited place does not trigger again',
        () async {
      final place = _createPlace(
        id: 'place_already_arrived',
        name: 'Clock Tower',
        lat: 5.4164,
        lng: 100.3327,
      );
      final itin = _createItinerary(
        id: 'itin_already',
        title: 'Already Arrived Trip',
        date: fixedDateStr,
        places: [place],
      );
      locService.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(events.add);

      final qualifyingPos = _createPosition(
        latitude: 5.4164,
        longitude: 100.3327,
        accuracy: 5.0,
      );

      // Trigger arrival with 2 consecutive fixes
      locService.simulatePositionChange(qualifyingPos);
      locService.simulatePositionChange(qualifyingPos);
      await pumpEventQueue();

      expect(events.length, equals(1));
      expect(locService.isPlaceArrived('place_already_arrived'), isTrue);

      // Send 10 further fixes at the exact coordinate
      for (int i = 0; i < 10; i++) {
        locService.simulatePositionChange(qualifyingPos);
      }
      await pumpEventQueue();

      // No new event was emitted
      expect(events.length, equals(1));
      await sub.cancel();
    });

    test(
        '12. Navigation-confirmed arrival does not cause a duplicate Itinerary arrival dialog after returning',
        () async {
      final place = _createPlace(
        id: 'place_nav_handover',
        name: 'Town Museum',
        lat: 5.4164,
        lng: 100.3327,
      );
      final itin = _createItinerary(
        id: 'itin_handover',
        title: 'Handover Trip',
        date: fixedDateStr,
        places: [place],
      );

      // 1. User starts watching itinerary
      locService.watchItinerary(itin);
      expect(locService.watchedPlacesCount, equals(1));

      final itineraryArrivalEvents = <PlaceArrivalEvent>[];
      final sub = locService.arrivalStream.listen(itineraryArrivalEvents.add);

      // 2. User taps "Start Navigation" -> proximity tracking paused
      locService.pauseItineraryProximity();

      // 3. Navigation runs and arrives at destination
      const start = LatLng(5.4100, 100.3327);
      final end = LatLng(place.lat!, place.lng!);
      final route = _createRoute(points: [start, end]);

      final nav = NavigationController(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // 2 qualifying fixes at destination confirm navigation arrival
      final destPos = _createPosition(
        latitude: end.latitude,
        longitude: end.longitude,
        accuracy: 5.0,
      );
      await nav.handlePositionForTesting(destPos);
      await nav.handlePositionForTesting(destPos);
      expect(nav.hasArrived, isTrue);

      // 4. Navigation completes, returns to Itinerary Detail
      // Itinerary detail marks the place as visited
      final updatedPlace = place.copyWith(
        isVisited: true,
        visitedAt: fixedDate,
      );
      final updatedItin = _createItinerary(
        id: 'itin_handover',
        title: 'Handover Trip',
        date: fixedDateStr,
        places: [updatedPlace],
      );

      // 5. Itinerary tracking refreshes with updated itinerary
      locService.watchItinerary(updatedItin);

      // Place is now visited -> 0 watched places
      expect(locService.watchedPlacesCount, equals(0));

      // 6. User stays at destination coordinate and GPS streams more fixes
      locService.simulatePositionChange(destPos);
      locService.simulatePositionChange(destPos);
      await pumpEventQueue();

      // Zero arrival events emitted by ItineraryDetail proximity detection!
      expect(itineraryArrivalEvents.isEmpty, isTrue);

      nav.dispose();
      await sub.cancel();
    });
  });
}
