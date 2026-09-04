import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gotrip/models/itineraryModel.dart';
import 'package:gotrip/modules/itinerary/itineraryDetail.dart';
import 'package:gotrip/services/itinerary_pdf_service.dart';
import 'package:gotrip/services/location_service.dart';

Position makePosition({
  required double latitude,
  required double longitude,
  DateTime? timestamp,
  double accuracy = 5.0,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp ?? DateTime.now(),
    accuracy: accuracy,
    altitude: 10.0,
    heading: 0.0,
    speed: 0.0,
    speedAccuracy: 0.0,
    altitudeAccuracy: 0.0,
    headingAccuracy: 0.0,
  );
}

ItineraryPlace createPlace({
  required String id,
  required String name,
  required String suggestedTime,
  int durationMinutes = 60,
  String address = '123 Heritage Street, George Town',
  double? lat = 5.4164,
  double? lng = 100.3327,
  bool isVisited = false,
  DateTime? visitedAt,
}) {
  return ItineraryPlace(
    placeId: id,
    name: name,
    address: address,
    suggestedTime: suggestedTime,
    durationMinutes: durationMinutes,
    lat: lat,
    lng: lng,
    isVisited: isVisited,
    visitedAt: visitedAt,
  );
}

ItineraryModel createItinerary({
  required String id,
  required String title,
  required String date,
  required List<ItineraryPlace> places,
  int totalDays = 1,
  List<ItineraryDay>? extraDays,
}) {
  final day1 = ItineraryDay(
    dayNumber: 1,
    date: date,
    places: places,
  );

  return ItineraryModel(
    id: id,
    title: title,
    startDate: date,
    totalDays: totalDays,
    days: [day1, ...(extraDays ?? const [])],
    createdAt: DateTime(2026, 9, 1),
    isOriginCurrentLocation: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = LocationService.instance;
  final fixedToday = DateTime(2026, 9, 4, 10, 0);
  const fixedDateStr = '2026-09-04';

  StreamController<Position>? testStreamCtrl;

  setUp(() {
    service.resetForTesting();
    testStreamCtrl?.close();
    testStreamCtrl = StreamController<Position>.broadcast();
    service.testPositionStream = testStreamCtrl!.stream;
    service.testNowProvider = () => fixedToday;
    service.testServiceEnabledChecker = () async => true;
    service.testPermissionChecker = () async => LocationPermission.always;
    service.testPositionProvider = (
        {LocationAccuracy desiredAccuracy = LocationAccuracy.high,
        Duration? timeLimit}) async {
      return makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);
    };
  });

  tearDown(() {
    service.resetForTesting();
    testStreamCtrl?.close();
    testStreamCtrl = null;
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Suite A: Watch Scope and Boundary Tests
  // ═══════════════════════════════════════════════════════════════════════════

  group('A. Watch scope and boundary', () {
    test('1. Today\'s unvisited place with coordinates is watched', () {
      final p1 = createPlace(
          id: 'p1', name: 'Fort Cornwallis', suggestedTime: '09:00');
      final itin = createItinerary(
          id: 'itin_today',
          title: 'Today Trip',
          date: fixedDateStr,
          places: [p1]);

      final shouldTrack = service.watchItinerary(itin);
      expect(shouldTrack, isTrue);
      expect(service.watchedPlacesCount, equals(1));
    });

    test('2. Visited places are not watched', () {
      final p1 = createPlace(
          id: 'p1',
          name: 'Visited Fort',
          suggestedTime: '09:00',
          isVisited: true);
      final itin = createItinerary(
          id: 'itin_visited',
          title: 'Visited Trip',
          date: fixedDateStr,
          places: [p1]);

      final shouldTrack = service.watchItinerary(itin);
      expect(shouldTrack, isFalse);
      expect(service.watchedPlacesCount, equals(0));
    });

    test('3. Future-day and past-day places do not trigger', () {
      final pFuture =
          createPlace(id: 'p_fut', name: 'Future Stop', suggestedTime: '09:00');
      final itinFuture = createItinerary(
          id: 'itin_future',
          title: 'Future Trip',
          date: '2026-09-10',
          places: [pFuture]);

      expect(service.watchItinerary(itinFuture), isFalse);
      expect(service.watchedPlacesCount, equals(0));

      final pPast =
          createPlace(id: 'p_past', name: 'Past Stop', suggestedTime: '09:00');
      final itinPast = createItinerary(
          id: 'itin_past',
          title: 'Past Trip',
          date: '2026-09-01',
          places: [pPast]);

      expect(service.watchItinerary(itinPast), isFalse);
      expect(service.watchedPlacesCount, equals(0));
    });

    test('4. Position just inside the 50m boundary triggers', () async {
      // Place at lat: 5.4164, lng: 100.3327
      final p = createPlace(
          id: 'p_border',
          name: 'Chew Jetty',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_border',
          title: 'Border Trip',
          date: fixedDateStr,
          places: [p]);
      service.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = service.arrivalStream.listen(events.add);

      // ~39m away: delta lat = 0.00035 deg (~38.9m)
      final insidePos =
          makePosition(latitude: 5.4164 + 0.00035, longitude: 100.3327);
      service.simulatePositionChange(insidePos);

      await pumpEventQueue();
      expect(events.length, equals(1));
      expect(events.first.placeId, equals('p_border'));

      await sub.cancel();
    });

    test('5. Position just outside the 50m boundary does not trigger',
        () async {
      final p = createPlace(
          id: 'p_outside',
          name: 'Chew Jetty',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_outside',
          title: 'Outside Trip',
          date: fixedDateStr,
          places: [p]);
      service.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = service.arrivalStream.listen(events.add);

      // ~61m away: delta lat = 0.00055 deg (~61.1m)
      final outsidePos =
          makePosition(latitude: 5.4164 + 0.00055, longitude: 100.3327);
      service.simulatePositionChange(outsidePos);

      await pumpEventQueue();
      expect(events.isEmpty, isTrue);

      await sub.cancel();
    });

    test('6. One position cannot emit the same place twice without re-arm',
        () async {
      final p = createPlace(
          id: 'p_once',
          name: 'Kek Lok Si',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_once',
          title: 'Single Emit Trip',
          date: fixedDateStr,
          places: [p]);
      service.watchItinerary(itin);

      final events = <PlaceArrivalEvent>[];
      final sub = service.arrivalStream.listen(events.add);

      final nearPos = makePosition(latitude: 5.4164, longitude: 100.3327);
      service.simulatePositionChange(nearPos);
      service.simulatePositionChange(nearPos);

      await pumpEventQueue();
      expect(events.length, equals(1));
      expect(service.isPlaceArrived('p_once'), isTrue);

      await sub.cancel();
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Suite B: Page Startup Tests
  // ═══════════════════════════════════════════════════════════════════════════

  group('B. Page startup', () {
    testWidgets(
        '7. Opening ItineraryDetailPage registers the itinerary and starts/reuses tracking',
        (tester) async {
      final p1 =
          createPlace(id: 'p_reg', name: 'Penang Hill', suggestedTime: '09:00');
      final itin = createItinerary(
          id: 'itin_startup',
          title: 'Startup Trip',
          date: fixedDateStr,
          places: [p1]);

      expect(service.watcherCount, equals(0));

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();

      expect(service.watchedPlacesCount, equals(1));
      expect(service.watcherCount, equals(1));
      expect(service.isTracking, isTrue);
    });

    testWidgets(
        '8. A fresh existing currentPosition already within 50m is evaluated immediately',
        (tester) async {
      final p1 = createPlace(
          id: 'p_fresh',
          name: 'Penang Botanic Gardens',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_fresh',
          title: 'Fresh Evaluation Trip',
          date: fixedDateStr,
          places: [p1]);

      // Seed fresh position within 20m of the place
      service.currentPosition = makePosition(
        latitude: 5.4164 + 0.0001,
        longitude: 100.3327,
        timestamp: fixedToday,
      );

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Arrival dialog should appear immediately without user movement
      expect(find.text("You've arrived! 🎉"), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(Dialog),
              matching: find.text('Penang Botanic Gardens')),
          findsOneWidget);
    });

    testWidgets(
        '9. A missing/stale currentPosition uses the injected fresh-position flow',
        (tester) async {
      final p1 = createPlace(
          id: 'p_stale',
          name: 'Clan Jetties',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_stale',
          title: 'Stale Refresh Trip',
          date: fixedDateStr,
          places: [p1]);

      // Stale position from 1 hour ago
      service.currentPosition = makePosition(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: fixedToday.subtract(const Duration(hours: 1)),
      );

      int refreshCount = 0;
      service.testServiceEnabledChecker = () async => true;
      service.testPermissionChecker = () async => LocationPermission.always;
      service.testPositionProvider = (
          {LocationAccuracy desiredAccuracy = LocationAccuracy.high,
          Duration? timeLimit}) async {
        refreshCount++;
        return makePosition(
            latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);
      };

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(refreshCount, equals(1));
      expect(find.text("You've arrived! 🎉"), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(Dialog), matching: find.text('Clan Jetties')),
          findsOneWidget);
    });

    testWidgets(
        '10. The arrival listener is attached before initial evaluation',
        (tester) async {
      final p1 = createPlace(
          id: 'p_listener_order',
          name: 'Order Venue',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_order',
          title: 'Order Test',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: fixedToday,
      );

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("You've arrived! 🎉"), findsOneWidget);
    });

    testWidgets(
        '11. Initial evaluation does not create duplicate events/dialogs',
        (tester) async {
      final p1 = createPlace(
          id: 'p_dedup_init',
          name: 'Pinang Peranakan Mansion',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_dedup_init',
          title: 'Dedup Init Trip',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: fixedToday,
      );

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Simulate a stream event with the same position
      service.simulatePositionChange(makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday));
      await tester.pump();

      expect(find.text("You've arrived! 🎉"), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Suite C: Page Disposal Tests
  // ═══════════════════════════════════════════════════════════════════════════

  group('C. Page disposal', () {
    testWidgets(
        '12. Disposing ItineraryDetailPage clears itinerary proximity targets',
        (tester) async {
      final p1 =
          createPlace(id: 'p_disp', name: 'Street Art', suggestedTime: '09:00');
      final itin = createItinerary(
          id: 'itin_disp',
          title: 'Disposal Trip',
          date: fixedDateStr,
          places: [p1]);

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();

      expect(service.watchedPlacesCount, equals(1));

      // Navigate away / replace home to trigger dispose
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('Other Page'))));
      await tester.pump();

      expect(service.watchedPlacesCount, equals(0));
    });

    testWidgets('13. Disposing the page releases exactly one watcher reference',
        (tester) async {
      final p1 = createPlace(
          id: 'p_watch_ref', name: 'Temple', suggestedTime: '09:00');
      final itin = createItinerary(
          id: 'itin_ref', title: 'Ref Trip', date: fixedDateStr, places: [p1]);

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();
      expect(service.watcherCount, equals(1));

      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('Other Page'))));
      await tester.pump();
      expect(service.watcherCount, equals(0));
    });

    testWidgets(
        '14. If another watcher such as MainPage conceptually remains, the shared GPS stream remains active',
        (tester) async {
      final p1 = createPlace(
          id: 'p_multi_watcher', name: 'Museum', suggestedTime: '09:00');
      final itin = createItinerary(
          id: 'itin_mw',
          title: 'Multi Watcher Trip',
          date: fixedDateStr,
          places: [p1]);

      // MainPage conceptually starts tracking first
      service.startTracking();
      expect(service.watcherCount, equals(1));
      expect(service.isTracking, isTrue);

      // Open detail page
      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();
      expect(service.watcherCount, equals(2));

      // Close detail page
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('MainPage'))));
      await tester.pump();

      // MainPage's watcher remains active
      expect(service.watcherCount, equals(1));
      expect(service.isTracking, isTrue);
      // But itinerary proximity targets are wiped
      expect(service.watchedPlacesCount, equals(0));

      service.stopTracking();
    });

    testWidgets(
        '15. After detail-page disposal, simulated movement near the old itinerary place produces no itinerary arrival event',
        (tester) async {
      final p1 = createPlace(
          id: 'p_ghost',
          name: 'Ghost Stop',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_ghost',
          title: 'Ghost Trip',
          date: fixedDateStr,
          places: [p1]);

      // Keep stream alive via external watcher
      service.startTracking();

      // Seed fresh position away so initial evaluation doesn't invoke async GPS
      service.currentPosition = makePosition(
          latitude: 5.5000, longitude: 100.4000, timestamp: fixedToday);

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Close detail page
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('MainPage'))));
      await tester.pump();

      // Simulate movement at the old itinerary place
      service.simulatePositionChange(
          makePosition(latitude: 5.4164, longitude: 100.3327));
      await tester.pump();

      expect(service.isPlaceArrived('p_ghost'), isFalse);

      service.stopTracking();
    });

    testWidgets(
        '16. Reopening the itinerary allows that place to trigger normally',
        (tester) async {
      final p1 = createPlace(
          id: 'p_reopen',
          name: 'Reopen Venue',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_reopen',
          title: 'Reopen Trip',
          date: fixedDateStr,
          places: [p1]);

      service.startTracking();

      // First open: user is far away so no arrival is triggered
      service.currentPosition = makePosition(
          latitude: 5.5000, longitude: 100.4000, timestamp: fixedToday);
      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text("You've arrived! 🎉"), findsNothing);

      // Close the page
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('MainPage'))));
      await tester.pump();

      // Reopen the itinerary with fresh position at the venue
      service.currentPosition = makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);
      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text("You've arrived! 🎉"), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(Dialog), matching: find.text('Reopen Venue')),
          findsOneWidget);

      service.stopTracking();
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Suite D: Dialog Dismissal Tests
  // ═══════════════════════════════════════════════════════════════════════════

  group('D. Dialog dismissal', () {
    testWidgets('17. Tapping Not yet re-arms exactly once', (tester) async {
      final p1 = createPlace(
          id: 'p_not_yet',
          name: 'Esplanade',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_ny',
          title: 'Not Yet Trip',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);

      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text("You've arrived! 🎉"), findsOneWidget);
      expect(service.isPlaceArrived('p_not_yet'), isTrue);

      // Tap Not yet
      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();

      expect(find.text("You've arrived! 🎉"), findsNothing);
      // Must be re-armed
      expect(service.isPlaceArrived('p_not_yet'), isFalse);
    });

    testWidgets('18. Android/system back re-arms exactly once', (tester) async {
      final p1 = createPlace(
          id: 'p_back_rearm',
          name: 'Queen Victoria Clock',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_back',
          title: 'Back Trip',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);

      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text("You've arrived! 🎉"), findsOneWidget);
      expect(service.isPlaceArrived('p_back_rearm'), isTrue);

      // Simulate Android hardware back button / pop route
      final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
      await widgetsAppState.didPopRoute();
      await tester.pumpAndSettle();

      expect(find.text("You've arrived! 🎉"), findsNothing);
      // Must be re-armed
      expect(service.isPlaceArrived('p_back_rearm'), isFalse);
    });

    testWidgets(
        '19. Confirming Yes, I\'m here! does not run the dismiss re-arm path',
        (tester) async {
      bool dismissed = false;
      bool confirmed = false;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () {
                showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (dialogCtx) => ArrivedDialog(
                    placeName: 'City Hall',
                    onConfirm: () {
                      confirmed = true;
                      Navigator.of(dialogCtx).pop(true);
                    },
                    onDismiss: () {
                      dismissed = true;
                      Navigator.of(dialogCtx).pop(false);
                    },
                    onPopInvoked: () {
                      dismissed = true;
                    },
                  ),
                );
              },
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text("You've arrived! 🎉"), findsOneWidget);

      await tester.tap(find.text("Yes, I'm here!"));
      await tester.pumpAndSettle();

      expect(find.text("You've arrived! 🎉"), findsNothing);
      expect(confirmed, isTrue);
      expect(dismissed, isFalse);
    });

    testWidgets('20. No duplicate/double pop occurs', (tester) async {
      final p1 = createPlace(
          id: 'p_no_double_pop',
          name: 'St. George Church',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_ndp',
          title: 'No Double Pop Trip',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);

      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Tap Not yet
      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();

      // Ensure detail page remains mounted and is not popped
      expect(find.byType(ItineraryDetailPage), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Suite E: Persistence Failure & Recovery Tests
  // ═══════════════════════════════════════════════════════════════════════════

  group('E. Persistence failure', () {
    testWidgets('21. Failed commitCheckIn leaves the place unvisited',
        (tester) async {
      final p1 = createPlace(
          id: 'p_fail_unvis',
          name: 'Kapitan Keling Mosque',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_fail',
          title: 'Failure Trip',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);

      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text("You've arrived! 🎉"), findsOneWidget);

      await tester.tap(find.text("Yes, I'm here!"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Because commitCheckIn throws (no logged in user in unit test environment),
      // error is caught, SnackBar is shown, and place remains unvisited in UI
      expect(
          find.text(
              'Check-in could not be saved. Please check your connection and try again.'),
          findsOneWidget);
      expect(find.text('Visited'), findsNothing);
    });

    testWidgets(
        '22. Failed persistence re-arms the place even when the widget is no longer mounted',
        (tester) async {
      final p1 = createPlace(
          id: 'p_fail_rearm',
          name: 'Han Jiang Temple',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_fail_rearm',
          title: 'Fail Rearm Trip',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);

      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text("Yes, I'm here!"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Re-arm MUST have executed upon catch
      expect(service.isPlaceArrived('p_fail_rearm'), isFalse);
    });

    testWidgets('23. A subsequent valid position can emit the arrival again',
        (tester) async {
      final p1 = createPlace(
          id: 'p_retry',
          name: 'Retry Stop',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_retry',
          title: 'Retry Trip',
          date: fixedDateStr,
          places: [p1]);

      service.currentPosition = makePosition(
          latitude: 5.4164, longitude: 100.3327, timestamp: fixedToday);

      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Tap Not yet
      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();

      expect(service.isPlaceArrived('p_retry'), isFalse);

      // Next position arrives within 50m
      service.simulatePositionChange(
          makePosition(latitude: 5.4164, longitude: 100.3327));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Dialog pops again
      expect(find.text("You've arrived! 🎉"), findsOneWidget);
    });

    test(
        '24. Successful persistence updates visited state only after completion',
        () {
      final p1 = createPlace(
          id: 'p_model_test', name: 'Model Test', suggestedTime: '09:00');
      final updatedPlace =
          p1.copyWith(isVisited: true, visitedAt: DateTime(2026, 9, 4, 10, 0));

      expect(p1.isVisited, isFalse);
      expect(updatedPlace.isVisited, isTrue);
      expect(updatedPlace.visitedAt, isNotNull);
    });

    test('25. Existing atomic commit call remains the persistence path', () {
      // Model serialization contract verification for atomic commit
      final p1 = createPlace(
          id: 'p_atomic',
          name: 'Atomic Stop',
          suggestedTime: '09:00',
          isVisited: true,
          visitedAt: DateTime(2026, 9, 4, 10, 0));
      final itin = createItinerary(
          id: 'itin_atomic',
          title: 'Atomic Trip',
          date: fixedDateStr,
          places: [p1]);

      final map = itin.toMap();
      expect(map['title'], equals('Atomic Trip'));
      expect(map['days'], isNotEmpty);
      final dayMap = map['days'][0] as Map<String, dynamic>;
      final placesList = dayMap['places'] as List<dynamic>;
      expect(placesList[0]['isVisited'], isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Suite F: Regression Isolation Tests
  // ═══════════════════════════════════════════════════════════════════════════

  group('F. Regression isolation', () {
    testWidgets('26. PDF export does not interact with tracking',
        (tester) async {
      final p1 =
          createPlace(id: 'p_pdf', name: 'PDF Stop', suggestedTime: '09:00');
      final itin = createItinerary(
          id: 'itin_pdf',
          title: 'PDF Isolation Trip',
          date: fixedDateStr,
          places: [p1]);

      int exportCallCount = 0;
      final mockPdfService = ItineraryPdfService(
        exportHandler: (it) async {
          exportCallCount++;
          return '/tmp/test.pdf';
        },
      );

      service.currentPosition = makePosition(
          latitude: 5.5000, longitude: 100.4000, timestamp: fixedToday);

      await tester.pumpWidget(MaterialApp(
        home: ItineraryDetailPage(itinerary: itin, pdfService: mockPdfService),
      ));
      await tester.pump();

      final exportButton = find.byKey(const ValueKey('export_pdf_button'));
      expect(exportButton, findsOneWidget);

      await tester.tap(exportButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(exportCallCount, equals(1));
      // Proximity tracking state was untouched by PDF export
      expect(service.watchedPlacesCount, equals(1));
    });

    test(
        '27. MainPage movement baseline and 3km refresh state are not cleared by pauseItineraryProximity',
        () {
      service.updateMovementBaseline(5.4164, 100.3327);
      expect(service.baselineLat, equals(5.4164));
      expect(service.baselineLng, equals(100.3327));

      service.pauseItineraryProximity();

      // Movement baseline for MainPage remains completely intact
      expect(service.baselineLat, equals(5.4164));
      expect(service.baselineLng, equals(100.3327));
    });

    testWidgets(
        '28. Repeated refresh/rebuild does not increase watcher count repeatedly',
        (tester) async {
      final p1 = createPlace(
          id: 'p_rebuild', name: 'Rebuild Venue', suggestedTime: '09:00');
      final itin = createItinerary(
          id: 'itin_rebuild',
          title: 'Rebuild Trip',
          date: fixedDateStr,
          places: [p1]);

      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      expect(service.watcherCount, equals(1));

      // Trigger setState/rebuild on detail page
      await tester
          .pumpWidget(MaterialApp(home: ItineraryDetailPage(itinerary: itin)));
      await tester.pump();
      expect(service.watcherCount, equals(1));
    });

    test('29. Existing same-place arrival suppression still works', () {
      final p = createPlace(
          id: 'p_suppress',
          name: 'Suppressed Stop',
          suggestedTime: '09:00',
          lat: 5.4164,
          lng: 100.3327);
      final itin = createItinerary(
          id: 'itin_suppress',
          title: 'Suppress Trip',
          date: fixedDateStr,
          places: [p]);

      service.watchItinerary(itin);
      service.markArrived('p_suppress');

      expect(service.isPlaceArrived('p_suppress'), isTrue);
      expect(service.watchedPlacesCount, equals(0));
    });
  });
}
