import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gotrip/services/navigate_service.dart';
import 'package:gotrip/services/route_service.dart';

Position createTestPosition({
  required double latitude,
  required double longitude,
  double speed = 10.0,
  double accuracy = 5.0,
  double heading = 0.0,
  DateTime? timestamp,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp ?? DateTime.now(),
    accuracy: accuracy,
    altitude: 10.0,
    heading: heading,
    speed: speed,
    speedAccuracy: 1.0,
    altitudeAccuracy: 1.0,
    headingAccuracy: 1.0,
  );
}

RouteResult createShortMultiStepRoute() {
  // 4 segments of ~22.2 meters each (total ~88.8m)
  // Step 0: (5.0000, 100.0) -> (5.0002, 100.0) ~22.2m
  // Step 1: (5.0002, 100.0) -> (5.0004, 100.0) ~22.2m
  // Step 2: (5.0004, 100.0) -> (5.0006, 100.0) ~22.2m
  // Step 3: (5.0006, 100.0) -> (5.0008, 100.0) ~22.2m (destination)
  final pts = [
    const LatLng(5.0000, 100.0),
    const LatLng(5.0002, 100.0),
    const LatLng(5.0004, 100.0),
    const LatLng(5.0006, 100.0),
    const LatLng(5.0008, 100.0),
  ];
  return RouteResult(
    polylinePoints: pts,
    steps: [
      NavStep(
        instruction: 'Head North on Segment 1',
        maneuver: 'straight',
        distanceMeters: 22.2,
        durationSeconds: 10,
        startLocation: pts[0],
        endLocation: pts[1],
        polylinePoints: [pts[0], pts[1]],
      ),
      NavStep(
        instruction: 'Continue on Segment 2',
        maneuver: 'straight',
        distanceMeters: 22.2,
        durationSeconds: 10,
        startLocation: pts[1],
        endLocation: pts[2],
        polylinePoints: [pts[1], pts[2]],
      ),
      NavStep(
        instruction: 'Continue on Segment 3',
        maneuver: 'straight',
        distanceMeters: 22.2,
        durationSeconds: 10,
        startLocation: pts[2],
        endLocation: pts[3],
        polylinePoints: [pts[2], pts[3]],
      ),
      NavStep(
        instruction: 'Arrive at destination',
        maneuver: 'straight',
        distanceMeters: 22.2,
        durationSeconds: 10,
        startLocation: pts[3],
        endLocation: pts[4],
        polylinePoints: [pts[3], pts[4]],
      ),
    ],
    distanceMeters: 88.8,
    durationSeconds: 40,
    bounds: LatLngBounds(
      southwest: pts.first,
      northeast: pts.last,
    ),
  );
}

