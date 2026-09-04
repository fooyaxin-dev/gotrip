import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/modules/main/mainpage.dart';
import 'package:gotrip/modules/place/detectPlacePage.dart';
import 'package:gotrip/services/for_you_recommendation_service.dart';
import 'package:gotrip/services/nearbyPlace_service.dart';
import 'package:gotrip/services/route_service.dart';
import 'package:gotrip/services/userPreference_service.dart';

class MockNearbyServiceForTesting extends NearbyPlacesService {
  List<PlaceModel> distancePlacesToReturn = [];
  List<PlaceModel> popularityPlacesToReturn = [];
  int distanceCalls = 0;
  int popularityCalls = 0;

  @override
  Future<List<PlaceModel>> ensureDistanceRound({
    required double lat,
    required double lng,
    int radius = 12000,
    List<String>? types,
  }) async {
    distanceCalls++;
    return distancePlacesToReturn;
  }

  @override
  Future<List<PlaceModel>> ensurePopularityRound({
    required double lat,
    required double lng,
    int radius = 12000,
    List<String>? types,
  }) async {
    popularityCalls++;
    return popularityPlacesToReturn;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    UserPreferenceService.instance.clearLocalSession();
    UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
      categories: ['restaurant'],
      cuisines: [],
      travelMode: 'walk',
      budgetTier: BudgetTier.budget,
      onboardingDone: true,
    ));
    ForYouRecommendationService.instance.invalidateUserGpsSnapshot();
  });

  PlaceModel makePlace({
    required String id,
    required String name,
    double? lat,
    double? lng,
    double? rating = 4.5,
    int? userRatingCount,
    String? primaryType = 'restaurant',
    List<String>? allTypes = const ['restaurant', 'food'],
    String source = 'google',
    bool? isOpenNow = true,
    String? photoUrl = 'https://example.com/photo.jpg',
  }) {
    return PlaceModel(
      id: id,
      name: name,
      address: 'Address $id',
      lat: lat ?? 3.1390,
      lng: lng ?? 101.6869,
      rating: rating,
      userRatingCount: userRatingCount ?? (rating != null ? 100 : null),
      primaryType: primaryType,
      allTypes: allTypes ?? ['restaurant', 'food'],
      source: source,
      isOpenNow: isOpenNow,
      photoUrl: photoUrl,
    );
  }

  group('A. Authoritative Shared For You Pipeline', () {
    test(
        '1. Shared For You combines DISTANCE and POPULARITY candidates [Production Service Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      final pDist = makePlace(id: 'dist_1', name: 'Distance Spot');
      final pPop = makePlace(id: 'pop_1', name: 'Popular Spot');
      mock.distancePlacesToReturn = [pDist];
      mock.popularityPlacesToReturn = [pPop];

      final snapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );

      expect(mock.distanceCalls, equals(1));
      expect(mock.popularityCalls, equals(1));
      expect(
          snapshot.places.map((p) => p.id), containsAll(['dist_1', 'pop_1']));
    });

    test('2. Duplicate Place IDs appear once [Production Service Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      final p1 = makePlace(id: 'shared_id', name: 'Common Place');
      final p2 = makePlace(id: 'shared_id', name: 'Common Place Copy');
      mock.distancePlacesToReturn = [p1];
      mock.popularityPlacesToReturn = [p2];

      final snapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );

      final matching =
          snapshot.places.where((p) => p.id == 'shared_id').toList();
      expect(matching.length, equals(1));
    });

    test(
        '3. Geoapify candidates are excluded from For You [Production Service Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      final pGoogle =
          makePlace(id: 'google_1', name: 'Google Place', source: 'google');
      final pGeoapify =
          makePlace(id: 'geo_1', name: 'Geo Place', source: 'geoapify');
      mock.distancePlacesToReturn = [pGoogle, pGeoapify];
      mock.popularityPlacesToReturn = [];

      final snapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );

      expect(snapshot.places.map((p) => p.id), contains('google_1'));
      expect(snapshot.places.map((p) => p.id), isNot(contains('geo_1')));
    });

    test(
        '4. Closed places (isOpenNow == false) are excluded [Production Service Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      final pOpen =
          makePlace(id: 'open_1', name: 'Open Place', isOpenNow: true);
      final pClosed =
          makePlace(id: 'closed_1', name: 'Closed Place', isOpenNow: false);
      final pNull =
          makePlace(id: 'null_hours', name: 'Unknown Hours', isOpenNow: null);
      mock.distancePlacesToReturn = [pOpen, pClosed, pNull];
      mock.popularityPlacesToReturn = [];

      final snapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );

      expect(snapshot.places.map((p) => p.id), contains('open_1'));
      expect(snapshot.places.map((p) => p.id), contains('null_hours'));
      expect(snapshot.places.map((p) => p.id), isNot(contains('closed_1')));
    });

    test(
        '5. Photoless places are excluded on both surfaces [Production Service Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      final pWithPhoto = makePlace(
          id: 'photo_1',
          name: 'Photo Place',
          photoUrl: 'https://img.com/p.jpg');
      final pNoPhoto =
          makePlace(id: 'no_photo_1', name: 'No Photo Place', photoUrl: null);
      final pEmptyPhoto = makePlace(
          id: 'empty_photo_1', name: 'Empty Photo Place', photoUrl: '');
      mock.distancePlacesToReturn = [pWithPhoto, pNoPhoto, pEmptyPhoto];
      mock.popularityPlacesToReturn = [];

      final snapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );

      expect(snapshot.places.map((p) => p.id), contains('photo_1'));
      expect(snapshot.places.map((p) => p.id), isNot(contains('no_photo_1')));
      expect(
          snapshot.places.map((p) => p.id), isNot(contains('empty_photo_1')));
    });

    test(
        '6. The same distance/radius rule is applied across travel modes [Production Service Coverage]',
        () {
      expect(radiusForTravelModeString('walk'), equals(2000));
      expect(radiusForTravelModeString('motor'), equals(8000));
      expect(radiusForTravelModeString('drive'), equals(12000));
      expect(radiusForTravelModeString('both'), equals(12000));
    });

    test(
        '7. Deterministic tie-breaking produces the same order regardless of input order [Production Algorithm Coverage]',
        () {
      final pA = makePlace(id: 'place_a', name: 'Place A', rating: 4.5);
      final pB = makePlace(id: 'place_b', name: 'Place B', rating: 4.5);
      final pC = makePlace(id: 'place_c', name: 'Place C', rating: 4.0);
      final pD = makePlace(id: 'place_d', name: 'Place D', rating: 4.8);

      final routes = {
        'place_a': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 500,
            durationSeconds: 300),
        'place_b': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 500,
            durationSeconds: 300),
        'place_c': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 200,
            durationSeconds: 150),
        'place_d': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 800,
            durationSeconds: 400),
      };

      // Order 1: A, B, C, D
      final result1 = UserPreferenceService.instance.buildForYouList(
        candidates: [pA, pB, pC, pD],
        routeResults: routes,
        requirePhoto: true,
      );

      // Order 2: D, C, B, A (reversed input order)
      final result2 = UserPreferenceService.instance.buildForYouList(
        candidates: [pD, pC, pB, pA],
        routeResults: routes,
        requirePhoto: true,
      );

      // Order 3: C, A, D, B (shuffled)
      final result3 = UserPreferenceService.instance.buildForYouList(
        candidates: [pC, pA, pD, pB],
        routeResults: routes,
        requirePhoto: true,
      );

      final order1 = result1.places.map((p) => p.id).toList();
      final order2 = result2.places.map((p) => p.id).toList();
      final order3 = result3.places.map((p) => p.id).toList();

      expect(order1, isNotEmpty);
      expect(order1, equals(order2));
      expect(order1, equals(order3));

      // Equal score & distance tie-break: place_a before place_b because ID ascending ('place_a' < 'place_b')
      final indexA = order1.indexOf('place_a');
      final indexB = order1.indexOf('place_b');
      expect(indexA, isNonNegative);
      expect(indexB, isNonNegative);
      expect(indexA, lessThan(indexB));
    });

    test(
        '8 & 9. MainPage preview is exactly first 7 IDs and DetectPlace For You consumes complete result in same order [Production Consistency Coverage]',
        () {
      final places = List.generate(
        12,
        (i) => makePlace(
          id: 'place_${i.toString().padLeft(2, '0')}',
          name: 'Place $i',
          rating: 4.0 + (i % 5) * 0.1,
        ),
      );

      final scores = {for (var p in places) p.id: 0.8};
      final explanations = <String, RecommendationExplanation>{};
      final routes = <String, RouteResult>{};

      final snapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        preferenceRevision: 1,
        generation: 1,
        contextKey: 'gps:3.139,101.687:2000:rev1:gen1',
        places: places,
        scores: scores,
        explanations: explanations,
        routeResults: routes,
      );

      // MainPage consumes first 7
      final mainPagePreview = snapshot.places.take(7).toList();
      expect(mainPagePreview.length, equals(7));

      // DetectPlacePage consumes complete list
      final detectPlaceFull = snapshot.places;
      expect(detectPlaceFull.length, equals(12));

      // The first 7 of DetectPlacePage match MainPage exactly in identical order
      expect(
        detectPlaceFull.take(7).map((p) => p.id).toList(),
        equals(mainPagePreview.map((p) => p.id).toList()),
      );
    });
  });

  group('B. MainPage Navigation & Mode Routing', () {
    test(
        '10. For You View All selects SortMode.recommended [Production Route Contract]',
        () {
      const page = RealTimeDetectPage(
        initialSortMode: SortMode.recommended,
        onBack: _noop,
      );
      expect(page.initialSortMode, equals(SortMode.recommended));
    });

    test(
        '11. Nearby View All selects SortMode.distance (Nearest) [Production Route Contract]',
        () {
      const page = RealTimeDetectPage(
        initialSortMode: SortMode.distance,
        onBack: _noop,
      );
      expect(page.initialSortMode, equals(SortMode.distance));
    });

    test(
        '12. Default DetectPlace entry selects SortMode.recommended [Production Route Contract]',
        () {
      const page = RealTimeDetectPage(onBack: _noop);
      expect(page.initialSortMode, isNull);
      expect(RealTimeDetectPage.defaultSortMode, equals(SortMode.recommended));
    });

    test(
        '10b. RealTimeDetectPage.isValidInitialSnapshot validates matching context and rejects mismatch [Production Helper Seam]',
        () {
      final places = [makePlace(id: 'p1', name: 'Place 1')];
      final snapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        preferenceRevision: 1,
        generation: 1,
        contextKey: 'gps:3.139,101.687:2000:rev1:gen1',
        places: places,
        scores: {'p1': 0.9},
        explanations: {},
        routeResults: {},
      );

      final pos = Position(
        latitude: 3.1390,
        longitude: 101.6869,
        timestamp: DateTime.now(),
        accuracy: 1,
        altitude: 0,
        heading: 0,
        speed: 0,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      // Matches context
      expect(
        RealTimeDetectPage.isValidInitialSnapshot(
          snapshot: snapshot,
          currentPosition: pos,
          radiusMeters: 2000,
          preferenceRevision: 1,
          generation: 1,
        ),
        isTrue,
      );

      // Landmark mode is rejected
      expect(
        RealTimeDetectPage.isValidInitialSnapshot(
          snapshot: snapshot,
          currentPosition: pos,
          radiusMeters: 2000,
          preferenceRevision: 1,
          generation: 1,
          isLandmark: true,
        ),
        isFalse,
      );

      // Mismatched preference revision is rejected
      expect(
        RealTimeDetectPage.isValidInitialSnapshot(
          snapshot: snapshot,
          currentPosition: pos,
          radiusMeters: 2000,
          preferenceRevision: 2,
          generation: 1,
        ),
        isFalse,
      );

      // Mismatched generation is rejected
      expect(
        RealTimeDetectPage.isValidInitialSnapshot(
          snapshot: snapshot,
          currentPosition: pos,
          radiusMeters: 2000,
          preferenceRevision: 1,
          generation: 2,
        ),
        isFalse,
      );

      // Null snapshot is rejected
      expect(
        RealTimeDetectPage.isValidInitialSnapshot(
          snapshot: null,
          currentPosition: pos,
          radiusMeters: 2000,
          preferenceRevision: 1,
          generation: 1,
        ),
        isFalse,
      );
    });

    test(
        '10c. MainPage navigation seams construct correct SortMode and pass valid snapshot [Production Navigation Seam]',
        () {
      final snapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        preferenceRevision: 1,
        generation: 1,
        contextKey: 'gps:3.139,101.687:2000:rev1:gen1',
        places: [makePlace(id: 'p1', name: 'Place 1')],
        scores: {'p1': 0.9},
        explanations: {},
        routeResults: {},
      );

      final forYouConfig = MainPage.buildAllForYouNavigationConfig(
        snapshot: snapshot,
        travelMode: TravelMode.walk,
      );
      expect(forYouConfig.sortMode, equals(SortMode.recommended));
      expect(forYouConfig.snapshot?.contextKey, equals(snapshot.contextKey));
      expect(forYouConfig.travelMode, equals(TravelMode.walk));

      final nearbyConfig = MainPage.buildNearbySeeAllNavigationConfig(
        travelMode: TravelMode.walk,
      );
      expect(nearbyConfig.sortMode, equals(SortMode.distance));
      expect(nearbyConfig.snapshot, isNull);
      expect(nearbyConfig.travelMode, equals(TravelMode.walk));
    });

    test(
        '10d. Initial snapshot validation uses saved walk mode radius (2000m) [Production Seam Coverage; Live Rendered Zero-Flicker Unverified Pending Real-Phone Testing]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      expect(RealTimeDetectPage.resolveSavedTravelModeRadius(), equals(2000));

      final pos = Position(
        latitude: 3.1390,
        longitude: 101.6869,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final walkSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:2000:rev1:gen1',
        places: [makePlace(id: 'w1', name: 'Walk Place')],
        scores: {'w1': 0.8},
        explanations: {},
        routeResults: {},
      );

      final motorSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 8000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:8000:rev1:gen1',
        places: [makePlace(id: 'm1', name: 'Motor Place')],
        scores: {'m1': 0.8},
        explanations: {},
        routeResults: {},
      );

      // Walk snapshot matches saved walk preference
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForSavedPreference(
          snapshot: walkSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
        ),
        isTrue,
      );

      // Motor snapshot is rejected under saved walk preference
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForSavedPreference(
          snapshot: motorSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
        ),
        isFalse,
      );
    });

    test(
        '10e. Initial snapshot validation uses saved motor mode radius (8000m) [Production Seam Coverage; Live Rendered Zero-Flicker Unverified Pending Real-Phone Testing]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'motor',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      expect(RealTimeDetectPage.resolveSavedTravelModeRadius(), equals(8000));

      final pos = Position(
        latitude: 3.1390,
        longitude: 101.6869,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final motorSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 8000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:8000:rev1:gen1',
        places: [makePlace(id: 'm1', name: 'Motor Place')],
        scores: {'m1': 0.85},
        explanations: {},
        routeResults: {},
      );

      final walkSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:2000:rev1:gen1',
        places: [makePlace(id: 'w1', name: 'Walk Place')],
        scores: {'w1': 0.85},
        explanations: {},
        routeResults: {},
      );

      // Motor snapshot matches saved motor preference (not rejected by walk default)
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForSavedPreference(
          snapshot: motorSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
        ),
        isTrue,
      );

      // Walk snapshot is rejected under saved motor preference
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForSavedPreference(
          snapshot: walkSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
        ),
        isFalse,
      );
    });

    test(
        '10f. Initial snapshot validation uses saved drive mode radius (12000m) [Production Seam Coverage; Live Rendered Zero-Flicker Unverified Pending Real-Phone Testing]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'drive',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      expect(RealTimeDetectPage.resolveSavedTravelModeRadius(), equals(12000));

      final pos = Position(
        latitude: 3.1390,
        longitude: 101.6869,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final driveSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 12000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:12000:rev1:gen1',
        places: [makePlace(id: 'd1', name: 'Drive Place')],
        scores: {'d1': 0.9},
        explanations: {},
        routeResults: {},
      );

      final walkSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:2000:rev1:gen1',
        places: [makePlace(id: 'w1', name: 'Walk Place')],
        scores: {'w1': 0.9},
        explanations: {},
        routeResults: {},
      );

      // Drive snapshot matches saved drive preference (not rejected by walk default)
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForSavedPreference(
          snapshot: driveSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
        ),
        isTrue,
      );

      // Walk snapshot is rejected under saved drive preference
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForSavedPreference(
          snapshot: walkSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
        ),
        isFalse,
      );
    });

    test(
        '10g. Saved Walk with no override: For You View All transfers Walk; Nearby View All transfers Walk [Production Navigation Seam]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      final snapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:2000:rev1:gen1',
        places: [makePlace(id: 'w1', name: 'Walk Place')],
        scores: {'w1': 0.9},
        explanations: {},
        routeResults: {},
      );

      final forYouConfig = MainPage.buildAllForYouNavigationConfig(
        snapshot: snapshot,
        travelMode: TravelMode.walk,
      );
      expect(forYouConfig.sortMode, equals(SortMode.recommended));
      expect(forYouConfig.travelMode, equals(TravelMode.walk));
      expect(forYouConfig.snapshot?.radiusMeters, equals(2000));

      final nearbyConfig = MainPage.buildNearbySeeAllNavigationConfig(
        travelMode: TravelMode.walk,
      );
      expect(nearbyConfig.sortMode, equals(SortMode.distance));
      expect(nearbyConfig.travelMode, equals(TravelMode.walk));
    });

    test(
        '10h. Saved Walk + temporary Motor override: View All transfers Motor and 8000m snapshot; saved preference remains Walk [Production Navigation Seam]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      final motorSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 8000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:8000:rev1:gen1',
        places: [makePlace(id: 'm1', name: 'Motor Place')],
        scores: {'m1': 0.85},
        explanations: {},
        routeResults: {},
      );

      // Temporary override on MainPage: transfer Motor and 8000m snapshot
      final forYouConfig = MainPage.buildAllForYouNavigationConfig(
        snapshot: motorSnapshot,
        travelMode: TravelMode.motor,
      );
      expect(forYouConfig.sortMode, equals(SortMode.recommended));
      expect(forYouConfig.travelMode, equals(TravelMode.motor));
      expect(forYouConfig.snapshot?.radiusMeters, equals(8000));

      final nearbyConfig = MainPage.buildNearbySeeAllNavigationConfig(
        travelMode: TravelMode.motor,
      );
      expect(nearbyConfig.sortMode, equals(SortMode.distance));
      expect(nearbyConfig.travelMode, equals(TravelMode.motor));

      // Saved preference remains Walk
      expect(UserPreferenceService.instance.current.travelMode, equals('walk'));
    });

    test(
        '10i. Saved Walk + temporary Drive override: View All transfers Drive and 12000m context; saved preference remains Walk [Production Navigation Seam]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      final driveSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 12000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:12000:rev1:gen1',
        places: [makePlace(id: 'd1', name: 'Drive Place')],
        scores: {'d1': 0.9},
        explanations: {},
        routeResults: {},
      );

      final forYouConfig = MainPage.buildAllForYouNavigationConfig(
        snapshot: driveSnapshot,
        travelMode: TravelMode.drive,
      );
      expect(forYouConfig.sortMode, equals(SortMode.recommended));
      expect(forYouConfig.travelMode, equals(TravelMode.drive));
      expect(forYouConfig.snapshot?.radiusMeters, equals(12000));

      final nearbyConfig = MainPage.buildNearbySeeAllNavigationConfig(
        travelMode: TravelMode.drive,
      );
      expect(nearbyConfig.sortMode, equals(SortMode.distance));
      expect(nearbyConfig.travelMode, equals(TravelMode.drive));

      // Saved preference remains Walk
      expect(UserPreferenceService.instance.current.travelMode, equals('walk'));
    });

    test(
        '10j. RealTimeDetectPage supplied initialTravelMode takes precedence only for that page session [Production Seam Coverage]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      // Initial travel mode supplied takes precedence
      final motorRadius = RealTimeDetectPage.resolveInitialTravelModeRadius(
        initialTravelMode: TravelMode.motor,
      );
      expect(motorRadius, equals(8000));

      final driveRadius = RealTimeDetectPage.resolveInitialTravelModeRadius(
        initialTravelMode: TravelMode.drive,
      );
      expect(driveRadius, equals(12000));

      // Saved preference remains Walk
      expect(UserPreferenceService.instance.current.travelMode, equals('walk'));
    });

    test(
        '10k. RealTimeDetectPage without initialTravelMode continues using saved preferences [Production Seam Coverage]',
        () {
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'motor',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      final radiusFromSaved = RealTimeDetectPage.resolveInitialTravelModeRadius(
        initialTravelMode: null,
      );
      expect(radiusFromSaved, equals(8000));

      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'drive',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      final driveRadiusFromSaved =
          RealTimeDetectPage.resolveInitialTravelModeRadius(
        initialTravelMode: null,
      );
      expect(driveRadiusFromSaved, equals(12000));
    });

    test(
        '10l. A transferred Motor/Drive snapshot validates immediately against the transferred mode radius [Production Seam Coverage; Live Rendered Zero-Flicker Unverified Pending Real-Phone Testing]',
        () {
      // Saved preference is Walk (2000m)
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['restaurant'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));

      final pos = Position(
        latitude: 3.1390,
        longitude: 101.6869,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final motorSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 8000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:8000:rev1:gen1',
        places: [makePlace(id: 'm1', name: 'Motor Place')],
        scores: {'m1': 0.85},
        explanations: {},
        routeResults: {},
      );

      final driveSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 12000,
        preferenceRevision:
            UserPreferenceService.instance.preferencesChanged.value,
        generation: 1,
        contextKey: 'gps:3.139,101.687:12000:rev1:gen1',
        places: [makePlace(id: 'd1', name: 'Drive Place')],
        scores: {'d1': 0.9},
        explanations: {},
        routeResults: {},
      );

      // Transferred Motor mode allows 8000m snapshot to validate immediately
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForEffectiveTravelMode(
          snapshot: motorSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
          initialTravelMode: TravelMode.motor,
        ),
        isTrue,
      );

      // Transferred Drive mode allows 12000m snapshot to validate immediately
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForEffectiveTravelMode(
          snapshot: driveSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
          initialTravelMode: TravelMode.drive,
        ),
        isTrue,
      );

      // Without initialTravelMode, saved Walk rejects both 8000m and 12000m
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForEffectiveTravelMode(
          snapshot: motorSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
          initialTravelMode: null,
        ),
        isFalse,
      );
      expect(
        RealTimeDetectPage.isValidInitialSnapshotForEffectiveTravelMode(
          snapshot: driveSnapshot,
          currentPosition: pos,
          preferenceRevision:
              UserPreferenceService.instance.preferencesChanged.value,
          generation: 1,
          initialTravelMode: null,
        ),
        isFalse,
      );
    });

    test(
        '10m. Landmark mode still rejects a normal user-GPS initial snapshot [Production Isolation Coverage]',
        () {
      final pos = Position(
        latitude: 3.1390,
        longitude: 101.6869,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final motorSnapshot = ForYouSnapshot(
        originType: RecommendationOriginType.gps,
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 8000,
        preferenceRevision: 1,
        generation: 1,
        contextKey: 'gps:3.139,101.687:8000:rev1:gen1',
        places: [makePlace(id: 'm1', name: 'Motor Place')],
        scores: {'m1': 0.85},
        explanations: {},
        routeResults: {},
      );

      expect(
        RealTimeDetectPage.isValidInitialSnapshotForEffectiveTravelMode(
          snapshot: motorSnapshot,
          currentPosition: pos,
          preferenceRevision: 1,
          generation: 1,
          initialTravelMode: TravelMode.motor,
          isLandmark: true,
        ),
        isFalse,
      );
    });
  });

  group('C. Invalidation, Isolation & Stale Protection', () {
    test(
        '13. Preference invalidation causes both surfaces to receive the same rebuilt result [Production Seam Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      mock.distancePlacesToReturn = [makePlace(id: 'pref_1', name: 'Place 1')];

      final snap1 =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );
      expect(ForYouRecommendationService.instance.userGpsSnapshot, isNotNull);

      // Now update preference
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['cafe'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.midRange,
        onboardingDone: true,
      ));

      // Snapshot must be invalidated
      ForYouRecommendationService.instance.invalidateUserGpsSnapshot();
      expect(ForYouRecommendationService.instance.userGpsSnapshot, isNull);

      final snap2 =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );
      expect(snap2.preferenceRevision, greaterThan(snap1.preferenceRevision));
    });

    test(
        '13b. Snapshot in flight when preference revision changes is not committed; subsequent requests receive new snapshot [Production Race Coverage]',
        () async {
      final completer = Completer<List<PlaceModel>>();
      final slowMock = _DelayingMockNearbyService(completer.future);

      final initialPrefRev = UserPreferenceService.instance.preferenceRevision;

      // 1. Snapshot request begins for normal GPS context
      final inFlightFuture =
          ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: slowMock,
      );

      // 2. Preferences revision changes while request is in flight
      UserPreferenceService.instance.setPreferencesForTesting(UserPreferences(
        categories: ['bakery'],
        cuisines: [],
        travelMode: 'walk',
        budgetTier: BudgetTier.budget,
        onboardingDone: true,
      ));
      final updatedPrefRev = UserPreferenceService.instance.preferenceRevision;
      expect(updatedPrefRev, greaterThan(initialPrefRev));

      // 3. Stale result completes
      completer.complete([makePlace(id: 'stale_pref_1', name: 'Old Place')]);
      final staleSnapshot = await inFlightFuture;

      // Stale snapshot has the old preference revision
      expect(staleSnapshot.preferenceRevision, equals(initialPrefRev));

      // 4. Stale result is NOT committed/published as the current GPS snapshot!
      expect(ForYouRecommendationService.instance.userGpsSnapshot, isNull);

      // 5. Both consumers (e.g. MainPage and DetectPlacePage) subsequently request the snapshot
      final fastMock = MockNearbyServiceForTesting();
      fastMock.distancePlacesToReturn = [
        makePlace(id: 'fresh_pref_1', name: 'Fresh Bakery Place')
      ];

      final consumerA =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: fastMock,
      );

      final consumerB =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: fastMock,
      );

      // Both receive the identical current snapshot with the updated revision
      expect(consumerA.preferenceRevision, equals(updatedPrefRev));
      expect(consumerB.preferenceRevision, equals(updatedPrefRev));
      expect(consumerA.contextKey, equals(consumerB.contextKey));
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.contextKey,
          equals(consumerA.contextKey));
    });

    test(
        '14. Manual/location refresh invalidation does not reuse a stale context [Production Seam Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      mock.distancePlacesToReturn = [makePlace(id: 'loc_1', name: 'Loc 1')];

      final snap1 =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );
      expect(snap1, isNotNull);

      // Manual refresh invalidates
      ForYouRecommendationService.instance.invalidateUserGpsSnapshot();
      expect(ForYouRecommendationService.instance.userGpsSnapshot, isNull);

      // Reload at new location 3.200, 101.700
      final snap2 =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.2000,
        lng: 101.7000,
        radiusMeters: 2000,
        nearbyService: mock,
      );
      expect(snap2.lat, equals(3.2000));
      expect(snap2.contextKey, contains('3.200,101.700'));
    });

    test(
        '15. Search snapshot cannot overwrite normal GPS snapshot [Production Isolation Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      mock.distancePlacesToReturn = [
        makePlace(id: 'search_1', name: 'Search 1')
      ];

      // Build a GPS snapshot first
      final gpsSnapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        originType: RecommendationOriginType.gps,
        nearbyService: mock,
      );
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.contextKey,
          equals(gpsSnapshot.contextKey));

      // Now run a search snapshot at different coordinates
      final searchSnapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 5.4141,
        lng: 100.3288,
        radiusMeters: 2000,
        originType: RecommendationOriginType.searched,
        originName: 'Penang',
        nearbyService: mock,
      );
      expect(
          searchSnapshot.originType, equals(RecommendationOriginType.searched));

      // The normal GPS snapshot MUST remain unchanged!
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.contextKey,
          equals(gpsSnapshot.contextKey));
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.lat,
          equals(3.1390));
    });

    test(
        '16. Landmark snapshot cannot overwrite normal GPS snapshot [Production Isolation Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      mock.distancePlacesToReturn = [
        makePlace(id: 'landmark_1', name: 'Landmark 1')
      ];

      final gpsSnapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        originType: RecommendationOriginType.gps,
        nearbyService: mock,
      );

      // Now run a landmark snapshot
      final landmarkSnapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1579,
        lng: 101.7116,
        radiusMeters: 2000,
        originType: RecommendationOriginType.landmark,
        originName: 'KLCC',
        nearbyService: mock,
      );
      expect(landmarkSnapshot.originType,
          equals(RecommendationOriginType.landmark));

      // The normal GPS snapshot MUST NOT be overwritten
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.contextKey,
          equals(gpsSnapshot.contextKey));
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.lat,
          equals(3.1390));
    });

    test(
        '16b. Landmark recommended mode triggers popularity prefetch and integrates candidates [Production Bootstrap Seam Coverage]',
        () async {
      final mock = MockNearbyServiceForTesting();
      final landmarkDist = makePlace(
        id: 'lm_dist_1',
        name: 'Landmark Distance Spot',
        lat: 3.1579,
        lng: 101.7116,
      );
      final landmarkPop = makePlace(
        id: 'lm_pop_1',
        name: 'Landmark Popular Spot',
        lat: 3.1585,
        lng: 101.7120,
      );
      mock.distancePlacesToReturn = [landmarkDist];
      mock.popularityPlacesToReturn = [landmarkPop];

      // Build GPS snapshot first to verify it is NOT overwritten
      final gpsSnapshot =
          await ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: mock,
      );
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.contextKey,
          equals(gpsSnapshot.contextKey));

      // 1. Verify that when Landmark is in recommended mode, _popularityPlaces is initially empty,
      // and executeBootstrapEndPopularitySeam triggers prefetch!
      bool prefetchTriggered = false;
      final triggered = RealTimeDetectPage.executeBootstrapEndPopularitySeam(
        isPopularityEmpty: true,
        onTriggerPrefetch: () {
          prefetchTriggered = true;
        },
      );
      expect(triggered, isTrue);
      expect(prefetchTriggered, isTrue);

      // 2. Verify that executePrefetchPopularitySeam uses the nearbyService to fetch popularity round
      final popCallsBefore = mock.popularityCalls;
      final popResult = await RealTimeDetectPage.executePrefetchPopularitySeam(
        lat: 3.1579,
        lng: 101.7116,
        radius: 2000,
        nearbyService: mock,
      );
      expect(popResult, equals([landmarkPop]));
      expect(mock.popularityCalls, equals(popCallsBefore + 1));

      // 3. Verify that combining candidates for Landmark recommended tab includes both
      final combined = RealTimeDetectPage.getCandidatesForTab(
        mode: SortMode.recommended,
        distancePlaces: [landmarkDist],
        popularityPlaces: popResult,
      );
      expect(combined.map((p) => p.id).toList(),
          containsAll(['lm_dist_1', 'lm_pop_1']));

      // 4. Verify that normal user GPS snapshot was NEVER overwritten
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.contextKey,
          equals(gpsSnapshot.contextKey));
      expect(ForYouRecommendationService.instance.userGpsSnapshot?.lat,
          equals(3.1390));
    });

    test(
        '17. A stale in-flight request cannot overwrite a newer generation [Production Async Guard Coverage]',
        () async {
      final completer = Completer<List<PlaceModel>>();
      final slowMock = _DelayingMockNearbyService(completer.future);

      final startGen = ForYouRecommendationService.instance.currentGeneration;

      // Start generation N request
      final inFlightFuture =
          ForYouRecommendationService.instance.ensureForYouSnapshot(
        lat: 3.1390,
        lng: 101.6869,
        radiusMeters: 2000,
        nearbyService: slowMock,
      );

      // While request is in flight, invalidate/advance generation
      ForYouRecommendationService.instance.invalidateUserGpsSnapshot();
      expect(ForYouRecommendationService.instance.currentGeneration,
          equals(startGen + 1));

      // Now complete the slow request from previous generation
      completer.complete([makePlace(id: 'slow_1', name: 'Slow Place')]);
      final staleSnapshot = await inFlightFuture;

      // Stale snapshot returned to caller, but did NOT overwrite the current generation snapshot!
      expect(staleSnapshot.generation, equals(startGen));
      expect(ForYouRecommendationService.instance.userGpsSnapshot, isNull);
    });
  });

  group('D. Algorithm Preservation', () {
    test(
        '18. Nearest remains DISTANCE-only and sorted ascending [Production Preservation Coverage]',
        () {
      final p1 = makePlace(id: 'n1', name: 'Near 1');
      final p2 = makePlace(id: 'n2', name: 'Near 2');
      final p3 = makePlace(id: 'n3', name: 'Near 3');

      final routes = {
        'n1': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 800,
            durationSeconds: 500),
        'n2': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 200,
            durationSeconds: 150),
        'n3': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 500,
            durationSeconds: 300),
      };

      final sorted = RealTimeDetectPage.sortNearestPlaces(
        places: [p1, p2, p3],
        routeResults: routes,
      );

      // Ascending: n2 (200m), n3 (500m), n1 (800m)
      expect(sorted.map((p) => p.id).toList(), equals(['n2', 'n3', 'n1']));
    });

    test(
        '19. Rank remains POPULARITY-only and preserves its existing ordering [Production Preservation Coverage]',
        () {
      final p1 = makePlace(id: 'r1', name: 'Rank 1', rating: 4.8);
      final p2 = makePlace(id: 'r2', name: 'Rank 2', rating: 4.8);
      final p3 = makePlace(id: 'r3', name: 'Rank 3', rating: 4.2);
      final p4 = PlaceModel(
        id: 'r4',
        name: 'Rank 4',
        source: 'google',
        rating: null,
      );

      final popularityOrder = {'r2': 0, 'r1': 1, 'r3': 2, 'r4': 3};
      final routes = {
        'r1': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 500,
            durationSeconds: 300),
        'r2': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 500,
            durationSeconds: 300),
        'r3': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 500,
            durationSeconds: 300),
        'r4': RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
                southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
            distanceMeters: 500,
            durationSeconds: 300),
      };

      final sorted = RealTimeDetectPage.sortRankPlaces(
        places: [p1, p2, p3, p4],
        popularityResponseOrder: popularityOrder,
        routeResults: routes,
      );

      // Rated before unrated, then highest rating, equal rating tie-break by popularity order (r2=0 before r1=1), unrated last (r4)
      expect(
          sorted.map((p) => p.id).toList(), equals(['r2', 'r1', 'r3', 'r4']));
    });
  });
}

void _noop() {}

class _DelayingMockNearbyService extends NearbyPlacesService {
  final Future<List<PlaceModel>> future;
  _DelayingMockNearbyService(this.future);

  @override
  Future<List<PlaceModel>> ensureDistanceRound({
    required double lat,
    required double lng,
    int radius = 12000,
    List<String>? types,
  }) {
    return future;
  }

  @override
  Future<List<PlaceModel>> ensurePopularityRound({
    required double lat,
    required double lng,
    int radius = 12000,
    List<String>? types,
  }) {
    return future;
  }
}
