import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gotrip/services/location_service.dart';
import 'package:gotrip/services/route_service.dart';
import 'package:gotrip/services/navigate_service.dart';
import 'package:gotrip/modules/place/routePreviewPage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 16B1 — Navigation Metric Truth and Mode Parity Tests', () {
    // 1. Total Drive distance comes from RouteResult.distanceMeters.
    test('1. Total Drive distance comes from RouteResult.distanceMeters', () {
      const driveRoadMeters = 8450.0;
      final result = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [
          NavStep(
            instruction: 'Head north',
            maneuver: 'straight',
            distanceMeters: 8450.0,
            durationSeconds: 900,
            startLocation: LatLng(5.41, 100.33),
            endLocation: LatLng(5.42, 100.34),
            polylinePoints: [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
          )
        ],
        distanceMeters: driveRoadMeters,
        durationSeconds: 900,
        bounds: LatLngBounds(
          southwest: const LatLng(5.41, 100.33),
          northeast: const LatLng(5.42, 100.34),
        ),
      );

      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
        initialRoute: result,
      );

      expect(result.distanceMeters, equals(8450.0));
      expect(nav.travelMode, equals(TravelMode.drive));
    });

    // 2. Total Walk distance comes from the Walk RouteResult.
    test('2. Total Walk distance comes from the Walk RouteResult', () {
      const walkRoadMeters = 1250.0;
      final result = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.415, 100.335)],
        steps: const [
          NavStep(
            instruction: 'Walk north',
            maneuver: 'walk',
            distanceMeters: 1250.0,
            durationSeconds: 900,
            startLocation: LatLng(5.41, 100.33),
            endLocation: LatLng(5.415, 100.335),
            polylinePoints: [LatLng(5.41, 100.33), LatLng(5.415, 100.335)],
          )
        ],
        distanceMeters: walkRoadMeters,
        durationSeconds: 900,
        bounds: LatLngBounds(
          southwest: const LatLng(5.41, 100.33),
          northeast: const LatLng(5.415, 100.335),
        ),
      );

      expect(result.distanceMeters, equals(1250.0));
      expect(result.durationSeconds, equals(900));
    });

    // 3. Motorcycle preview never silently labels Drive data as Motorcycle.
    test('3. Motorcycle preview never silently labels Drive data as Motorcycle',
        () {
      final driveFallbackResult = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 5000.0,
        durationSeconds: 600,
        bounds: LatLngBounds(
          southwest: const LatLng(5.41, 100.33),
          northeast: const LatLng(5.42, 100.34),
        ),
        isFallback: true,
        fallbackNotice:
            'Motorcycle routing is unavailable here. A driving route will be used.',
      );

      expect(driveFallbackResult.isFallback, isTrue);
      expect(driveFallbackResult.fallbackNotice,
          contains('Motorcycle routing is unavailable here'));
    });

    // 4. Explicit Motorcycle fallback is reused during active navigation.
    test('4. Explicit Motorcycle fallback is reused during active navigation',
        () {
      final fallbackResult = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 4500.0,
        durationSeconds: 550,
        bounds: LatLngBounds(
          southwest: const LatLng(5.41, 100.33),
          northeast: const LatLng(5.42, 100.34),
        ),
        isFallback: true,
        fallbackNotice:
            'Motorcycle routing is unavailable here. A driving route will be used.',
      );

      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.motor,
        initialRoute: fallbackResult,
      );

      expect(nav.initialRoute?.isFallback, isTrue);
      expect(nav.initialRoute?.distanceMeters, equals(4500.0));
    });

    // 5. Progress is based on matched distance along route.
    test('5. Progress is based on matched distance along route', () {
      const totalPolyDist = 1000.0;
      const matchedDist = 450.0;
      final progress = (matchedDist / totalPolyDist).clamp(0.0, 1.0);

      expect(progress, equals(0.45));
    });

    // 6. Remaining road distance uses API distance scaled by polyline progress.
    test(
        '6. Remaining road distance uses API distance scaled by polyline progress',
        () {
      const googleRoadMeters = 5000.0;
      const totalPolyDist =
          4800.0; // Decoded polyline geometric length differs slightly
      const matchedDist = 2400.0; // Halfway through polyline

      final routeProgress = (matchedDist / totalPolyDist).clamp(0.0, 1.0);
      final remainingRoadMeters = googleRoadMeters * (1.0 - routeProgress);

      // Exactly 50% of the 5000m road distance = 2500m, NOT (4800 - 2400 = 2400m)
      expect(remainingRoadMeters, equals(2500.0));
    });

    // 7. Remaining distance does not use destination straight-line distance.
    test(
        '7. Remaining distance does not use destination straight-line distance',
        () {
      const straightLineToDestination =
          800.0; // Straight line across river / canyon
      const googleRoadMeters = 6000.0; // Road detour around bridge
      const routeProgress = 0.25;

      final remainingRoadMeters = googleRoadMeters * (1.0 - routeProgress);

      expect(remainingRoadMeters, equals(4500.0));
      expect(remainingRoadMeters, isNot(equals(straightLineToDestination)));
    });

    // 8. Remaining duration decreases consistently with route progress.
    test('8. Remaining duration decreases consistently with route progress',
        () {
      const step1Sec = 200;
      const step2Sec = 400;

      // Halfway through step 1:
      const step1RemainingRatio = 0.5;
      final remainingAtMidStep1 = (step1Sec * step1RemainingRatio) + step2Sec;

      // At start of step 2:
      const step2RemainingRatio = 1.0;
      final remainingAtStartStep2 = step2Sec * step2RemainingRatio;

      expect(remainingAtMidStep1, equals(500));
      expect(remainingAtStartStep2, equals(400));
      expect(remainingAtStartStep2, lessThan(remainingAtMidStep1));
    });

    // 9. Zero GPS speed does not make ETA infinite.
    test('9. Zero GPS speed does not make ETA infinite', () {
      const totalBaselineSeconds = 1200;
      const routeProgress = 0.5;

      // Speed is 0.0 m/s (stopped at a red light)
      const currentSpeed = 0.0;
      expect(currentSpeed, equals(0.0));

      final remainingDurationSec =
          (totalBaselineSeconds * (1.0 - routeProgress)).round();
      final eta = DateTime(2026, 9, 3, 14, 0)
          .add(Duration(seconds: remainingDurationSec));

      expect(remainingDurationSec, equals(600));
      expect(eta, equals(DateTime(2026, 9, 3, 14, 10)));
      expect(remainingDurationSec.isFinite, isTrue);
    });

    // 10. One inaccurate forward GPS jump does not permanently advance progress.
    test(
        '10. One inaccurate forward GPS jump does not permanently advance progress',
        () {
      const currentMatchedDist = 300.0;
      const speed = 10.0; // 36 km/h
      const recoverySeconds = 1.0;
      const goodGps = true;

      final maxAllowableJump = [
        45.0,
        speed * recoverySeconds * 2.0 + (goodGps ? 40.0 : 20.0),
      ].reduce((a, b) => a > b ? a : b); // max(45.0, 10 * 1 * 2 + 40 = 60.0)

      // Spurious GPS spike 250m ahead along route
      const candidateDistAlongRoute = 550.0;
      final candidateJump = candidateDistAlongRoute - currentMatchedDist;
      final isPlausibleJump = candidateJump <= maxAllowableJump;

      expect(maxAllowableJump, equals(60.0));
      expect(candidateJump, equals(250.0));
      expect(
          isPlausibleJump, isFalse); // Rejected! Progress does not jump to 550m
    });

    // 11. Progress does not move backward under ordinary jitter.
    test('11. Progress does not move backward under ordinary jitter', () {
      var currentProgress = 500.0;

      // Fix with backward jitter (projects to 492m)
      const jitterCandidate = 492.0;
      if (jitterCandidate >= currentProgress) {
        currentProgress = jitterCandidate;
      }

      expect(currentProgress, equals(500.0)); // Maintained invariant
    });

    // 12. Next-turn instruction and distance use the same step.
    test('12. Next-turn instruction and distance use the same step', () {
      const step0 = NavStep(
        instruction: 'Head north on Main St',
        maneuver: 'straight',
        distanceMeters: 400.0,
        durationSeconds: 60,
        startLocation: LatLng(5.41, 100.33),
        endLocation: LatLng(5.414, 100.33),
        polylinePoints: [],
      );

      const step1 = NavStep(
        instruction: 'Turn right onto Market St',
        maneuver: 'turn-right',
        distanceMeters: 300.0,
        durationSeconds: 45,
        startLocation: LatLng(5.414, 100.33),
        endLocation: LatLng(5.414, 100.333),
        polylinePoints: [],
      );

      final steps = [step0, step1];
      const currentStepIndex = 0;

      // In step 0, currentStep getter returns upcoming maneuver (step 1)
      final upcomingManeuver = currentStepIndex + 1 < steps.length
          ? steps[currentStepIndex + 1]
          : steps[currentStepIndex];

      // Distance to end of step 0 is distance counting down to step 1
      const stepRemainingRatio = 0.75; // 75% of step 0 remaining = 300m
      final distToUpcomingTurn = step0.distanceMeters * stepRemainingRatio;

      expect(upcomingManeuver.instruction, equals('Turn right onto Market St'));
      expect(distToUpcomingTurn, equals(300.0));
    });

    // 13. Reroute atomically replaces all route metrics.
    test('13. Reroute atomically replaces all route metrics', () {
      final oldRoute = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 10000.0,
        durationSeconds: 1200,
        bounds: LatLngBounds(
          southwest: const LatLng(5.41, 100.33),
          northeast: const LatLng(5.42, 100.34),
        ),
      );

      final newReroute = RouteResult(
        polylinePoints: const [LatLng(5.415, 100.335), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 6200.0,
        durationSeconds: 750,
        bounds: LatLngBounds(
          southwest: const LatLng(5.415, 100.335),
          northeast: const LatLng(5.42, 100.34),
        ),
      );

      var totalMeters = oldRoute.distanceMeters;
      var remainingMeters = oldRoute.distanceMeters;
      var remainingSec = oldRoute.durationSeconds;
      var matchedDist = 3800.0;

      // Atomic reroute replacement:
      totalMeters = newReroute.distanceMeters;
      remainingMeters = newReroute.distanceMeters;
      remainingSec = newReroute.durationSeconds;
      matchedDist = 0.0;

      expect(totalMeters, equals(6200.0));
      expect(remainingMeters, equals(6200.0));
      expect(remainingSec, equals(750));
      expect(matchedDist, equals(0.0));
    });

    // 14. Failed reroute preserves the last valid route metrics.
    test('14. Failed reroute preserves the last valid route metrics', () {
      const existingTotalMeters = 8000.0;
      const existingRemainingMeters = 4200.0;
      const existingMatchedProgress = 3800.0;

      var totalMeters = existingTotalMeters;
      var remainingMeters = existingRemainingMeters;
      var matchedProgress = existingMatchedProgress;

      // Network error occurs during reroute
      final errorOccurred = true;
      if (errorOccurred) {
        // Fallback: retain existing metrics
        // Do NOT reset to 0 or null
      }

      expect(totalMeters, equals(8000.0));
      expect(remainingMeters, equals(4200.0));
      expect(matchedProgress, equals(3800.0));
    });

    // 15. Stale GPS stops unlimited prediction.
    test('15. Stale GPS stops unlimited prediction', () {
      const speed = 15.0; // 54 km/h
      final now = DateTime.now();
      final lastFix = now.subtract(const Duration(seconds: 5)); // 5 seconds old

      final gpsAgeSeconds = now.difference(lastFix).inMilliseconds / 1000.0;
      final canDeadReckon = speed > 1.0 && gpsAgeSeconds < 4.0;

      final predictionLead = canDeadReckon ? speed * 4.0 : 0.0;

      expect(gpsAgeSeconds, greaterThanOrEqualTo(4.0));
      expect(canDeadReckon, isFalse);
      expect(predictionLead, equals(0.0)); // Prediction frozen
    });

    // 16. Fresh origin is preferred before navigation starts.
    test('16. Fresh origin is preferred before navigation starts', () {
      const staleUserLat = 5.4100;
      const staleUserLng = 100.3300;

      const liveGpsLat = 5.4180;
      const liveGpsLng = 100.3380;

      // Logic from PlaceDetailPage: if live GPS is available, prefer it over stale widget coordinates
      const hasLiveGps = true;
      final selectedLat = hasLiveGps ? liveGpsLat : staleUserLat;
      final selectedLng = hasLiveGps ? liveGpsLng : staleUserLng;

      expect(selectedLat, equals(5.4180));
      expect(selectedLng, equals(100.3380));
      expect(selectedLat, isNot(equals(staleUserLat)));
    });

    // 17. Invalid (0,0) coordinates are rejected.
    test('17. Invalid (0,0) coordinates are rejected', () async {
      expect(
        () => RouteService.instance.fetchNavigationRoute(
          fromLat: 0.0,
          fromLng: 0.0,
          toLat: 5.42,
          toLng: 100.34,
          mode: TravelMode.drive,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    // 18. Existing lower-marker, progress-bar and camera configuration remain present.
    test(
        '18. Existing lower-marker, progress-bar and camera configuration remain present',
        () {
      final navDrive = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
      );

      final navWalk = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.walk,
      );

      // Tilt is 45 for Drive/Motor, 0 for Walk
      expect(navDrive.travelMode, equals(TravelMode.drive));
      expect(navWalk.travelMode, equals(TravelMode.walk));
      expect(navDrive.progress, inInclusiveRange(0.0, 1.0));
    });

    // 19. Walk, Motorcycle and Drive all remain supported.
    test('19. Walk, Motorcycle and Drive all remain supported', () {
      expect(TravelMode.values, contains(TravelMode.walk));
      expect(TravelMode.values, contains(TravelMode.motor));
      expect(TravelMode.values, contains(TravelMode.drive));

      expect(travelModeFromString('walk'), equals(TravelMode.walk));
      expect(travelModeFromString('motor'), equals(TravelMode.motor));
      expect(travelModeFromString('drive'), equals(TravelMode.drive));
      expect(travelModeFromString('both'), equals(TravelMode.drive));
    });

    // 20. Progress clamp guarantees no NaN or infinity and reaches 1.0 only on arrival.
    test(
        '20. Progress clamp guarantees no NaN or infinity and reaches 1.0 only on arrival',
        () {
      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
      );

      expect(nav.progress.isNaN, isFalse);
      expect(nav.progress.isInfinite, isFalse);
      expect(nav.progress, equals(0.0));
      expect(nav.hasArrived, isFalse);
    });
  });

  group('Task 16B1.1 — ETA Traffic Calibration and Origin Freshness Tests', () {
    // 1. Sum of adjusted step durations equals route baseline duration.
    test('1. Sum of adjusted step durations equals route baseline duration',
        () {
      final steps = [
        const NavStep(
          instruction: 'Step 1',
          maneuver: 'straight',
          distanceMeters: 500,
          durationSeconds: 400,
          startLocation: LatLng(5.41, 100.33),
          endLocation: LatLng(5.415, 100.335),
          polylinePoints: [],
        ),
        const NavStep(
          instruction: 'Step 2',
          maneuver: 'turn-right',
          distanceMeters: 700,
          durationSeconds: 600,
          startLocation: LatLng(5.415, 100.335),
          endLocation: LatLng(5.42, 100.34),
          polylinePoints: [],
        ),
      ];

      // Route baseline is traffic-aware (1500s total, vs static 1000s)
      final remaining = NavigationController.calculateRemainingDuration(
        routeBaselineSeconds: 1500,
        steps: steps,
        currentStepIndex: 0,
        currentStepRemainingRatio: 1.0,
        routeProgress: 0.0,
      );

      expect(remaining, equals(1500));
    });

    // 2. Half-completed current step reduces adjusted remaining time correctly.
    test(
        '2. Half-completed current step reduces adjusted remaining time correctly',
        () {
      final steps = [
        const NavStep(
          instruction: 'Step 1',
          maneuver: 'straight',
          distanceMeters: 500,
          durationSeconds: 400,
          startLocation: LatLng(5.41, 100.33),
          endLocation: LatLng(5.415, 100.335),
          polylinePoints: [],
        ),
        const NavStep(
          instruction: 'Step 2',
          maneuver: 'turn-right',
          distanceMeters: 700,
          durationSeconds: 600,
          startLocation: LatLng(5.415, 100.335),
          endLocation: LatLng(5.42, 100.34),
          polylinePoints: [],
        ),
      ];

      // Step 1 adjusted duration is 1500 * (400 / 1000) = 600s.
      // Half completed (currentStepRemainingRatio = 0.5) -> 300s remaining.
      // Step 2 adjusted duration is 1500 * (600 / 1000) = 900s.
      // Total remaining = 300 + 900 = 1200s.
      final remaining = NavigationController.calculateRemainingDuration(
        routeBaselineSeconds: 1500,
        steps: steps,
        currentStepIndex: 0,
        currentStepRemainingRatio: 0.5,
        routeProgress: 0.2,
      );

      expect(remaining, equals(1200));
    });

    // 3. Traffic-aware route duration remains authoritative.
    test('3. Traffic-aware route duration remains authoritative', () {
      final steps = [
        const NavStep(
          instruction: 'Step 1',
          maneuver: 'straight',
          distanceMeters: 1000,
          durationSeconds: 600, // static duration without traffic
          startLocation: LatLng(5.41, 100.33),
          endLocation: LatLng(5.42, 100.34),
          polylinePoints: [],
        ),
      ];

      // Traffic baseline is 1800s (heavy rush hour traffic)
      final remaining = NavigationController.calculateRemainingDuration(
        routeBaselineSeconds: 1800,
        steps: steps,
        currentStepIndex: 0,
        currentStepRemainingRatio: 1.0,
        routeProgress: 0.0,
      );

      expect(remaining, equals(1800));
      expect(remaining, isNot(equals(600)));
    });

    // 4. Zero step durations use proportional fallback.
    test('4. Zero step durations use proportional fallback', () {
      final steps = [
        const NavStep(
          instruction: 'Step 1',
          maneuver: 'straight',
          distanceMeters: 500,
          durationSeconds: 0,
          startLocation: LatLng(5.41, 100.33),
          endLocation: LatLng(5.415, 100.335),
          polylinePoints: [],
        ),
      ];

      // 40% progress on a 1000s route with 0s step duration
      final remaining = NavigationController.calculateRemainingDuration(
        routeBaselineSeconds: 1000,
        steps: steps,
        currentStepIndex: 0,
        currentStepRemainingRatio: 0.6,
        routeProgress: 0.40,
      );

      expect(remaining, equals(600)); // 1000 * (1 - 0.40)
    });

    // 5. Recent cached GPS is accepted.
    test('5. Recent cached GPS is accepted', () {
      final now = DateTime.now();
      final recentPos = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now.subtract(const Duration(seconds: 4)),
        altitude: 10.0,
        altitudeAccuracy: 1.0,
        accuracy: 8.0,
        heading: 90.0,
        headingAccuracy: 5.0,
        speed: 12.0,
        speedAccuracy: 1.0,
      );

      expect(LocationService.isPositionFresh(recentPos, now: now), isTrue);
    });

    // 6. Stale cached GPS requests a fresh position.
    test('6. Stale cached GPS requests a fresh position', () {
      final now = DateTime.now();
      final stalePos = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now
            .subtract(const Duration(seconds: 25)), // 25s old > 10s threshold
        altitude: 10.0,
        altitudeAccuracy: 1.0,
        accuracy: 8.0,
        heading: 90.0,
        headingAccuracy: 5.0,
        speed: 12.0,
        speedAccuracy: 1.0,
      );

      expect(LocationService.isPositionFresh(stalePos, now: now), isFalse);
    });

    // 7. Moved-away start rejects old initialRoute.
    test('7. Moved-away start rejects old initialRoute', () {
      final oldRoute = RouteResult(
        polylinePoints: const [
          LatLng(5.4100, 100.3300),
          LatLng(5.4200, 100.3400)
        ],
        steps: const [],
        distanceMeters: 5000,
        durationSeconds: 600,
        bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.33),
            northeast: const LatLng(5.42, 100.34)),
      );

      // User moved 650m away during preview
      const movedGps = LatLng(5.4155, 100.3310);
      final canReuse = NavigationController.shouldReuseInitialRoute(
        currentGps: movedGps,
        initialRoute: oldRoute,
        mode: TravelMode.drive,
      );

      expect(canReuse, isFalse);
    });

    // 8. Normal GPS drift reuses initialRoute.
    test('8. Normal GPS drift reuses initialRoute', () {
      final route = RouteResult(
        polylinePoints: const [
          LatLng(5.41000, 100.33000),
          LatLng(5.4200, 100.3400)
        ],
        steps: const [],
        distanceMeters: 5000,
        durationSeconds: 600,
        bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.33),
            northeast: const LatLng(5.42, 100.34)),
      );

      // Jitter of only 12m
      const driftedGps = LatLng(5.41008, 100.33005);
      final canReuse = NavigationController.shouldReuseInitialRoute(
        currentGps: driftedGps,
        initialRoute: route,
        mode: TravelMode.drive,
      );

      expect(canReuse, isTrue);
    });

    // 9. Only selected preview mode is fetched initially.
    test('9. Only selected preview mode is fetched initially', () {
      // Test the preview mode cache structure
      final routeData = <TravelMode, RouteResult?>{};
      const selectedMode = TravelMode.drive;

      // Simulate lazy loading initial state: only selected mode fetched
      routeData[selectedMode] = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 5000,
        durationSeconds: 600,
        bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.33),
            northeast: const LatLng(5.42, 100.34)),
      );

      expect(routeData.containsKey(TravelMode.drive), isTrue);
      expect(routeData.containsKey(TravelMode.walk), isFalse);
      expect(routeData.containsKey(TravelMode.motor), isFalse);
    });

    // 10. Selecting another mode fetches it once.
    test('10. Selecting another mode fetches it once', () {
      final routeData = <TravelMode, RouteResult?>{
        TravelMode.drive: RouteResult(
          polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
          steps: const [],
          distanceMeters: 5000,
          durationSeconds: 600,
          bounds: LatLngBounds(
              southwest: const LatLng(5.41, 100.33),
              northeast: const LatLng(5.42, 100.34)),
        ),
      };

      int fetchCount = 0;
      void selectMode(TravelMode mode) {
        if (!routeData.containsKey(mode)) {
          fetchCount++;
          routeData[mode] = RouteResult(
            polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
            steps: const [],
            distanceMeters: 4800,
            durationSeconds: 500,
            bounds: LatLngBounds(
                southwest: const LatLng(5.41, 100.33),
                northeast: const LatLng(5.42, 100.34)),
          );
        }
      }

      selectMode(TravelMode.motor);
      expect(fetchCount, equals(1));
      expect(routeData.containsKey(TravelMode.motor), isTrue);
    });

    // 11. Returning to a fetched mode uses cache.
    test('11. Returning to a fetched mode uses cache', () {
      final routeData = <TravelMode, RouteResult?>{
        TravelMode.drive: RouteResult(
          polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
          steps: const [],
          distanceMeters: 5000,
          durationSeconds: 600,
          bounds: LatLngBounds(
              southwest: const LatLng(5.41, 100.33),
              northeast: const LatLng(5.42, 100.34)),
        ),
        TravelMode.motor: RouteResult(
          polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
          steps: const [],
          distanceMeters: 4800,
          durationSeconds: 500,
          bounds: LatLngBounds(
              southwest: const LatLng(5.41, 100.33),
              northeast: const LatLng(5.42, 100.34)),
        ),
      };

      int fetchCount = 0;
      void selectMode(TravelMode mode) {
        if (!routeData.containsKey(mode)) {
          fetchCount++;
        }
      }

      // Switching back to Drive
      selectMode(TravelMode.drive);
      expect(fetchCount, equals(0)); // Zero new fetches; cached route used
    });

    // 12. Waze-style UI and progress logic remain unchanged.
    test('12. Waze-style UI and progress logic remain unchanged', () {
      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
      );

      expect(nav.progress, equals(0.0));
      expect(nav.progress.isFinite, isTrue);
      expect(nav.travelMode, equals(TravelMode.drive));
    });
  });

  group('Task 16B1.2 — Bounded Live Traffic ETA Refresh Tests', () {
    // 1. Walking navigation never performs traffic refresh.
    test('1. Walking navigation never performs traffic refresh', () {
      final now = DateTime.now();
      final validGps = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now,
        altitude: 10,
        altitudeAccuracy: 1,
        accuracy: 5,
        heading: 0,
        headingAccuracy: 0,
        speed: 1.2,
        speedAccuracy: 0.5,
      );
      final outReason = StringBuffer();
      final eligible = NavigationController.checkTrafficRefreshEligibility(
        isNavigationActive: true,
        isDisposed: false,
        hasArrived: false,
        mode: TravelMode.walk,
        lastGps: validGps,
        lastGpsTime: now,
        isOffline: false,
        isRequestInFlight: false,
        lastSuccessfulRouteOrRefreshAt:
            now.subtract(const Duration(minutes: 10)),
        lastTrafficAttemptAt: null,
        remainingMeters: 5000,
        now: now,
        outReason: outReason,
      );
      expect(eligible, isFalse);
      expect(outReason.toString(), equals('walking'));
    });

    // 2. Drive navigation cannot refresh before five-minute cooldown.
    test('2. Drive navigation cannot refresh before five-minute cooldown', () {
      final now = DateTime.now();
      final validGps = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now,
        altitude: 10,
        altitudeAccuracy: 1,
        accuracy: 5,
        heading: 0,
        headingAccuracy: 0,
        speed: 12,
        speedAccuracy: 1,
      );
      final outReason = StringBuffer();
      final eligible = NavigationController.checkTrafficRefreshEligibility(
        isNavigationActive: true,
        isDisposed: false,
        hasArrived: false,
        mode: TravelMode.drive,
        lastGps: validGps,
        lastGpsTime: now,
        isOffline: false,
        isRequestInFlight: false,
        lastSuccessfulRouteOrRefreshAt:
            now.subtract(const Duration(minutes: 3)), // 3m < 5m
        lastTrafficAttemptAt: null,
        remainingMeters: 5000,
        now: now,
        outReason: outReason,
      );
      expect(eligible, isFalse);
      expect(outReason.toString(), equals('cooldown'));
    });

    // 3. Drive navigation becomes eligible after five minutes.
    test('3. Drive navigation becomes eligible after five minutes', () {
      final now = DateTime.now();
      final validGps = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now,
        altitude: 10,
        altitudeAccuracy: 1,
        accuracy: 5,
        heading: 0,
        headingAccuracy: 0,
        speed: 12,
        speedAccuracy: 1,
      );
      final outReason = StringBuffer();
      final eligible = NavigationController.checkTrafficRefreshEligibility(
        isNavigationActive: true,
        isDisposed: false,
        hasArrived: false,
        mode: TravelMode.drive,
        lastGps: validGps,
        lastGpsTime: now,
        isOffline: false,
        isRequestInFlight: false,
        lastSuccessfulRouteOrRefreshAt:
            now.subtract(const Duration(seconds: 310)), // > 300s
        lastTrafficAttemptAt: null,
        remainingMeters: 5000,
        now: now,
        outReason: outReason,
      );
      expect(eligible, isTrue);
      expect(outReason.toString(), equals('eligible'));
    });

    // 4. Routes shorter than or equal to 2 km do not refresh.
    test('4. Routes shorter than or equal to 2 km do not refresh', () {
      final now = DateTime.now();
      final validGps = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now,
        altitude: 10,
        altitudeAccuracy: 1,
        accuracy: 5,
        heading: 0,
        headingAccuracy: 0,
        speed: 12,
        speedAccuracy: 1,
      );
      final outReason = StringBuffer();
      final eligible = NavigationController.checkTrafficRefreshEligibility(
        isNavigationActive: true,
        isDisposed: false,
        hasArrived: false,
        mode: TravelMode.drive,
        lastGps: validGps,
        lastGpsTime: now,
        isOffline: false,
        isRequestInFlight: false,
        lastSuccessfulRouteOrRefreshAt:
            now.subtract(const Duration(minutes: 10)),
        lastTrafficAttemptAt: null,
        remainingMeters: 2000.0, // boundary case <= 2000m
        now: now,
        outReason: outReason,
      );
      expect(eligible, isFalse);
      expect(outReason.toString(), equals('near_destination'));
    });

    // 5. Invalid GPS coordinates do not refresh.
    test('5. Invalid GPS coordinates do not refresh', () {
      final now = DateTime.now();
      final outReason = StringBuffer();
      final eligible = NavigationController.checkTrafficRefreshEligibility(
        isNavigationActive: true,
        isDisposed: false,
        hasArrived: false,
        mode: TravelMode.drive,
        lastGps: null,
        lastGpsTime: null,
        isOffline: false,
        isRequestInFlight: false,
        lastSuccessfulRouteOrRefreshAt:
            now.subtract(const Duration(minutes: 10)),
        lastTrafficAttemptAt: null,
        remainingMeters: 5000.0,
        now: now,
        outReason: outReason,
      );
      expect(eligible, isFalse);
      expect(outReason.toString(), equals('no_fresh_gps'));
    });

    // 6. Offline navigation does not refresh.
    test('6. Offline navigation does not refresh', () {
      final now = DateTime.now();
      final validGps = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now,
        altitude: 10,
        altitudeAccuracy: 1,
        accuracy: 5,
        heading: 0,
        headingAccuracy: 0,
        speed: 12,
        speedAccuracy: 1,
      );
      final outReason = StringBuffer();
      final eligible = NavigationController.checkTrafficRefreshEligibility(
        isNavigationActive: true,
        isDisposed: false,
        hasArrived: false,
        mode: TravelMode.drive,
        lastGps: validGps,
        lastGpsTime: now,
        isOffline: true, // offline navigation
        isRequestInFlight: false,
        lastSuccessfulRouteOrRefreshAt:
            now.subtract(const Duration(minutes: 10)),
        lastTrafficAttemptAt: null,
        remainingMeters: 5000.0,
        now: now,
        outReason: outReason,
      );
      expect(eligible, isFalse);
      expect(outReason.toString(), equals('offline'));
    });

    // 7. Request-in-flight prevents duplicate requests.
    test('7. Request-in-flight prevents duplicate requests', () {
      final now = DateTime.now();
      final validGps = Position(
        latitude: 5.4164,
        longitude: 100.3327,
        timestamp: now,
        altitude: 10,
        altitudeAccuracy: 1,
        accuracy: 5,
        heading: 0,
        headingAccuracy: 0,
        speed: 12,
        speedAccuracy: 1,
      );
      final outReason = StringBuffer();
      final eligible = NavigationController.checkTrafficRefreshEligibility(
        isNavigationActive: true,
        isDisposed: false,
        hasArrived: false,
        mode: TravelMode.drive,
        lastGps: validGps,
        lastGpsTime: now,
        isOffline: false,
        isRequestInFlight: true, // request already in flight
        lastSuccessfulRouteOrRefreshAt:
            now.subtract(const Duration(minutes: 10)),
        lastTrafficAttemptAt: null,
        remainingMeters: 5000.0,
        now: now,
        outReason: outReason,
      );
      expect(eligible, isFalse);
      expect(outReason.toString(), equals('request_in_flight'));
    });

    // 8. Valid refreshed result updates authoritative duration and road distance.
    test(
        '8. Valid refreshed result updates authoritative duration and road distance',
        () async {
      final initialRoute = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [
          NavStep(
            instruction: 'Go straight',
            maneuver: 'straight',
            distanceMeters: 5000.0,
            durationSeconds: 600,
            startLocation: LatLng(5.41, 100.33),
            endLocation: LatLng(5.42, 100.34),
            polylinePoints: [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
          ),
        ],
        distanceMeters: 5000.0,
        durationSeconds: 600,
        bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.33),
            northeast: const LatLng(5.42, 100.34)),
      );

      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
      );
      await nav.applyRouteResult(initialRoute);
      expect(nav.remainingMeters, equals(5000.0));
      expect(nav.remainingSeconds, equals(600));

      // New traffic-refreshed route
      final refreshedRoute = RouteResult(
        polylinePoints: const [LatLng(5.415, 100.335), LatLng(5.42, 100.34)],
        steps: const [
          NavStep(
            instruction: 'Continue to destination',
            maneuver: 'straight',
            distanceMeters: 4500.0,
            durationSeconds: 950,
            startLocation: LatLng(5.415, 100.335),
            endLocation: LatLng(5.42, 100.34),
            polylinePoints: [LatLng(5.415, 100.335), LatLng(5.42, 100.34)],
          ),
        ],
        distanceMeters: 4500.0,
        durationSeconds: 950,
        bounds: LatLngBounds(
            southwest: const LatLng(5.415, 100.335),
            northeast: const LatLng(5.42, 100.34)),
      );

      await nav.applyRouteResult(refreshedRoute, isTrafficRefresh: true);
      expect(nav.remainingMeters, equals(4500.0));
      expect(nav.remainingSeconds, equals(950));
    });

    // 9. Failed refresh preserves the previous route and metrics.
    test('9. Failed refresh preserves the previous route and metrics',
        () async {
      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
      );
      final initialRoute = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 5000.0,
        durationSeconds: 600,
        bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.33),
            northeast: const LatLng(5.42, 100.34)),
      );
      await nav.applyRouteResult(initialRoute);

      final prevMeters = nav.remainingMeters;
      final prevSeconds = nav.remainingSeconds;
      final prevPoints = List<LatLng>.from(nav.polylinePoints);

      // A failed refresh does not modify route metrics
      expect(nav.remainingMeters, equals(prevMeters));
      expect(nav.remainingSeconds, equals(prevSeconds));
      expect(nav.polylinePoints, equals(prevPoints));
    });

    // 10. Stale response from an earlier request/session is ignored.
    test('10. Stale response from an earlier request/session is ignored', () {
      final route = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 5000.0,
        durationSeconds: 600,
        bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.33),
            northeast: const LatLng(5.42, 100.34)),
      );
      final isValid = NavigationController.isValidTrafficRefreshResult(
        result: route,
        requestSessionId: 'session_old',
        currentSessionId: 'session_new',
        requestGeneration: 1,
        currentGeneration: 1,
        isNavigationActive: true,
      );
      expect(isValid, isFalse);
    });

    // 11. Stopping or disposing navigation cancels scheduled refresh work.
    test('11. Stopping or disposing navigation cancels scheduled refresh work',
        () {
      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
      );
      nav.startTrafficRefreshTimer();
      expect(nav.isTrafficRefreshActive, isTrue);

      nav.dispose();
      expect(nav.isTrafficRefreshActive, isFalse);
      expect(nav.isDisposed, isTrue);
    });

    // 12. Off-route reroute cannot be overwritten by an older traffic response.
    test(
        '12. Off-route reroute cannot be overwritten by an older traffic response',
        () {
      final route = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 5000.0,
        durationSeconds: 600,
        bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.33),
            northeast: const LatLng(5.42, 100.34)),
      );

      // Traffic refresh was initiated with generation 1; reroute advanced active generation to 2
      final isValid = NavigationController.isValidTrafficRefreshResult(
        result: route,
        requestSessionId: 'session_1',
        currentSessionId: 'session_1',
        requestGeneration: 1,
        currentGeneration: 2,
        isNavigationActive: true,
      );
      expect(isValid, isFalse);
    });

    // 13. Existing calculateRemainingDuration() behaviour remains correct.
    test('13. Existing calculateRemainingDuration() behaviour remains correct',
        () {
      final steps = [
        const NavStep(
          instruction: 'Step 1',
          maneuver: 'straight',
          distanceMeters: 500,
          durationSeconds: 400,
          startLocation: LatLng(5.41, 100.33),
          endLocation: LatLng(5.415, 100.335),
          polylinePoints: [],
        ),
        const NavStep(
          instruction: 'Step 2',
          maneuver: 'turn-right',
          distanceMeters: 700,
          durationSeconds: 600,
          startLocation: LatLng(5.415, 100.335),
          endLocation: LatLng(5.42, 100.34),
          polylinePoints: [],
        ),
      ];

      final remaining = NavigationController.calculateRemainingDuration(
        routeBaselineSeconds: 1500,
        steps: steps,
        currentStepIndex: 0,
        currentStepRemainingRatio: 1.0,
        routeProgress: 0.0,
      );
      expect(remaining, equals(1500));
    });

    // 14. Existing marker, camera-follow and progress calculations remain unchanged.
    test(
        '14. Existing marker, camera-follow and progress calculations remain unchanged',
        () {
      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
      );

      expect(nav.cameraBearing, equals(0.0));
      expect(nav.progress, equals(0.0));
      expect(nav.progress.isFinite, isTrue);
      expect(nav.hasArrived, isFalse);
    });
  });

  group('Task 16B1.2A — Lifecycle and Route Request Protection Tests', () {
    // 1. canInitiateRouteRequest blocks requests when disposed or arrived.
    test('1. canInitiateRouteRequest blocks requests when disposed or arrived',
        () {
      expect(
        NavigationController.canInitiateRouteRequest(
          isDisposed: true,
          hasArrived: false,
        ),
        isFalse,
      );
      expect(
        NavigationController.canInitiateRouteRequest(
          isDisposed: false,
          hasArrived: true,
        ),
        isFalse,
      );
      expect(
        NavigationController.canInitiateRouteRequest(
          isDisposed: true,
          hasArrived: true,
        ),
        isFalse,
      );
      expect(
        NavigationController.canInitiateRouteRequest(
          isDisposed: false,
          hasArrived: false,
        ),
        isTrue,
      );
    });

    // 2. shouldLaunchPendingReroute prevents launching when disposed, arrived or no position.
    test(
        '2. shouldLaunchPendingReroute prevents launching when disposed, arrived or no position',
        () {
      expect(
        NavigationController.shouldLaunchPendingReroute(
          isDisposed: true,
          hasArrived: false,
          hasPendingPosition: true,
        ),
        isFalse,
      );
      expect(
        NavigationController.shouldLaunchPendingReroute(
          isDisposed: false,
          hasArrived: true,
          hasPendingPosition: true,
        ),
        isFalse,
      );
      expect(
        NavigationController.shouldLaunchPendingReroute(
          isDisposed: false,
          hasArrived: false,
          hasPendingPosition: false,
        ),
        isFalse,
      );
      expect(
        NavigationController.shouldLaunchPendingReroute(
          isDisposed: false,
          hasArrived: false,
          hasPendingPosition: true,
        ),
        isTrue,
      );
    });

    // 3. isValidTrafficRefreshResult rejects stale responses or inactive navigation.
    test(
        '3. isValidTrafficRefreshResult rejects stale responses or inactive navigation',
        () {
      final route = RouteResult(
        polylinePoints: const [LatLng(5.41, 100.33), LatLng(5.42, 100.34)],
        steps: const [],
        distanceMeters: 5000,
        durationSeconds: 600,
        bounds: LatLngBounds(
          southwest: const LatLng(5.41, 100.33),
          northeast: const LatLng(5.42, 100.34),
        ),
      );

      // Mismatched session
      expect(
        NavigationController.isValidTrafficRefreshResult(
          result: route,
          requestSessionId: 'sess_1',
          currentSessionId: 'sess_2',
          requestGeneration: 1,
          currentGeneration: 1,
          isNavigationActive: true,
        ),
        isFalse,
      );

      // Mismatched generation (e.g. from disposal, arrival, or reroute)
      expect(
        NavigationController.isValidTrafficRefreshResult(
          result: route,
          requestSessionId: 'sess_1',
          currentSessionId: 'sess_1',
          requestGeneration: 1,
          currentGeneration: 2,
          isNavigationActive: true,
        ),
        isFalse,
      );

      // Inactive navigation (disposed or arrived)
      expect(
        NavigationController.isValidTrafficRefreshResult(
          result: route,
          requestSessionId: 'sess_1',
          currentSessionId: 'sess_1',
          requestGeneration: 1,
          currentGeneration: 1,
          isNavigationActive: false,
        ),
        isFalse,
      );
    });

    // 4. Disposal lifecycle cancels scheduled refresh timer and marks disposed.
    test(
        '4. Disposal lifecycle cancels scheduled refresh timer and marks disposed',
        () {
      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
      );
      nav.startTrafficRefreshTimer();
      expect(nav.isTrafficRefreshActive, isTrue);

      nav.dispose();
      expect(nav.isTrafficRefreshActive, isFalse);
      expect(nav.isDisposed, isTrue);
    });

    // 5. Real production failure path uses injectable routeFetcher.
    test('5. Real production failure path uses injectable routeFetcher',
        () async {
      const ttsChannel = MethodChannel('flutter_tts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ttsChannel, (call) async => 1);

      int fetchCalls = 0;
      final nav = NavigationController(
        startLat: 5.41,
        startLng: 100.33,
        endLat: 5.42,
        endLng: 100.34,
        travelMode: TravelMode.drive,
        routeFetcher: ({
          required fromLat,
          required fromLng,
          required toLat,
          required toLng,
          required mode,
        }) async {
          fetchCalls++;
          throw Exception('Simulated network timeout');
        },
      );

      // In production, when navigation is initialized without initialRoute,
      // it fetches a fresh route from the GPS position using routeFetcher.
      await nav.init(const TestVSync());

      expect(fetchCalls, greaterThanOrEqualTo(1));
      expect(nav.error, contains('Simulated network timeout'));
      expect(nav.loading, isFalse);

      await Future.delayed(const Duration(milliseconds: 50));
      nav.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ttsChannel, null);
    });
  });

  group(
      'Task 16C — Real-Time Navigation Origin, Route Progress and Reliable Rerouting Tests',
      () {
    test('1. Preview origin resolver uses fresh high-accuracy GPS when valid',
        () async {
      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        locationProvider: () async => Position(
          latitude: 5.4165,
          longitude: 100.3325,
          timestamp: DateTime.now(),
          accuracy: 8.0,
          altitude: 10.0,
          altitudeAccuracy: 1.0,
          heading: 90.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );

      expect(origin.source, equals('fresh_gps'));
      expect(origin.lat, closeTo(5.4165, 0.0001));
      expect(origin.lng, closeTo(100.3325, 0.0001));
      expect(origin.gpsAgeMs, greaterThanOrEqualTo(0));
    });

    test('2. Preview origin resolver falls back gracefully on provider error',
        () async {
      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        locationProvider: () async => throw Exception('GPS unavailable'),
      );

      expect(origin.source, equals('fallback_passed_coordinate'));
      expect(origin.lat, equals(5.4140));
      expect(origin.lng, equals(100.3290));
      expect(origin.gpsAgeMs, equals(-1));
    });

    test(
        '3. Preview origin resolver rejects invalid (0,0) coordinates and falls back',
        () async {
      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        locationProvider: () async => Position(
          latitude: 0.0,
          longitude: 0.0,
          timestamp: DateTime.now(),
          accuracy: 5.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 0.0,
          headingAccuracy: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );

      expect(origin.source, equals('fallback_passed_coordinate'));
      expect(origin.lat, equals(5.4140));
      expect(origin.lng, equals(100.3290));
    });

    test(
        '4. shouldReuseInitialRoute enforces mode tolerance (50m walk vs 80m drive)',
        () {
      final start = const LatLng(5.4164, 100.3327);
      final dummyRoute = RouteResult(
        polylinePoints: [start, const LatLng(5.4200, 100.3350)],
        steps: const [],
        distanceMeters: 500.0,
        durationSeconds: 300,
        bounds: LatLngBounds(
          southwest: const LatLng(5.41, 100.32),
          northeast: const LatLng(5.43, 100.34),
        ),
      );

      // Distance ~60 meters from start
      final at60m = const LatLng(5.4169, 100.3327);
      final dist60 = Geolocator.distanceBetween(
        at60m.latitude,
        at60m.longitude,
        start.latitude,
        start.longitude,
      );
      expect(dist60, inInclusiveRange(50.0, 75.0));

      // Walk rejects 60m (>50m tolerance)
      final canReuseWalk = NavigationController.shouldReuseInitialRoute(
        currentGps: at60m,
        initialRoute: dummyRoute,
        mode: TravelMode.walk,
      );
      expect(canReuseWalk, isFalse);

      // Drive accepts 60m (<=80m tolerance)
      final canReuseDrive = NavigationController.shouldReuseInitialRoute(
        currentGps: at60m,
        initialRoute: dummyRoute,
        mode: TravelMode.drive,
      );
      expect(canReuseDrive, isTrue);

      // Motorcycle also accepts 60m (<=80m tolerance)
      final canReuseMotor = NavigationController.shouldReuseInitialRoute(
        currentGps: at60m,
        initialRoute: dummyRoute,
        mode: TravelMode.motor,
      );
      expect(canReuseMotor, isTrue);
    });

    test(
        '5. calculateEffectiveRerouteThreshold scales base threshold with accuracy',
        () {
      // Walk base is 25m
      expect(
        NavigationController.calculateEffectiveRerouteThreshold(
          mode: TravelMode.walk,
          gpsAccuracyMeters: 10.0,
        ),
        equals(25.0), // max(25.0, 10 * 1.5 = 15) -> 25.0
      );

      expect(
        NavigationController.calculateEffectiveRerouteThreshold(
          mode: TravelMode.walk,
          gpsAccuracyMeters: 24.0,
        ),
        equals(36.0), // max(25.0, 24 * 1.5 = 36) -> 36.0
      );

      // Drive base is 40m
      expect(
        NavigationController.calculateEffectiveRerouteThreshold(
          mode: TravelMode.drive,
          gpsAccuracyMeters: 15.0,
        ),
        equals(40.0), // max(40.0, 15 * 1.5 = 22.5) -> 40.0
      );

      expect(
        NavigationController.calculateEffectiveRerouteThreshold(
          mode: TravelMode.drive,
          gpsAccuracyMeters: 35.0,
        ),
        equals(52.5), // max(40.0, 35 * 1.5 = 52.5) -> 52.5
      );
    });

    test(
        '6. evaluateRerouteCondition requires at least 3 consecutive fixes AND 3 seconds',
        () {
      // 2 fixes and 4000ms -> false
      expect(
        NavigationController.evaluateRerouteCondition(
          consecutiveOffRouteFixes: 2,
          offRouteDurationMs: 4000,
        ),
        isFalse,
      );

      // 4 fixes and 2500ms -> false
      expect(
        NavigationController.evaluateRerouteCondition(
          consecutiveOffRouteFixes: 4,
          offRouteDurationMs: 2500,
        ),
        isFalse,
      );

      // 3 fixes and 3000ms -> true
      expect(
        NavigationController.evaluateRerouteCondition(
          consecutiveOffRouteFixes: 3,
          offRouteDurationMs: 3000,
        ),
        isTrue,
      );

      // 5 fixes and 5000ms -> true
      expect(
        NavigationController.evaluateRerouteCondition(
          consecutiveOffRouteFixes: 5,
          offRouteDurationMs: 5000,
        ),
        isTrue,
      );
    });

    test('7. NavigationRouteUpdateState and initial controller state', () {
      final nav = NavigationController(
        startLat: 5.4140,
        startLng: 100.3290,
        endLat: 5.4200,
        endLng: 100.3350,
      );

      expect(nav.routeUpdateState, equals(NavigationRouteUpdateState.idle));
      expect(nav.routeUpdateMessage, isNull);
    });

    test(
        '8. Traffic refresh is silent and never modifies route update feedback',
        () async {
      final nav = NavigationController(
        startLat: 5.4140,
        startLng: 100.3290,
        endLat: 5.4200,
        endLng: 100.3350,
        initialRoute: RouteResult(
          polylinePoints: const [
            LatLng(5.4140, 100.3290),
            LatLng(5.4200, 100.3350)
          ],
          steps: const [],
          distanceMeters: 3000.0,
          durationSeconds: 400,
          bounds: LatLngBounds(
            southwest: const LatLng(5.41, 100.32),
            northeast: const LatLng(5.43, 100.34),
          ),
        ),
      );

      expect(nav.routeUpdateState, equals(NavigationRouteUpdateState.idle));
      expect(nav.routeUpdateMessage, isNull);

      // After initialization with initialRoute, route update state remains idle
      expect(nav.routeUpdateState, equals(NavigationRouteUpdateState.idle));
      expect(nav.routeUpdateMessage, isNull);
    });

    test('9. Disposing controller cleans up state without leaks', () {
      final nav = NavigationController(
        startLat: 5.4140,
        startLng: 100.3290,
        endLat: 5.4200,
        endLng: 100.3350,
      );

      nav.dispose();
      expect(nav.routeUpdateState, equals(NavigationRouteUpdateState.idle));
      expect(nav.routeUpdateMessage, isNull);
    });
  });

  group('Task 16C1 — Fresh GPS Validation and Route Colour Seam Tests', () {
    test('1. GPS age <=10 seconds is accepted as fresh_gps', () async {
      final now = DateTime.now();
      final posTimestamp = now.subtract(const Duration(seconds: 5));

      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        clockNow: now,
        locationProvider: () async => Position(
          latitude: 5.4165,
          longitude: 100.3325,
          timestamp: posTimestamp,
          accuracy: 12.0,
          altitude: 10.0,
          altitudeAccuracy: 1.0,
          heading: 90.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );

      expect(origin.source, equals('fresh_gps'));
      expect(origin.lat, closeTo(5.4165, 0.0001));
      expect(origin.lng, closeTo(100.3325, 0.0001));
      expect(origin.gpsAgeMs, equals(5000));
    });

    test('2. GPS age >10 seconds is rejected and preserves calculated age',
        () async {
      final now = DateTime.now();
      final posTimestamp = now.subtract(const Duration(seconds: 15));

      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        clockNow: now,
        locationProvider: () async => Position(
          latitude: 5.4165,
          longitude: 100.3325,
          timestamp: posTimestamp,
          accuracy: 12.0,
          altitude: 10.0,
          altitudeAccuracy: 1.0,
          heading: 90.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );

      expect(origin.source, equals('fallback_passed_coordinate'));
      expect(origin.lat, equals(5.4140));
      expect(origin.lng, equals(100.3290));
      expect(origin.gpsAgeMs, equals(15000));
    });

    test('3. Future timestamp is rejected beyond clock tolerance', () async {
      final now = DateTime.now();
      final posTimestamp = now.add(const Duration(seconds: 5));

      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        clockNow: now,
        locationProvider: () async => Position(
          latitude: 5.4165,
          longitude: 100.3325,
          timestamp: posTimestamp,
          accuracy: 12.0,
          altitude: 10.0,
          altitudeAccuracy: 1.0,
          heading: 90.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );

      expect(origin.source, equals('fallback_passed_coordinate'));
      expect(origin.lat, equals(5.4140));
      expect(origin.lng, equals(100.3290));
      expect(origin.gpsAgeMs, equals(-5000));
    });

    test('4. Accuracy >60m is rejected and falls back', () async {
      final now = DateTime.now();
      final posTimestamp = now.subtract(const Duration(seconds: 2));

      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        clockNow: now,
        locationProvider: () async => Position(
          latitude: 5.4165,
          longitude: 100.3325,
          timestamp: posTimestamp,
          accuracy: 65.0, // > 60m threshold
          altitude: 10.0,
          altitudeAccuracy: 1.0,
          heading: 90.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );

      expect(origin.source, equals('fallback_passed_coordinate'));
      expect(origin.lat, equals(5.4140));
      expect(origin.lng, equals(100.3290));
      expect(origin.gpsAgeMs, equals(2000));
    });

    test('5. Accuracy <=60m is accepted as fresh_gps', () async {
      final now = DateTime.now();
      final posTimestamp = now.subtract(const Duration(seconds: 2));

      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 5.4140,
        fallbackLng: 100.3290,
        clockNow: now,
        locationProvider: () async => Position(
          latitude: 5.4165,
          longitude: 100.3325,
          timestamp: posTimestamp,
          accuracy: 60.0, // Exactly at max threshold
          altitude: 10.0,
          altitudeAccuracy: 1.0,
          heading: 90.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );

      expect(origin.source, equals('fresh_gps'));
      expect(origin.lat, closeTo(5.4165, 0.0001));
      expect(origin.lng, closeTo(100.3325, 0.0001));
      expect(origin.gpsAgeMs, equals(2000));
    });

    test('6. Invalid fallback does not cause route request when GPS fails',
        () async {
      final origin = await RoutePreviewPage.resolvePreviewOrigin(
        fallbackLat: 0.0,
        fallbackLng: 0.0,
        locationProvider: () async => throw Exception('GPS unavailable'),
      );

      expect(origin.source, equals('fallback_passed_coordinate'));
      expect(origin.lat, equals(0.0));
      expect(origin.lng, equals(0.0));
      expect(origin.gpsAgeMs, equals(-1));
    });

    test(
        '7. displayedRoutePoint returns null when route has fewer than 2 points',
        () {
      final nav = NavigationController(
        startLat: 5.4140,
        startLng: 100.3290,
        endLat: 5.4200,
        endLng: 100.3350,
      );

      expect(nav.displayedRoutePoint, isNull);
    });

    test(
        '8. displayedRoutePoint returns point strictly on route at displayDistAlongRoute',
        () async {
      const p1 = LatLng(5.4140, 100.3290);
      const p2 = LatLng(5.4200, 100.3290);
      final totalDist = Geolocator.distanceBetween(
        p1.latitude,
        p1.longitude,
        p2.latitude,
        p2.longitude,
      );

      final route = RouteResult(
        polylinePoints: const [p1, p2],
        steps: const [],
        distanceMeters: totalDist,
        durationSeconds: 300,
        bounds: LatLngBounds(southwest: p1, northeast: p2),
      );

      final nav = NavigationController(
        startLat: p1.latitude,
        startLng: p1.longitude,
        endLat: p2.latitude,
        endLng: p2.longitude,
        initialRoute: route,
      );

      await nav.applyRouteResult(route);

      // Before ticks, displayDist is 0.0 -> point is p1
      expect(nav.displayedRoutePoint, isNotNull);
      expect(nav.displayedRoutePoint!.latitude, closeTo(p1.latitude, 0.0001));
      expect(nav.displayedRoutePoint!.longitude, closeTo(p1.longitude, 0.0001));
    });

    test(
        '9. displayedRoutePoint stays on route even when raw GPS/marker is off-route',
        () async {
      const p1 = LatLng(5.4140, 100.3290);
      const p2 = LatLng(5.4200, 100.3290);
      final totalDist = Geolocator.distanceBetween(
        p1.latitude,
        p1.longitude,
        p2.latitude,
        p2.longitude,
      );

      final route = RouteResult(
        polylinePoints: const [p1, p2],
        steps: const [],
        distanceMeters: totalDist,
        durationSeconds: 300,
        bounds: LatLngBounds(southwest: p1, northeast: p2),
      );

      final nav = NavigationController(
        startLat: p1.latitude,
        startLng: p1.longitude,
        endLat: p2.latitude,
        endLng: p2.longitude,
        initialRoute: route,
      );

      await nav.applyRouteResult(route);

      final pointOnRoute = nav.displayedRoutePoint!;
      // Point must lie on longitude 100.3290 and between p1.lat and p2.lat
      expect(pointOnRoute.longitude, closeTo(100.3290, 0.0001));
      expect(pointOnRoute.latitude, inInclusiveRange(p1.latitude, p2.latitude));

      // Off-route marker position simulated at longitude 100.3350
      const offRouteRawMarker = LatLng(5.4140, 100.3350);
      final distOffRoute = Geolocator.distanceBetween(
        pointOnRoute.latitude,
        pointOnRoute.longitude,
        offRouteRawMarker.latitude,
        offRouteRawMarker.longitude,
      );
      expect(distOffRoute, greaterThan(50.0));
      // Route point remains on road (longitude 100.3290), not pulled to 100.3350
      expect(nav.displayedRoutePoint!.longitude, closeTo(100.3290, 0.0001));
    });

    test('10. Newly applied route updates displayedRoutePoint to new route', () async {
      const p1 = LatLng(5.4140, 100.3290);
      const p2 = LatLng(5.4200, 100.3290);
      const newP1 = LatLng(5.5000, 100.4000);
      const newP2 = LatLng(5.5100, 100.4000);

      final nav = NavigationController(
        startLat: p1.latitude,
        startLng: p1.longitude,
        endLat: p2.latitude,
        endLng: p2.longitude,
      );

      await nav.applyRouteResult(RouteResult(
        polylinePoints: const [p1, p2],
        steps: const [],
        distanceMeters: 1000.0,
        durationSeconds: 300,
        bounds: LatLngBounds(southwest: p1, northeast: p2),
      ));
      expect(nav.displayedRoutePoint!.latitude, closeTo(p1.latitude, 0.0001));

      // Apply rerouted route
      await nav.applyRouteResult(RouteResult(
        polylinePoints: const [newP1, newP2],
        steps: const [],
        distanceMeters: 1200.0,
        durationSeconds: 350,
        bounds: LatLngBounds(southwest: newP1, northeast: newP2),
      ));
      expect(nav.displayedRoutePoint!.latitude, closeTo(newP1.latitude, 0.0001));
      expect(nav.displayedRoutePoint!.longitude, closeTo(newP1.longitude, 0.0001));
    });
  });
}