Future<RouteResult> mockRouteFetcher({
  required double fromLat,
  required double fromLng,
  required double toLat,
  required double toLng,
  required TravelMode mode,
}) async {
  return createShortMultiStepRoute();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const ttsChannel = MethodChannel('flutter_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
  });

  tearDownAll(() {
    const ttsChannel = MethodChannel('flutter_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
  });

  group('GPS Navigation Startup Dead-Zone Fix Production Suite', () {
    // ── Test 1 ──
    test(
        '1. Pre-stream watchdog polls continuously when stream is silent (>4 attempts, does not terminate at 4)',
        () async {
      int fallbackCalls = 0;
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          fallbackCalls++;
          return createTestPosition(
            latitude: 5.00005,
            longitude: 100.0,
            timestamp: simulatedNow,
          );
        },
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      // Simulate 6 successive periodic watchdog evaluations, advancing simulatedNow by 2 seconds each time
      for (int i = 0; i < 6; i++) {
        simulatedNow = simulatedNow.add(const Duration(seconds: 2));
        await nav.checkGpsHealthAndFallback();
      }

      // In the old implementation, attempts stopped strictly at 4.
      // Now it must poll continuously (> 4 attempts, here 1 at init + 6 watchdog ticks = 7)
      expect(fallbackCalls, greaterThanOrEqualTo(6));
      expect(nav.lastGpsStreamEventAt, isNull);
      expect(nav.lastNavigationFixAt, isNotNull);

      nav.dispose();
    });

    // ── Test 2 ──
    test(
        '2. Usable seed position immediately establishes navigation fix and route progress without waiting for stream',
        () async {
      final simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      final seedTime = simulatedNow.subtract(const Duration(seconds: 2));

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          return createTestPosition(
            latitude: 5.0001,
            longitude: 100.0,
            timestamp: seedTime,
          );
        },
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      // Seed should have established fix immediately
      expect(nav.lastNavigationFixAt, equals(simulatedNow));
      expect(nav.lastGpsStreamEventAt, isNull);
      expect(nav.debugGpsAgeSeconds, equals(double.infinity));
      expect(nav.debugNavigationFixAgeSeconds, equals(0.0));
      // State should be active (not stuck at WAIT GPS)
      expect(nav.debugTrackingState, isIn(['MATCH', 'MATCH~', 'SEED FIX']));
      expect(nav.matchedDistAlongRoute, greaterThan(0.0));

      nav.dispose();
    });

    // ── Test 3 ──
    test('3. Stale seed (>15s) is rejected and not used for immediate fix',
        () async {
      final simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      final staleSeedTime = simulatedNow.subtract(const Duration(seconds: 20));

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          return createTestPosition(
            latitude: 5.0001,
            longitude: 100.0,
            timestamp: staleSeedTime,
          );
        },
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      // Stale seed rejected for immediate fix
      expect(nav.lastGpsStreamEventAt, isNull);
      expect(nav.debugTrackingState, equals('WAIT GPS'));

      nav.dispose();
    });

    // ── Test 4 ──
    test('4. Fallback positions maintain recovery and tracking state',
        () async {
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          return createTestPosition(
            latitude: 5.0001,
            longitude: 100.0,
            timestamp: simulatedNow,
          );
        },
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      simulatedNow = simulatedNow.add(const Duration(seconds: 2));
      await nav.performFallbackLocation('pre_stream');

      expect(nav.debugNavigationFixAgeSeconds, equals(0.0));
      expect(nav.debugGpsAgeSeconds, equals(double.infinity));
      expect(nav.debugTrackingState, isIn(['MATCH', 'MATCH~', 'START FIX']));
      expect(nav.debugRecoverySeconds, lessThanOrEqualTo(30.0));

      nav.dispose();
    });

    // ── Test 5 ──
    test(
        '5. Genuine stream event immediately cancels/suppresses fallback dependence and updates _lastGpsStreamEventAt',
        () async {
      int fallbackCalls = 0;
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      final streamController = StreamController<Position>.broadcast();

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          fallbackCalls++;
          return createTestPosition(
            latitude: 5.00005,
            longitude: 100.0,
            timestamp: simulatedNow,
          );
        },
        positionStreamProvider: ({locationSettings}) => streamController.stream,
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());
      final preStreamFallbacks = fallbackCalls;

      // Stream delivers genuine fix
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 500));
      streamController.add(createTestPosition(
        latitude: 5.0001,
        longitude: 100.0,
        timestamp: simulatedNow,
      ));
      await pumpEventQueue();

      expect(nav.lastGpsStreamEventAt, equals(simulatedNow));
      expect(nav.debugGpsAgeSeconds, equals(0.0));

      // Watchdog ticks at +500ms after stream event (streamAge = 500ms < 2200ms)
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 500));
      await nav.checkGpsHealthAndFallback();

      // No new fallback calls should have been made
      expect(fallbackCalls, equals(preStreamFallbacks));

      nav.dispose();
      await streamController.close();
    });

    // ── Test 6 ──
    test(
        '6. Late-arriving fallback after stream event does not overwrite newer stream data',
        () async {
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      final fallbackCompleter = Completer<Position>();
      final route = createShortMultiStepRoute();

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: route,
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) =>
            fallbackCompleter.future,
      );
      nav.testClock = () => simulatedNow;
      await nav.applyRouteResult(route);

      // Start fallback at T=0
      final fallbackFuture = nav.performFallbackLocation('pre_stream');
      expect(nav.isFallbackInFlight, isTrue);

      // Stream arrives at T=500ms with stream location (5.0002, 100.0)
      final streamTime = simulatedNow.add(const Duration(milliseconds: 500));
      final streamPos = createTestPosition(
        latitude: 5.0002,
        longitude: 100.0,
        timestamp: streamTime,
      );
      await nav.simulateProductionGpsStreamEvent(streamPos,
          eventTime: streamTime);

      expect(nav.lastGpsStreamEventAt, equals(streamTime));
      final streamProgress = nav.matchedDistAlongRoute;

      // Late fallback finally completes at T=1000ms with old location (5.00005, 100.0)
      simulatedNow = simulatedNow.add(const Duration(seconds: 1));
      fallbackCompleter.complete(createTestPosition(
        latitude: 5.00005,
        longitude: 100.0,
        timestamp: simulatedNow,
      ));
      await fallbackFuture;

      expect(nav.isFallbackInFlight, isFalse);
      // Progress must not have been corrupted or overwritten backwards by late fallback
      expect(nav.matchedDistAlongRoute, equals(streamProgress));
      expect(nav.lastGpsStreamEventAt, equals(streamTime));

      nav.dispose();
    });

    // ── Test 7 ──
    test('7. Stream stall (>2.2s) re-engages fallback polling with cooldown',
        () async {
      int fallbackCalls = 0;
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      final route = createShortMultiStepRoute();

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: route,
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          fallbackCalls++;
          return createTestPosition(
            latitude: 5.0002,
            longitude: 100.0,
            timestamp: simulatedNow,
          );
        },
      );
      nav.testClock = () => simulatedNow;
      await nav.applyRouteResult(route);

      // Stream fix at T=0
      await nav.simulateProductionGpsStreamEvent(
        createTestPosition(
          latitude: 5.0001,
          longitude: 100.0,
          timestamp: simulatedNow,
        ),
        eventTime: simulatedNow,
      );

      // At T=1.5s (streamAge = 1.5s < 2.2s)
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 1500));
      await nav.checkGpsHealthAndFallback();
      expect(fallbackCalls, equals(0));

      // At T=2.5s (streamAge = 2.5s >= 2.2s), fallback engages!
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 1000));
      await nav.checkGpsHealthAndFallback();
      expect(fallbackCalls, equals(1));

      // At T=3.0s (500ms since last fallback < 1400ms cooldown), throttled!
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 500));
      await nav.checkGpsHealthAndFallback();
      expect(fallbackCalls, equals(1));

      // At T=4.1s (1600ms since last fallback >= 1400ms cooldown), engages!
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 1100));
      await nav.checkGpsHealthAndFallback();
      expect(fallbackCalls, equals(2));

      nav.dispose();
    });

    // ── Test 8 ──
    test(
        '8. Stream silence (>5s) triggers stream restart without resetting route or monotonic progress',
        () async {
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      int streamSubscribedCount = 0;
      final streamCtrl = StreamController<Position>.broadcast();
      final route = createShortMultiStepRoute();

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: route,
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async =>
            createTestPosition(
          latitude: 5.0001,
          longitude: 100.0,
          timestamp: simulatedNow,
        ),
        positionStreamProvider: ({locationSettings}) {
          streamSubscribedCount++;
          return streamCtrl.stream;
        },
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());
      expect(streamSubscribedCount, equals(1));

      // Advance progress via fallback
      simulatedNow = simulatedNow.add(const Duration(seconds: 2));
      await nav.performFallbackLocation('pre_stream');
      final progressBeforeRestart = nav.matchedDistAlongRoute;
      final stepBeforeRestart = nav.currentStepIndex;
      expect(progressBeforeRestart, greaterThan(0.0));

      // Simulate stream event at T=2s
      await nav.simulateProductionGpsStreamEvent(
        createTestPosition(
          latitude: 5.0002,
          longitude: 100.0,
          timestamp: simulatedNow,
        ),
        eventTime: simulatedNow,
      );
      final streamProgress = nav.matchedDistAlongRoute;

      // Now stream falls silent for 6s (streamAge = 6s >= 5s)
      simulatedNow = simulatedNow.add(const Duration(seconds: 6));
      await nav.checkGpsHealthAndFallback();

      // Small async wait for delayed stream subscription restart
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(streamSubscribedCount, equals(2));
      // Route progress and step index MUST be preserved (not reset)
      expect(nav.matchedDistAlongRoute, equals(streamProgress));
      expect(nav.currentStepIndex, greaterThanOrEqualTo(stepBeforeRestart));

      nav.dispose();
      await streamCtrl.close();
    });

    // ── Test 9 ──
    test(
        '9. Timestamp separation: debugGpsAgeSeconds remains infinite/large during fallback-only phase while debugNavigationFixAgeSeconds is small',
        () async {
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async =>
            createTestPosition(
          latitude: 5.0001,
          longitude: 100.0,
          timestamp: simulatedNow,
        ),
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      // Advance clock by 3s
      simulatedNow = simulatedNow.add(const Duration(seconds: 3));
      await nav.performFallbackLocation('pre_stream');

      // debugGpsAgeSeconds MUST be infinite (stream has never fired)
      expect(nav.debugGpsAgeSeconds, equals(double.infinity));
      // debugNavigationFixAgeSeconds MUST be 0.0 (fresh fallback fix)
      expect(nav.debugNavigationFixAgeSeconds, equals(0.0));

      nav.dispose();
    });

    // ── Test 10 ──
    test(
        '10. Single in-flight fallback constraint: concurrent triggers do not spawn overlapping getCurrentPosition calls',
        () async {
      final simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      int currentPositionCallCount = 0;
      final completer = Completer<Position>();

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) {
          currentPositionCallCount++;
          return completer.future;
        },
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      // Trigger fallback #1
      final future1 = nav.performFallbackLocation('pre_stream');
      expect(nav.isFallbackInFlight, isTrue);
      expect(currentPositionCallCount, equals(1));

      // Trigger fallback #2 concurrently while #1 is in flight
      final future2 = nav.performFallbackLocation('pre_stream');
      expect(currentPositionCallCount, equals(1)); // Still strictly 1!

      // Complete
      completer.complete(createTestPosition(
        latitude: 5.0001,
        longitude: 100.0,
        timestamp: simulatedNow,
      ));
      await future1;
      await future2;

      expect(nav.isFallbackInFlight, isFalse);
      expect(currentPositionCallCount, equals(1));

      nav.dispose();
    });

    // ── Test 11 ──
    test('11. Fallback cooldown enforcement: calls within 1400ms are throttled',
        () async {
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      int callCount = 0;

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          callCount++;
          return createTestPosition(
            latitude: 5.0001,
            longitude: 100.0,
            timestamp: simulatedNow,
          );
        },
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      // Call 1 at T=0ms
      await nav.performFallbackLocation('pre_stream');
      expect(callCount, equals(1));

      // Call 2 at T=800ms (diff = 800ms < 1400ms) -> throttled
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 800));
      await nav.performFallbackLocation('pre_stream');
      expect(callCount, equals(1));

      // Call 3 at T=1500ms (diff from Call 1 = 1500ms >= 1400ms) -> executed
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 700));
      await nav.performFallbackLocation('pre_stream');
      expect(callCount, equals(2));

      nav.dispose();
    });

    // ── Test 12 ──
    test(
        '12. Dispose cancels all timers and subscriptions; in-flight fallback cannot update state after dispose',
        () async {
      final simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);
      final completer = Completer<Position>();

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) => completer.future,
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      final future = nav.performFallbackLocation('pre_stream');
      expect(nav.isFallbackInFlight, isTrue);

      nav.dispose();
      expect(nav.isDisposed, isTrue);

      // Completing the fallback post-dispose should be safely ignored
      completer.complete(createTestPosition(
        latitude: 5.0005,
        longitude: 100.0,
        timestamp: simulatedNow,
      ));
      await future;

      expect(nav.lastNavigationFixAt, isNull);
    });

    // ── Test 13 ──
    test('13. Arrival stops fallback and watchdog activity', () async {
      int fallbackCalls = 0;
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async {
          fallbackCalls++;
          return createTestPosition(
            latitude: 5.00005,
            longitude: 100.0,
            timestamp: simulatedNow,
          );
        },
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      // Progressively advance through steps 0, 1, 2, 3 to arrive safely within jump limits
      final advancePoints = [
        const LatLng(5.0002, 100.0), // Step 1
        const LatLng(5.0004, 100.0), // Step 2
        const LatLng(5.0006, 100.0), // Step 3 (last step)
        const LatLng(5.0008, 100.0), // Destination
      ];

      for (final pt in advancePoints) {
        simulatedNow = simulatedNow.add(const Duration(seconds: 1));
        await nav.handlePositionForTesting(createTestPosition(
          latitude: pt.latitude,
          longitude: pt.longitude,
          accuracy: 5.0,
          timestamp: simulatedNow,
        ));
      }

      // Second consecutive qualifying fix at destination
      simulatedNow = simulatedNow.add(const Duration(seconds: 1));
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.0008,
        longitude: 100.0,
        accuracy: 5.0,
        timestamp: simulatedNow,
      ));

      expect(nav.hasArrived, isTrue);
      final callsAtArrival = fallbackCalls;

      // Watchdog tick post-arrival must not trigger any fallback
      simulatedNow = simulatedNow.add(const Duration(seconds: 2));
      await nav.checkGpsHealthAndFallback();
      expect(fallbackCalls, equals(callsAtArrival));

      nav.dispose();
    });

    // ── Test 14 ──
    test(
        '14. Handover from fallback to stream preserves monotonic progress (no backward jump)',
        () async {
      DateTime simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async =>
            createTestPosition(
          latitude: 5.0002, // ~22.2m along route
          longitude: 100.0,
          timestamp: simulatedNow,
        ),
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      // Fallback establishes progress
      simulatedNow = simulatedNow.add(const Duration(seconds: 2));
      await nav.performFallbackLocation('pre_stream');
      final fallbackProgress = nav.matchedDistAlongRoute;
      expect(fallbackProgress, greaterThan(20.0));

      // Stream delivers an event slightly behind (e.g. at ~15m)
      simulatedNow = simulatedNow.add(const Duration(milliseconds: 500));
      await nav.simulateProductionGpsStreamEvent(
        createTestPosition(
          latitude: 5.00015, // ~16.6m along route
          longitude: 100.0,
          timestamp: simulatedNow,
        ),
        eventTime: simulatedNow,
      );

      // Monotonicity check: progress must NEVER jump backward
      expect(nav.matchedDistAlongRoute, greaterThanOrEqualTo(fallbackProgress));
      expect(nav.lastGpsStreamEventAt, equals(simulatedNow));

      nav.dispose();
    });

    // ── Test 15 ──
    test(
        '15. Seed/fallback fix with polyline points correctly advances step and updates remaining distance/duration',
        () async {
      final simulatedNow = DateTime(2026, 9, 1, 10, 0, 0);

      final nav = NavigationController(
        startLat: 5.0000,
        startLng: 100.0,
        endLat: 5.0008,
        endLng: 100.0,
        initialRoute: createShortMultiStepRoute(),
        routeFetcher: mockRouteFetcher,
        currentPositionProvider: ({desiredAccuracy}) async =>
            createTestPosition(
          latitude: 5.00025, // Into step 1 (~27m along route)
          longitude: 100.0,
          timestamp: simulatedNow,
        ),
        positionStreamProvider: ({locationSettings}) =>
            const Stream<Position>.empty(),
      );
      nav.testClock = () => simulatedNow;

      await nav.init(const TestVSync());

      // Verify that step and distance updated from seed fix
      expect(nav.currentStepIndex, greaterThanOrEqualTo(1));
      expect(nav.remainingMeters, lessThan(88.8));
      expect(nav.remainingSeconds, lessThan(40));

      nav.dispose();
    });
  });
}
