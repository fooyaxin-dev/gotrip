import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gotrip/services/navigate_service.dart';
import 'package:gotrip/services/route_service.dart';

Position createTestPosition({
  required double latitude,
  required double longitude,
  double speed = 14.0, // ~50 km/h
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

RouteResult createTestRoute({
  required List<LatLng> points,
  List<NavStep>? steps,
  double? distanceMeters,
  int durationSeconds = 600,
}) {
  double calculatedDist = 0.0;
  for (int i = 0; i < points.length - 1; i++) {
    calculatedDist += Geolocator.distanceBetween(
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
            instruction: 'Head North',
            maneuver: 'straight',
            distanceMeters: distanceMeters ?? calculatedDist,
            durationSeconds: durationSeconds,
            startLocation: points.first,
            endLocation: points.last,
            polylinePoints: points,
          ),
        ],
    distanceMeters: distanceMeters ?? calculatedDist,
    durationSeconds: durationSeconds,
    bounds: LatLngBounds(
      southwest: points.first,
      northeast: points.last,
    ),
  );
}

/// Progressively advances navigation controller in small plausible increments
/// so each step falls well within maxAllowableJump (< 45m).
Future<void> advanceToProgress(
  NavigationController nav, {
  required double startLat,
  required double endLat,
  required double lng,
  int count = 10,
  double speed = 14.0,
}) async {
  for (int i = 1; i <= count; i++) {
    final lat = startLat + (endLat - startLat) * (i / count);
    await nav.handlePositionForTesting(createTestPosition(
      latitude: lat,
      longitude: lng,
      speed: speed,
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Route: straight line North for ~2000m
  // 5.0000 to 5.0180 at 100.0000 (~2003 meters)
  const p0 = LatLng(5.0000, 100.0000);
  const p1 = LatLng(5.0050, 100.0000); // ~556m
  const p2 = LatLng(5.0100, 100.0000); // ~1112m
  const p3 = LatLng(5.0180, 100.0000); // ~2003m
  const polyline = [p0, p1, p2, p3];

  const step1 = NavStep(
    instruction: 'Continue on Jalan Utama',
    maneuver: 'straight',
    distanceMeters: 556.0,
    durationSeconds: 120,
    startLocation: p0,
    endLocation: p1,
    polylinePoints: [p0, p1],
  );

  const step2 = NavStep(
    instruction: 'Turn right at junction',
    maneuver: 'turn-right',
    distanceMeters: 1447.0,
    durationSeconds: 300,
    startLocation: p1,
    endLocation: p3,
    polylinePoints: [p1, p2, p3],
  );

  group('GPS Navigation Visual Progress & Monotonicity Production Tests', () {
    test('1. Same-route accepted Progress never decreases', () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      double lastProgress = nav.debugMatchedProgress;

      // Feed series of plausible fixes advancing forward with backward jitter
      final testCoords = [
        const LatLng(5.0003, 100.0000), // ~33m
        const LatLng(5.0006, 100.0000), // ~67m
        const LatLng(5.0005, 100.0000), // jitter backward ~55m
        const LatLng(5.0009, 100.0000), // forward ~100m
        const LatLng(5.0008, 100.0001), // jitter backward & sideways
        const LatLng(5.0012, 100.0000), // forward ~133m
      ];

      for (final coord in testCoords) {
        await nav.handlePositionForTesting(createTestPosition(
          latitude: coord.latitude,
          longitude: coord.longitude,
        ));
        expect(nav.debugMatchedProgress, greaterThanOrEqualTo(lastProgress),
            reason: 'Accepted progress must be monotonically non-decreasing');
        lastProgress = nav.debugMatchedProgress;
      }
    });

    test('2. Same-route Visual never decreases during normal forward travel',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.0015, lng: 100.0000, count: 5);

      double lastVisual = nav.displayDistAlongRoute;

      // Simulate 50 frames of ticker updates across 2 seconds
      for (int i = 1; i <= 50; i++) {
        nav.onTickForTesting(Duration(milliseconds: i * 40));
        expect(nav.displayDistAlongRoute, greaterThanOrEqualTo(lastVisual),
            reason: 'Visual progress must never decrease on frame tick $i');
        lastVisual = nav.displayDistAlongRoute;
      }
    });

    test(
        '3. Reproduce Case A: Progress fixed at 308.5m, dead-reckoning collapses, Visual does not move backward',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // Advance smoothly to ~308.5m (lat 5.00277)
      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.00277, lng: 100.0000, count: 10);
      nav.setDisplayDistForTesting(nav.debugMatchedProgress);

      expect(nav.debugMatchedProgress, closeTo(308.5, 5.0));

      // Let dead-reckoning advance Visual ahead during GPS silence
      for (int i = 1; i <= 30; i++) {
        nav.onTickForTesting(Duration(milliseconds: i * 50));
      }

      final visualBeforeFix = nav.displayDistAlongRoute;
      expect(visualBeforeFix, greaterThan(nav.debugMatchedProgress),
          reason:
              'Dead reckoning should have advanced Visual ahead of Progress');

      // New GPS fix arrives at the SAME progress point (308.5m)
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.00277,
        longitude: 100.0000,
        speed: 13.0,
      ));

      // Run multiple subsequent animation ticks after the fix
      for (int i = 31; i <= 60; i++) {
        nav.onTickForTesting(Duration(milliseconds: i * 50));
        expect(nav.displayDistAlongRoute, greaterThanOrEqualTo(visualBeforeFix),
            reason:
                'Visual must HOLD its position and NOT regress when fix collapses prediction lead');
      }

      // Assert forward lead is strictly bounded to evidence-based limit (<= 4.0m)
      expect(nav.displayDistAlongRoute - nav.debugMatchedProgress,
          lessThanOrEqualTo(4.0));
    });

    test(
        '4. Reproduce stop case (Case E): speed drops to 0, prediction becomes 0, Visual does not move backward or remain materially ahead',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // Advance to ~1397m (approx lat 5.01256) in 35 steps
      await advanceToProgress(nav,
          startLat: 5.0000,
          endLat: 5.01256,
          lng: 100.0000,
          count: 35,
          speed: 16.1);
      nav.setDisplayDistForTesting(nav.debugMatchedProgress);

      expect(nav.debugMatchedProgress, closeTo(1397.0, 10.0));

      // Run dead reckoning ticks
      for (int i = 1; i <= 25; i++) {
        nav.onTickForTesting(Duration(milliseconds: i * 50));
      }

      final visualPeak = nav.displayDistAlongRoute;
      expect(visualPeak, greaterThan(nav.debugMatchedProgress));

      // Vehicle comes to a complete halt: speed = 0.0
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.01256,
        longitude: 100.0000,
        speed: 0.0,
      ));

      // Subsequent ticks with speed = 0
      for (int i = 26; i <= 50; i++) {
        nav.onTickForTesting(Duration(milliseconds: i * 50));
        expect(nav.displayDistAlongRoute, greaterThanOrEqualTo(visualPeak),
            reason: 'Visual must not roll backward when vehicle stops');
      }

      // Assert Visual does NOT remain materially ahead of accepted fresh GPS
      final finalLead = nav.displayDistAlongRoute - nav.debugMatchedProgress;
      expect(finalLead, lessThanOrEqualTo(4.0),
          reason:
              'Stopped vehicle must settle within small evidence-based forward allowance (<= 4m), not stale 25m ahead');
    });

    test(
        '5. Single derived-speed spike does not produce implausible speed jump or massive prediction overshoot',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // Normal movement fix at 50 km/h (13.8 m/s)
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.0003,
        longitude: 100.0000,
        speed: 13.8, // 50 km/h
      ));

      // Now inject short-interval fix with 9m jitter (previously caused derivedSpeed = 45 m/s = 162 km/h)
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.00038, // ~9m jump
        longitude: 100.0000,
        speed: 0.0, // device reported speed 0
      ));

      // Speed change must be rate-limited by realistic physical acceleration (~4.5 m/s^2 * dt)
      // From 13.8 m/s (50 km/h), speed should not spike to 162 km/h or even jump wildly
      expect(nav.debugSpeedKmh, lessThanOrEqualTo(65.0),
          reason:
              'Realistic acceleration bounds prevent derived speed spike from inflating speed');

      // Ticker prediction lead must be conservative (<= 4.0m, well below previous 25m/50m)
      nav.onTickForTesting(const Duration(milliseconds: 100));
      expect(nav.debugPredictionLeadMeters, lessThanOrEqualTo(4.0),
          reason:
              'Prediction lead must be strictly capped at evidence-based bound (<= 4.0m)');
    });

    test(
        '5B. First-sample speed spike from zero speed is rate-limited and does not inflate prediction lead',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // First sample when stopped at origin (debugSpeedMps == 0.0)
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.0000,
        longitude: 100.0000,
        speed: 0.0,
      ));
      expect(nav.debugSpeedMps, equals(0.0));

      // Now inject single abnormal speed spike fix with speed = 35.0 m/s (126 km/h)
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.0001,
        longitude: 100.0000,
        speed: 35.0,
      ));

      // Must NOT immediately jump from 0 to mode ceiling 35 m/s (126 km/h).
      // Bounded by acceleration: ~4.5 m/s^2 * dtFix <= 5.0 m/s (~18 km/h).
      expect(nav.debugSpeedMps, lessThanOrEqualTo(5.0),
          reason:
              'First sample acceleration from zero must be rate-limited, not jumping to mode ceiling');

      nav.onTickForTesting(const Duration(milliseconds: 100));
      expect(nav.debugPredictionLeadMeters, lessThanOrEqualTo(4.0),
          reason: 'Prediction lead must remain bounded (<= 4.0m)');

      // When next sample arrives back at speed = 0, speed returns cleanly towards 0
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.0001,
        longitude: 100.0000,
        speed: 0.0,
      ));
      expect(nav.debugSpeedMps, equals(0.0));
    });

    test(
        '6. Repeated MATCH/HOLD cycles do not cause forward-backward oscillation',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.0010, lng: 100.0000, count: 4);

      double minObservedVisual = nav.displayDistAlongRoute;

      // Alternate between valid fix and noisy fix (HOLD)
      for (int cycle = 1; cycle <= 8; cycle++) {
        // MATCH fix
        await nav.handlePositionForTesting(createTestPosition(
          latitude: 5.0010 + (cycle * 0.0002),
          longitude: 100.0000,
          speed: 10.0,
          accuracy: 5.0,
        ));
        nav.onTickForTesting(Duration(milliseconds: cycle * 200));
        expect(
            nav.displayDistAlongRoute, greaterThanOrEqualTo(minObservedVisual));
        minObservedVisual = nav.displayDistAlongRoute;

        // HOLD fix: large perpendicular gap (off-road noise)
        await nav.handlePositionForTesting(createTestPosition(
          latitude: 5.0010 + (cycle * 0.0002),
          longitude: 100.0020, // 220m off route -> HOLD
          speed: 10.0,
          accuracy: 10.0,
        ));
        nav.onTickForTesting(Duration(milliseconds: cycle * 200 + 100));
        expect(
            nav.displayDistAlongRoute, greaterThanOrEqualTo(minObservedVisual),
            reason: 'HOLD state must not pull Visual backward');
        minObservedVisual = nav.displayDistAlongRoute;
      }
    });

    test('7. Stale or inaccurate fixes do not pull Visual backward', () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.0012, lng: 100.0000, count: 4);
      nav.onTickForTesting(const Duration(milliseconds: 100));

      final visualCheckpoint = nav.displayDistAlongRoute;

      // Inaccurate fix (accuracy = 80m > 60m threshold)
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.0010,
        longitude: 100.0000,
        accuracy: 80.0,
      ));
      nav.onTickForTesting(const Duration(milliseconds: 200));
      expect(nav.displayDistAlongRoute, greaterThanOrEqualTo(visualCheckpoint));

      // Stale fix (timestamp 30 seconds in the past)
      await nav.handlePositionForTesting(createTestPosition(
        latitude: 5.0005,
        longitude: 100.0000,
        timestamp: DateTime.now().subtract(const Duration(seconds: 30)),
      ));
      nav.onTickForTesting(const Duration(milliseconds: 300));
      expect(nav.displayDistAlongRoute, greaterThanOrEqualTo(visualCheckpoint));
    });

    test('8. Marker production position follows non-regressing Visual progress',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.0010, lng: 100.0000, count: 4);

      double lastMarkerLat = nav.positionNotifier.value?.latitude ?? 0.0;

      for (int i = 1; i <= 20; i++) {
        nav.onTickForTesting(Duration(milliseconds: i * 50));
        final currentMarker = nav.positionNotifier.value;
        expect(currentMarker, isNotNull);
        expect(currentMarker!.latitude, greaterThanOrEqualTo(lastMarkerLat),
            reason:
                'Vehicle marker latitude must not decrease along North route');
        lastMarkerLat = currentMarker.latitude;
      }
    });

    test(
        '9. Camera target coordinates follow the same non-regressing positionNotifier stream (controller/structural coverage)',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.0010, lng: 100.0000, count: 4);

      double lastTargetLat = nav.positionNotifier.value?.latitude ?? 0.0;

      for (int i = 1; i <= 15; i++) {
        nav.onTickForTesting(Duration(milliseconds: i * 50));
        final camTarget = nav.displayLatLng;
        expect(camTarget, isNotNull);
        expect(camTarget, equals(nav.positionNotifier.value));
        expect(camTarget!.latitude, greaterThanOrEqualTo(lastTargetLat),
            reason:
                'Camera target stream latitude must not decrease along North route');
        expect(nav.cameraBearing, inInclusiveRange(0.0, 360.0));
        lastTargetLat = camTarget.latitude;
      }
    });

    test('10. Segment and Step remain monotonic on the same route', () async {
      final route = createTestRoute(
        points: polyline,
        steps: [step1, step2],
      );
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      int lastSegment = nav.debugNearestSegment;
      int lastStep = nav.debugCurrentStepIndex;

      // Advance progressively across Step 1 (~556m) into Step 2
      for (int i = 1; i <= 20; i++) {
        final lat = 5.0000 + (0.0080 * (i / 20));
        await nav.handlePositionForTesting(createTestPosition(
          latitude: lat,
          longitude: 100.0000,
        ));
        expect(nav.debugNearestSegment, greaterThanOrEqualTo(lastSegment));
        expect(nav.debugCurrentStepIndex, greaterThanOrEqualTo(lastStep));
        lastSegment = nav.debugNearestSegment;
        lastStep = nav.debugCurrentStepIndex;
      }
    });

    test(
        '11. Legitimate next-maneuver distance reset still works when step advances',
        () async {
      final route = createTestRoute(
        points: polyline,
        steps: [step1, step2],
      );
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      // Advance right near the end of Step 1 (~556m, approx lat 5.0049)
      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.0048, lng: 100.0000, count: 15);

      final distBeforeTransition = nav.distToTurnEnd;
      expect(distBeforeTransition, lessThan(60.0));
      expect(nav.debugCurrentStepIndex, equals(0));

      // Cross boundary into Step 2 in plausible increments (<45m per fix)
      await advanceToProgress(nav,
          startLat: 5.0048, endLat: 5.0056, lng: 100.0000, count: 4);
      expect(nav.debugCurrentStepIndex, equals(1));
      // distToTurnEnd now represents distance to end of Step 2 (which is > 1000m)
      expect(nav.distToTurnEnd, greaterThan(1000.0),
          reason:
              'Next-maneuver distance legitimately jumps when step advances');
    });

    test(
        '12. A confirmed reroute/new route generation can reset Progress and Visual',
        () async {
      final route1 = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route1,
      );
      await nav.applyRouteResult(route1);

      // Advance route 1 to ~1397m in 35 steps
      await advanceToProgress(nav,
          startLat: 5.0000, endLat: 5.01256, lng: 100.0000, count: 35);
      expect(nav.debugMatchedProgress, greaterThan(1000.0));

      // Now new route generation is installed (reroute to new destination)
      const newP0 = LatLng(5.1000, 100.1000);
      const newP1 = LatLng(5.1200, 100.1000);
      final route2 = createTestRoute(points: const [newP0, newP1]);

      await nav.applyRouteResult(route2);

      // Progress and Visual must reset on new route generation
      expect(nav.debugRouteVersion, equals(2));
      expect(nav.debugMatchedProgress, equals(0.0));
      expect(nav.displayDistAlongRoute, equals(0.0));
    });

    test(
        '13. Late asynchronous results from previous route generation cannot overwrite active route',
        () async {
      final gen1Completer = Completer<RouteResult>();
      final gen2Completer = Completer<RouteResult>();
      int fetchCallCount = 0;

      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        routeFetcher: ({
          required double fromLat,
          required double fromLng,
          required double toLat,
          required double toLng,
          required TravelMode mode,
        }) {
          fetchCallCount++;
          if (fetchCallCount == 1) {
            return gen1Completer.future;
          }
          return gen2Completer.future;
        },
      );

      final initialRoute = createTestRoute(points: polyline);
      await nav.applyRouteResult(initialRoute);
      expect(nav.debugRouteVersion, equals(1));

      // Actually trigger an asynchronous reroute request in the controller.
      // This enters _triggerReroute -> _loadRoute, calling routeFetcher and awaiting gen1Completer.future.
      unawaited(nav.triggerRerouteForTesting(
        createTestPosition(latitude: 5.0050, longitude: 100.0050),
        reason: 'async_in_flight_test',
      ));
      // Allow event loop to invoke routeFetcher
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fetchCallCount, equals(1),
          reason: 'Asynchronous route request must be genuinely in flight');
      expect(nav.activeRouteGeneration, equals(1));

      // In production, when a subsequent reroute is requested while a route request is in flight,
      // _loadRoute queues _pendingReroutePosition and increments _activeRouteGeneration.
      unawaited(nav.triggerRerouteForTesting(
        createTestPosition(latitude: 5.0060, longitude: 100.0060),
        reason: 'second_reroute_in_flight',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(nav.activeRouteGeneration, equals(2),
          reason:
              'Pending reroute increments _activeRouteGeneration to supersede in-flight request');

      // Complete the stale in-flight slow route from generation 1
      gen1Completer.complete(createTestRoute(points: const [
        LatLng(5.99, 100.99),
        LatLng(5.995, 100.99),
      ]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Stale generation 1 route was rejected! Pending reroute launched for generation 2.
      expect(fetchCallCount, equals(2),
          reason:
              'Pending reroute must be launched after stale request is discarded');
      expect(nav.polylinePoints.first, equals(polyline.first),
          reason:
              'Stale route result must be rejected and not overwrite active route');

      // When the pending reroute finishes, its route is applied
      const pGen2 = LatLng(5.77, 100.77);
      gen2Completer.complete(
          createTestRoute(points: const [pGen2, LatLng(5.78, 100.78)]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(nav.polylinePoints.first, equals(pGen2),
          reason: 'Pending reroute generation must apply successfully');
      expect(nav.debugRouteVersion, equals(2));
    });

    test(
        '14. Existing Drive, Motorcycle and Walk modes maintain appropriate prediction bounds',
        () async {
      // 1. Test Walk mode prediction bound (<= 1.5m)
      final walkRoute = createTestRoute(points: polyline);
      final navWalk = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.walk,
        initialRoute: walkRoute,
      );
      await navWalk.applyRouteResult(walkRoute);

      await advanceToProgress(navWalk,
          startLat: 5.0000,
          endLat: 5.0005,
          lng: 100.0000,
          count: 3,
          speed: 2.0);
      navWalk.onTickForTesting(const Duration(milliseconds: 100));

      expect(navWalk.debugPredictionLeadMeters, lessThanOrEqualTo(1.5),
          reason: 'Walk prediction lead must not exceed 1.5m');

      // 2. Test Drive mode prediction bound (<= 4.0m)
      final driveRoute = createTestRoute(points: polyline);
      final navDrive = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: driveRoute,
      );
      await navDrive.applyRouteResult(driveRoute);

      await advanceToProgress(navDrive,
          startLat: 5.0000,
          endLat: 5.0010,
          lng: 100.0000,
          count: 5,
          speed: 25.0);
      navDrive.onTickForTesting(const Duration(milliseconds: 100));

      expect(navDrive.debugPredictionLeadMeters, lessThanOrEqualTo(4.0),
          reason: 'Drive prediction lead must not exceed 4.0m');

      // 3. Test Motorcycle mode prediction bound (<= 4.0m)
      final motorRoute = createTestRoute(points: polyline);
      final navMotor = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.motor,
        initialRoute: motorRoute,
      );
      await navMotor.applyRouteResult(motorRoute);

      await advanceToProgress(navMotor,
          startLat: 5.0000,
          endLat: 5.0010,
          lng: 100.0000,
          count: 5,
          speed: 25.0);
      navMotor.onTickForTesting(const Duration(milliseconds: 100));

      expect(navMotor.debugPredictionLeadMeters, lessThanOrEqualTo(4.0),
          reason: 'Motorcycle prediction lead must not exceed 4.0m');
      expect(navMotor.travelMode, equals(TravelMode.motor));
    });

    test(
        '15. Two processed fixes exactly 1 second apart produce dtFix approximately 1.0s, not 0.2s',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      DateTime currentTime = DateTime(2026, 9, 5, 12, 0, 0);
      nav.testClock = () => currentTime;

      // Fix 1 at T=0
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.0001, longitude: 100.0000, speed: 0.0),
        now: currentTime,
      );

      // Advance clock by exactly 1.0 second (1000ms)
      currentTime = currentTime.add(const Duration(milliseconds: 1000));

      // Fix 2 at T=1.0s
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.0002, longitude: 100.0000, speed: 10.0),
        now: currentTime,
      );

      expect(nav.debugLastSpeedDtFix, isNotNull);
      expect(nav.debugLastSpeedDtFix, closeTo(1.0, 0.001),
          reason:
              'Two fixes 1s apart must produce dtFix ~ 1.0s, not clamped to 0.2s');
    });

    test('16. Two processed fixes exactly 500ms apart use approximately 0.5s',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      DateTime currentTime = DateTime(2026, 9, 5, 12, 0, 0);
      nav.testClock = () => currentTime;

      // Fix 1 at T=0
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.0001, longitude: 100.0000, speed: 0.0),
        now: currentTime,
      );

      // Advance clock by exactly 500ms
      currentTime = currentTime.add(const Duration(milliseconds: 500));

      // Fix 2 at T=0.5s
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.0002, longitude: 100.0000, speed: 5.0),
        now: currentTime,
      );

      expect(nav.debugLastSpeedDtFix, isNotNull);
      expect(nav.debugLastSpeedDtFix, closeTo(0.5, 0.001),
          reason: 'Two fixes 500ms apart must produce dtFix ~ 0.5s');
    });

    test(
        '17. Production stream pre-updating GPS-age state does not overwrite separate speed-sample interval',
        () async {
      final route = createTestRoute(points: polyline);
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        initialRoute: route,
      );
      await nav.applyRouteResult(route);

      DateTime currentTime = DateTime(2026, 9, 5, 12, 0, 0);
      nav.testClock = () => currentTime;

      // Production stream event 1: stream listener sets _lastNavigationFixAt = now before _handlePosition
      await nav.simulateProductionGpsStreamEvent(
        createTestPosition(latitude: 5.0001, longitude: 100.0000, speed: 0.0),
        eventTime: currentTime,
      );

      // Advance clock by 1.0 second
      currentTime = currentTime.add(const Duration(seconds: 1));

      // Production stream event 2: pre-updates _lastNavigationFixAt = now
      await nav.simulateProductionGpsStreamEvent(
        createTestPosition(latitude: 5.0002, longitude: 100.0000, speed: 10.0),
        eventTime: currentTime,
      );

      // Even with production pre-update, dtFix must reflect the true 1.0s interval between speed samples
      expect(nav.debugLastSpeedDtFix, closeTo(1.0, 0.001),
          reason:
              'Production stream pre-updating GPS-age state must not overwrite separate speed-sample interval');
      expect(nav.debugGpsAgeSeconds, closeTo(0.0, 0.001));
      expect(nav.debugNavigationFixAgeSeconds, closeTo(0.0, 0.001));
    });

    test(
        '18. Acceleration limit scales with elapsed time (0.5s vs 1.0s vs 2.0s)',
        () async {
      // TravelMode.drive maxAccel is 4.5 m/s^2.
      // 0.5s interval -> max increase = 2.25 m/s
      // 1.0s interval -> max increase = 4.50 m/s
      // 2.0s interval -> max increase = 9.00 m/s

      // 1. 0.5s interval
      final nav05 = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav05.applyRouteResult(createTestRoute(points: polyline));
      DateTime t0 = DateTime(2026, 9, 5, 12, 0, 0);
      nav05.testClock = () => t0;
      await nav05.handlePositionForTesting(
        createTestPosition(latitude: 5.0000, longitude: 100.0000, speed: 0.0),
        now: t0,
      );
      t0 = t0.add(const Duration(milliseconds: 500));
      await nav05.handlePositionForTesting(
        createTestPosition(latitude: 5.0001, longitude: 100.0000, speed: 30.0),
        now: t0,
      );
      final speed05 = nav05.debugSpeedMps;
      expect(speed05, closeTo(2.25, 0.01),
          reason: '0.5s interval must permit ~2.25 m/s increase');

      // 2. 1.0s interval
      final nav10 = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav10.applyRouteResult(createTestRoute(points: polyline));
      DateTime t1 = DateTime(2026, 9, 5, 12, 0, 0);
      nav10.testClock = () => t1;
      await nav10.handlePositionForTesting(
        createTestPosition(latitude: 5.0000, longitude: 100.0000, speed: 0.0),
        now: t1,
      );
      t1 = t1.add(const Duration(milliseconds: 1000));
      await nav10.handlePositionForTesting(
        createTestPosition(latitude: 5.0001, longitude: 100.0000, speed: 30.0),
        now: t1,
      );
      final speed10 = nav10.debugSpeedMps;
      expect(speed10, closeTo(4.50, 0.01),
          reason: '1.0s interval must permit ~4.50 m/s increase');
      expect(speed05, closeTo(speed10 * 0.5, 0.05),
          reason: '0.5s interval permits approximately half of 1.0s interval');

      // 3. 2.0s interval
      final nav20 = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav20.applyRouteResult(createTestRoute(points: polyline));
      DateTime t2 = DateTime(2026, 9, 5, 12, 0, 0);
      nav20.testClock = () => t2;
      await nav20.handlePositionForTesting(
        createTestPosition(latitude: 5.0000, longitude: 100.0000, speed: 0.0),
        now: t2,
      );
      t2 = t2.add(const Duration(milliseconds: 2000));
      await nav20.handlePositionForTesting(
        createTestPosition(latitude: 5.0001, longitude: 100.0000, speed: 30.0),
        now: t2,
      );
      final speed20 = nav20.debugSpeedMps;
      expect(speed20, closeTo(9.00, 0.01),
          reason: '2.0s interval must permit ~9.00 m/s increase');
      expect(speed20, closeTo(speed10 * 2.0, 0.05),
          reason: '2.0s interval permits approximately twice 1.0s interval');
    });

    test('19. Deceleration scales with real elapsed time', () async {
      // TravelMode.drive maxDecel is 9.0 m/s^2.
      // Starting speed = 25.0 m/s (~90 km/h), vehicle suddenly reports 0.0 m/s.
      // 0.5s interval -> max decrease = 4.5 m/s -> speed reaches 20.5 m/s
      // 1.0s interval -> max decrease = 9.0 m/s -> speed reaches 16.0 m/s
      // 2.0s interval -> max decrease = 18.0 m/s -> speed reaches 7.0 m/s

      // 1. 0.5s deceleration
      final nav05 = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav05.applyRouteResult(createTestRoute(points: polyline));
      DateTime t0 = DateTime(2026, 9, 5, 12, 0, 0);
      nav05.testClock = () => t0;
      for (int i = 0; i < 6; i++) {
        t0 = t0.add(const Duration(seconds: 1));
        await nav05.handlePositionForTesting(
          createTestPosition(
              latitude: 5.0000 + i * 0.0002, longitude: 100.0, speed: 25.0),
          now: t0,
        );
      }
      expect(nav05.debugSpeedMps, equals(25.0));

      // Decelerate over 0.5s (vehicle stops at current coordinate)
      t0 = t0.add(const Duration(milliseconds: 500));
      await nav05.handlePositionForTesting(
        createTestPosition(latitude: 5.0010, longitude: 100.0, speed: 0.0),
        now: t0,
      );
      expect(nav05.debugSpeedMps, closeTo(20.5, 0.01),
          reason: '0.5s interval allows 4.5 m/s deceleration');

      // 2. 1.0s deceleration
      final nav10 = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav10.applyRouteResult(createTestRoute(points: polyline));
      DateTime t1 = DateTime(2026, 9, 5, 12, 0, 0);
      nav10.testClock = () => t1;
      for (int i = 0; i < 6; i++) {
        t1 = t1.add(const Duration(seconds: 1));
        await nav10.handlePositionForTesting(
          createTestPosition(
              latitude: 5.0000 + i * 0.0002, longitude: 100.0, speed: 25.0),
          now: t1,
        );
      }
      expect(nav10.debugSpeedMps, equals(25.0));

      // Decelerate over 1.0s (vehicle stops at current coordinate)
      t1 = t1.add(const Duration(milliseconds: 1000));
      await nav10.handlePositionForTesting(
        createTestPosition(latitude: 5.0010, longitude: 100.0, speed: 0.0),
        now: t1,
      );
      expect(nav10.debugSpeedMps, closeTo(16.0, 0.01),
          reason: '1.0s interval allows 9.0 m/s deceleration');

      // 3. 2.0s deceleration
      final nav20 = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav20.applyRouteResult(createTestRoute(points: polyline));
      DateTime t2 = DateTime(2026, 9, 5, 12, 0, 0);
      nav20.testClock = () => t2;
      for (int i = 0; i < 6; i++) {
        t2 = t2.add(const Duration(seconds: 1));
        await nav20.handlePositionForTesting(
          createTestPosition(
              latitude: 5.0000 + i * 0.0002, longitude: 100.0, speed: 25.0),
          now: t2,
        );
      }
      expect(nav20.debugSpeedMps, equals(25.0));

      // Decelerate over 2.0s (vehicle stops at current coordinate)
      t2 = t2.add(const Duration(milliseconds: 2000));
      await nav20.handlePositionForTesting(
        createTestPosition(latitude: 5.0010, longitude: 100.0, speed: 0.0),
        now: t2,
      );
      expect(nav20.debugSpeedMps, closeTo(7.0, 0.01),
          reason: '2.0s interval allows 18.0 m/s deceleration');
    });

    test(
        '20. First abnormal speed sample from rest cannot jump directly to mode ceiling',
        () async {
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav.applyRouteResult(createTestRoute(points: polyline));

      DateTime currentTime = DateTime(2026, 9, 5, 12, 0, 0);
      nav.testClock = () => currentTime;

      // First fix arrives claiming 35.0 m/s (~126 km/h) instantly from rest
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.0001, longitude: 100.0000, speed: 35.0),
        now: currentTime,
      );

      // First sample default dtFix is 1.0s, so max increase is 4.5 m/s.
      // Speed must be capped at 4.5 m/s, NOT jump directly to mode ceiling (35.0 m/s).
      expect(nav.debugSpeedMps, closeTo(4.5, 0.01),
          reason:
              'First sample from rest must not jump directly to 35 m/s mode ceiling');
    });

    test(
        '21. Normal vehicle accelerating from rest does not remain artificially slow because of 0.2s clamping',
        () async {
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        travelMode: TravelMode.drive,
        initialRoute: createTestRoute(points: polyline),
      );
      await nav.applyRouteResult(createTestRoute(points: polyline));

      DateTime currentTime = DateTime(2026, 9, 5, 12, 0, 0);
      nav.testClock = () => currentTime;

      // Initial fix at rest
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.0000, longitude: 100.0000, speed: 0.0),
        now: currentTime,
      );
      expect(nav.debugSpeedMps, equals(0.0));

      // Normal vehicle accelerates at ~3.0 m/s^2 (well within 4.5 m/s^2 drive limit).
      // After 1.0s, candidate speed is 3.0 m/s (~10.8 km/h).
      currentTime = currentTime.add(const Duration(seconds: 1));
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.00003, longitude: 100.0000, speed: 3.0),
        now: currentTime,
      );

      // Under the v1.1 bug, dtFix was falsely 0.2s, capping maxSpeedIncrease at 4.5 * 0.2 = 0.9 m/s.
      // With the v1.2 fix, dtFix is 1.0s, so maxSpeedIncrease is 4.5 m/s, easily permitting 3.0 m/s.
      expect(nav.debugSpeedMps, closeTo(3.0, 0.01),
          reason:
              'Normal acceleration must not be choked to 0.9 m/s by artificial 0.2s clamp');

      // After another 1.0s, speed is 6.0 m/s
      currentTime = currentTime.add(const Duration(seconds: 1));
      await nav.handlePositionForTesting(
        createTestPosition(latitude: 5.00008, longitude: 100.0000, speed: 6.0),
        now: currentTime,
      );
      expect(nav.debugSpeedMps, closeTo(6.0, 0.01),
          reason: 'Speed tracks vehicle acceleration cleanly to 6.0 m/s');
    });

    test(
        '22. Route generation mechanism does not duplicate, invalidate, or disrupt navigation flows',
        () async {
      // 1. Initial route loading
      final nav = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        routeFetcher: ({
          required double fromLat,
          required double fromLng,
          required double toLat,
          required double toLng,
          required TravelMode mode,
        }) async {
          return createTestRoute(points: polyline);
        },
      );

      expect(nav.activeRouteGeneration, equals(0));
      await nav.applyRouteResult(createTestRoute(points: polyline));
      expect(nav.debugRouteVersion, equals(1));
      expect(nav.activeRouteGeneration, equals(0));

      // 2. Successful reroute: triggering reroute launches _loadRoute with ++_activeRouteGeneration
      final rerouteCompleter = Completer<RouteResult>();
      final navReroute = NavigationController(
        startLat: p0.latitude,
        startLng: p0.longitude,
        endLat: p3.latitude,
        endLng: p3.longitude,
        routeFetcher: ({
          required double fromLat,
          required double fromLng,
          required double toLat,
          required double toLng,
          required TravelMode mode,
        }) =>
            rerouteCompleter.future,
      );
      await navReroute.applyRouteResult(createTestRoute(points: polyline));

      unawaited(navReroute.triggerRerouteForTesting(
        createTestPosition(latitude: 5.0050, longitude: 100.0050),
        reason: 'reroute_flow_test',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(navReroute.activeRouteGeneration, equals(1),
          reason:
              '_loadRoute increments activeRouteGeneration exactly once at launch');

      const pReroute0 = LatLng(5.2000, 100.2000);
      const pReroute1 = LatLng(5.2100, 100.2000);
      rerouteCompleter
          .complete(createTestRoute(points: const [pReroute0, pReroute1]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Route applied successfully, generation preserved at 1 (not double-incremented to 2)
      expect(navReroute.debugRouteVersion, equals(2));
      expect(navReroute.activeRouteGeneration, equals(1),
          reason:
              'Generation must not be double-incremented upon applying route');
      expect(navReroute.polylinePoints.first, equals(pReroute0));

      // 3. Traffic refresh does not disrupt active route generation
      final trafficResult = createTestRoute(
        points: const [pReroute0, pReroute1],
        distanceMeters: 1000.0,
        durationSeconds: 500,
      );
      await navReroute.applyRouteResult(trafficResult, isTrafficRefresh: true);
      expect(navReroute.activeRouteGeneration, equals(1),
          reason: 'Traffic refresh does not advance active route generation');
      expect(navReroute.remainingSeconds, equals(500));
    });
  });
}
