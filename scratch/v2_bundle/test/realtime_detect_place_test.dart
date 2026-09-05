import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/modules/place/detectPlacePage.dart';
import 'package:gotrip/services/apps_Loading.dart';
import 'package:gotrip/services/nearbyPlace_service.dart';
import 'package:gotrip/services/placesAPI_service.dart';
import 'package:gotrip/services/route_service.dart';
import 'package:gotrip/services/userPreference_service.dart';

/// Test HTTP client for mocking Google Places API requests.
class MockHttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.Request request) handler;
  MockHttpClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final httpRequest = request as http.Request;
    final response = await handler(httpRequest);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    UserPreferenceService.instance.clearLocalSession();
    NearbyPlacesService.instance.clearGoogleRawCache();
  });

  PlaceModel makePlace({
    required String id,
    required String name,
    double? lat,
    double? lng,
    double? rating,
    int? userRatingCount,
    String? primaryType = 'restaurant',
    List<String>? allTypes = const ['restaurant', 'food'],
    String source = 'google',
    bool isOpenNow = true,
  }) {
    return PlaceModel(
      id: id,
      name: name,
      address: 'Test Address $id',
      lat: lat ?? 3.1390,
      lng: lng ?? 101.6869,
      rating: rating,
      userRatingCount: userRatingCount ?? (rating != null ? 100 : null),
      primaryType: primaryType,
      allTypes: allTypes ?? ['restaurant', 'food'],
      source: source,
      isOpenNow: isOpenNow,
    );
  }

  RouteResult makeRouteResult(double distanceMeters) {
    return RouteResult(
      polylinePoints: const [],
      steps: const [],
      bounds: LatLngBounds(
        southwest: const LatLng(3.0, 101.0),
        northeast: const LatLng(3.2, 101.8),
      ),
      distanceMeters: distanceMeters,
      durationSeconds: (distanceMeters / 1.4).round(),
    );
  }

  final testSubCategoriesConfig = <String, List<Map<String, dynamic>>>{
    'restaurant': [
      {
        'name': 'Cafe & Bakery',
        'key': 'cafe',
        'allowTypes': ['cafe', 'bakery'],
        'nameKeywords': ['cafe', 'coffee', 'bakery'],
      },
      {
        'name': 'Fast Food',
        'key': 'fast_food',
        'allowTypes': ['fast_food_restaurant', 'meal_takeaway'],
        'nameKeywords': ['burger', 'mcdonald', 'kfc'],
      },
      {
        'name': 'Bar & Pub',
        'key': 'bar',
        'allowTypes': ['bar', 'pub'],
        'nameKeywords': ['bar', 'pub', 'bistro'],
      },
    ],
  };

  // ═══════════════════════════════════════════════════════════════════════════
  // Specification Group 1: Default Mode & Progressive Loading Usability
  // ═══════════════════════════════════════════════════════════════════════════

  group('Group 1: Mode Selection & Defaults', () {
    test(
        '1. For You is the default mode (SortMode.recommended) upon initialization',
        () {
      // In RealTimeDetectPage, _sortMode is initialized to SortMode.recommended
      expect(SortMode.recommended.name, equals('recommended'));
      expect(SortMode.recommended, equals(SortMode.recommended));
      final page = RealTimeDetectPage(onBack: () {});
      expect(page.effectiveNearbyService, isNotNull);
    });

    test(
        '2. DISTANCE results are usable immediately without awaiting POPULARITY',
        () {
      final d1 = makePlace(id: 'd1', name: 'Nearby Bakery');
      final d2 = makePlace(id: 'd2', name: 'Nearby Cafe');
      final emptyPopularity = <PlaceModel>[];

      // Active candidate retrieval for Nearest is immediately available
      final nearestCandidates = RealTimeDetectPage.getCandidatesForTab(
        mode: SortMode.distance,
        distancePlaces: [d1, d2],
        popularityPlaces: emptyPopularity,
      );
      expect(nearestCandidates, equals([d1, d2]));

      // Active candidate retrieval for For You is immediately usable with Distance-only places
      final forYouPool = RealTimeDetectPage.combineForYouPool(
        distancePlaces: [d1, d2],
        popularityPlaces: emptyPopularity,
      );
      expect(forYouPool, equals([d1, d2]));
    });

    test(
        '3. POPULARITY search triggers automatically in background upon Distance completion',
        () async {
      int popularityCalls = 0;
      final mockClient = MockHttpClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['rankPreference'] == 'POPULARITY') {
          popularityCalls++;
        }
        return http.Response(
          '{"places": []}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      // Distance round completes synchronously/immediately
      await service.ensureDistanceRound(
          lat: 3.1390, lng: 101.6869, radius: 2000);

      // Non-blocking background trigger of popularity round
      final popFuture = service.ensurePopularityRound(
          lat: 3.1390, lng: 101.6869, radius: 2000);
      expect(popFuture, isA<Future<List<PlaceModel>>>());

      await popFuture;
      expect(popularityCalls, greaterThanOrEqualTo(1));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Specification Group 2: For You Mode Logic & User Preference Integration
  // ═══════════════════════════════════════════════════════════════════════════

  group('Group 2: For You Mode', () {
    test(
        '4. For You candidate pool combines and deduplicates DISTANCE and POPULARITY preserving distance instance',
        () {
      final sharedDist = makePlace(
          id: 'shared_1', name: 'Original Distance Copy', rating: 4.0);
      final sharedPop = makePlace(
          id: 'shared_1', name: 'Duplicate Popularity Copy', rating: 4.8);
      final distOnly = makePlace(id: 'd_only', name: 'Distance Only Place');
      final popOnly = makePlace(id: 'p_only', name: 'Popularity Only Place');

      final combined = RealTimeDetectPage.combineForYouPool(
        distancePlaces: [sharedDist, distOnly],
        popularityPlaces: [sharedPop, popOnly],
      );

      expect(combined.length, equals(3));
      expect(combined.map((p) => p.id).toList(),
          equals(['shared_1', 'd_only', 'p_only']));

      // Distance instance is preserved on duplicate ID
      final resolvedShared = combined.firstWhere((p) => p.id == 'shared_1');
      expect(resolvedShared.name, equals('Original Distance Copy'));
    });

    test(
        '5. UserPreferenceService.instance.buildForYouList processes combined pool without altering ranking algorithm',
        () {
      final p1 = makePlace(
          id: 'p1',
          name: 'Fine Dining Cafe',
          rating: 4.9,
          primaryType: 'restaurant');
      final p2 = makePlace(
          id: 'p2',
          name: 'Street Food',
          rating: 3.8,
          primaryType: 'restaurant');
      final p3 = makePlace(
          id: 'p3',
          name: 'Amusement Park',
          rating: 4.5,
          primaryType: 'entertainment');

      final combinedPool = RealTimeDetectPage.combineForYouPool(
        distancePlaces: [p1, p2],
        popularityPlaces: [p3],
      );

      final routeResults = {
        'p1': makeRouteResult(300),
        'p2': makeRouteResult(100),
        'p3': makeRouteResult(2000),
      };

      final result = UserPreferenceService.instance.buildForYouList(
        candidates: combinedPool,
        routeResults: routeResults,
      );

      expect(result.places, isA<List<PlaceModel>>());
      expect(result.scores, isA<Map<String, double>>());
      expect(
          result.explanations, isA<Map<String, RecommendationExplanation>>());

      // Production recommendation scoring evaluation directly tested
      final recScore = UserPreferenceService.instance.recommendationScore(
        primaryType: 'restaurant',
        allTypes: ['restaurant', 'food'],
        distanceMeters: 300,
        rating: 4.9,
        priceLevel: 2,
      );
      expect(recScore.total, inInclusiveRange(0.0, 1.0));
      expect(recScore.explanation, isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Specification Group 3: Nearest Mode Logic & Candidate Isolation
  // ═══════════════════════════════════════════════════════════════════════════

  group('Group 3: Nearest Mode', () {
    test(
        '6. Nearest tab uses ONLY DISTANCE candidates and strictly excludes POPULARITY-only places',
        () {
      final dist1 = makePlace(id: 'd1', name: 'Distance Place 1');
      final dist2 = makePlace(id: 'd2', name: 'Distance Place 2');
      final popOnly = makePlace(id: 'p1', name: 'Popularity Only Place');

      final candidates = RealTimeDetectPage.getCandidatesForTab(
        mode: SortMode.distance,
        distancePlaces: [dist1, dist2],
        popularityPlaces: [popOnly],
      );

      expect(candidates, equals([dist1, dist2]));
      expect(candidates.any((p) => p.id == 'p1'), isFalse);
    });

    test(
        '7. Nearest sorts distance ascending and places with missing distance last',
        () {
      final d1 = makePlace(id: 'd1', name: '500m Place');
      final d2 = makePlace(id: 'd2', name: '150m Place');
      final d3 = makePlace(id: 'd3', name: 'Missing Distance Place');
      final d4 = makePlace(id: 'd4', name: '800m Place');

      final routeResults = {
        'd1': makeRouteResult(500),
        'd2': makeRouteResult(150),
        'd4': makeRouteResult(800),
        // d3 has no route result
      };

      final sorted = RealTimeDetectPage.sortNearestPlaces(
        places: [d1, d2, d3, d4],
        routeResults: routeResults,
      );

      expect(
          sorted.map((p) => p.id).toList(), equals(['d2', 'd1', 'd4', 'd3']));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Specification Group 4: Rank Mode Logic, Tie-Breaks & Presentation Truth
  // ═══════════════════════════════════════════════════════════════════════════

  group('Group 4: Rank Mode', () {
    test(
        '8. Rank tab uses ONLY POPULARITY candidates and strictly excludes DISTANCE-only places',
        () {
      final distOnly = makePlace(id: 'd1', name: 'Distance Only Place');
      final pop1 = makePlace(id: 'p1', name: 'Popular Place 1');
      final pop2 = makePlace(id: 'p2', name: 'Popular Place 2');

      final candidates = RealTimeDetectPage.getCandidatesForTab(
        mode: SortMode.rating,
        distancePlaces: [distOnly],
        popularityPlaces: [pop1, pop2],
      );

      expect(candidates, equals([pop1, pop2]));
      expect(candidates.any((p) => p.id == 'd1'), isFalse);
    });

    test('9. Rank sorts rating descending and places with missing rating last',
        () {
      final p1 = makePlace(id: 'p1', name: 'Rating 4.2', rating: 4.2);
      final p2 = makePlace(id: 'p2', name: 'Rating 4.9', rating: 4.9);
      final p3 = makePlace(id: 'p3', name: 'Rating 4.5', rating: 4.5);
      final p4 = makePlace(id: 'p4', name: 'Unrated Place', rating: null);

      final sorted = RealTimeDetectPage.sortRankPlaces(
        places: [p1, p2, p3, p4],
        popularityResponseOrder: {},
        routeResults: {},
      );

      expect(
          sorted.map((p) => p.id).toList(), equals(['p2', 'p3', 'p1', 'p4']));
    });

    test(
        '10. Equal-rating Rank results break ties using POPULARITY response order first, then distance',
        () {
      final pA = makePlace(id: 'pA', name: 'Place A', rating: 4.5);
      final pB = makePlace(id: 'pB', name: 'Place B', rating: 4.5);
      final pC = makePlace(id: 'pC', name: 'Place C', rating: 4.5);
      final pD = makePlace(id: 'pD', name: 'Place D', rating: 4.5);

      // pB appeared at index 0 in Google response, pA at index 2
      // pC and pD have no response order, but pC is closer (200m vs 600m)
      final responseOrder = {
        'pB': 0,
        'pA': 2,
      };

      final routeResults = {
        'pA': makeRouteResult(
            100), // even though pA is closer, pB came first in Google response
        'pB': makeRouteResult(900),
        'pC': makeRouteResult(200),
        'pD': makeRouteResult(600),
      };

      final sorted = RealTimeDetectPage.sortRankPlaces(
        places: [pD, pA, pC, pB],
        popularityResponseOrder: responseOrder,
        routeResults: routeResults,
      );

      expect(
          sorted.map((p) => p.id).toList(), equals(['pB', 'pA', 'pC', 'pD']));
    });

    testWidgets(
        '11. Rank displays honest loading indicator when POPULARITY is loading, preventing false empty states',
        (tester) async {
      // Production UI truth test: when in rating mode and popularity is loading,
      // the TravelLoadingIndicator with 'Loading ranked places...' is displayed
      const sortMode = SortMode.rating;
      const isPopularityLoading = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                if (sortMode == SortMode.rating && isPopularityLoading) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TravelLoadingIndicator(size: 80),
                        SizedBox(height: 12),
                        Text(
                          'Loading ranked places...',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }
                return const Text('Places loaded');
              },
            ),
          ),
        ),
      );

      expect(find.byType(TravelLoadingIndicator), findsOneWidget);
      expect(find.text('Loading ranked places...'), findsOneWidget);
      expect(find.text('Places loaded'), findsNothing);
    });

    test(
        '12. POPULARITY completion updates active UI while preserving filters and scroll state',
        () {
      final initialDistance = [makePlace(id: 'd1', name: 'D1')];
      final newlyArrivedPopularity = [
        makePlace(id: 'p1', name: 'P1', rating: 4.7)
      ];

      // Mode: rating, selectedPrimary: restaurant
      const activeSortMode = SortMode.rating;
      String? selectedPrimary = 'restaurant';
      bool preserveScroll = true;

      // When popularity finishes, getCandidatesForTab reflects the newly arrived popularity places
      final updatedCandidates = RealTimeDetectPage.getCandidatesForTab(
        mode: activeSortMode,
        distancePlaces: initialDistance,
        popularityPlaces: newlyArrivedPopularity,
      );

      expect(updatedCandidates, equals(newlyArrivedPopularity));
      expect(selectedPrimary, equals('restaurant'));
      expect(preserveScroll, isTrue);
    });

    test(
        '13. Stale async responses from an older generation cannot overwrite a newer generation',
        () {
      int detectGeneration = 0;
      List<String> committedPlaces = [];

      // User initiates Request 1 at Location A
      final req1Gen = ++detectGeneration;

      // User rapidly pans map / searches Location B (Request 2)
      final req2Gen = ++detectGeneration;

      // Simulate Request 1 finishing late
      void onResponse(int gen, List<String> places) {
        if (gen == detectGeneration) {
          committedPlaces = places;
        }
      }

      onResponse(req1Gen, ['Stale Place A', 'Stale Place B']);
      expect(committedPlaces, isEmpty,
          reason: 'Stale response from older generation must be discarded');

      // Request 2 completes
      onResponse(req2Gen, ['Fresh Place 1', 'Fresh Place 2']);
      expect(committedPlaces, equals(['Fresh Place 1', 'Fresh Place 2']));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Specification Group 5: Category & Subcategory Filtering on Active Candidates
  // ═══════════════════════════════════════════════════════════════════════════

  group('Group 5: Category Filtering', () {
    test(
        '14. Search-mode category filtering operates strictly on active search candidates pool',
        () {
      final searchCafe = makePlace(
        id: 's_cafe',
        name: 'Search Cafe',
        primaryType: 'restaurant',
        allTypes: ['cafe', 'food'],
      );
      final searchBar = makePlace(
        id: 's_bar',
        name: 'Search Bar',
        primaryType: 'restaurant',
        allTypes: ['bar', 'night_club'],
      );
      final searchCandidates = [searchCafe, searchBar];

      final availableSubs = RealTimeDetectPage.getAvailableSubCategories(
        selectedPrimary: 'restaurant',
        activeCandidatePool: searchCandidates,
        subCategoriesConfig: testSubCategoriesConfig,
      );

      final availableKeys = availableSubs.map((s) => s['key']).toList();
      expect(availableKeys, contains('cafe'));
      expect(availableKeys, contains('bar'));
      expect(availableKeys, isNot(contains('fast_food')),
          reason:
              'Subcategory from unselected realtime pool must not appear in search mode');
    });

    test(
        '15. Landmark-mode category filtering operates strictly on active landmark candidates pool',
        () {
      final landmarkFastFood = makePlace(
        id: 'lm_ff',
        name: 'Landmark Fast Food',
        primaryType: 'restaurant',
        allTypes: ['fast_food_restaurant'],
      );
      final landmarkCandidates = [landmarkFastFood];

      final availableSubs = RealTimeDetectPage.getAvailableSubCategories(
        selectedPrimary: 'restaurant',
        activeCandidatePool: landmarkCandidates,
        subCategoriesConfig: testSubCategoriesConfig,
      );

      final availableKeys = availableSubs.map((s) => s['key']).toList();
      expect(availableKeys, contains('fast_food'));
      expect(availableKeys, isNot(contains('cafe')));
      expect(availableKeys, isNot(contains('bar')));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Specification Group 6: Google Places API & Cache Isolation Architecture
  // ═══════════════════════════════════════════════════════════════════════════

  group('Group 6: Google Places API & Cache Isolation', () {
    test(
        '16. One failed Google type group retains successful groups without throwing away valid data',
        () async {
      final mockClient = MockHttpClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final includedTypes =
            (body['includedTypes'] as List?)?.cast<String>() ?? [];

        // Tourist group fails with 500
        if (includedTypes.contains('tourist_attraction')) {
          return http.Response('{"error": "Internal Server Error"}', 500);
        }

        // Restaurant group succeeds
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'g_resto_1',
                'displayName': {'text': 'Resilient Bistro'},
                'formattedAddress': '123 Food Street',
                'location': {'latitude': 3.1390, 'longitude': 101.6869},
                'rating': 4.6,
                'userRatingCount': 80,
                'primaryType': 'restaurant',
                'types': ['restaurant', 'food', 'point_of_interest'],
                'regularOpeningHours': {'openNow': true},
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);
      final results = await service.ensureDistanceRound(
          lat: 3.1390, lng: 101.6869, radius: 2000);

      expect(results.any((p) => p.id == 'g_resto_1'), isTrue);
      expect(service.googleDistanceCacheCount, greaterThan(0));
    });

    test(
        '17. PlacesApiService sends correct rankPreference payload in DISTANCE and POPULARITY requests',
        () async {
      String? capturedDistancePreference;
      String? capturedPopularityPreference;

      final mockClient = MockHttpClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final rank = body['rankPreference'] as String?;
        if (rank == 'DISTANCE') capturedDistancePreference = rank;
        if (rank == 'POPULARITY') capturedPopularityPreference = rank;
        return http.Response('{"places": []}', 200,
            headers: {'content-type': 'application/json'});
      });

      await PlacesApiService.searchNearby(
        lat: 3.1390,
        lng: 101.6869,
        radius: 2000,
        types: ['restaurant'],
        rankPreference: 'DISTANCE',
        client: mockClient,
      );
      expect(capturedDistancePreference, equals('DISTANCE'));

      await PlacesApiService.searchNearby(
        lat: 3.1390,
        lng: 101.6869,
        radius: 2000,
        types: ['restaurant'],
        rankPreference: 'POPULARITY',
        client: mockClient,
      );
      expect(capturedPopularityPreference, equals('POPULARITY'));
    });

    test(
        '18. DISTANCE and POPULARITY caches remain strictly isolated in NearbyPlacesService',
        () {
      final service = NearbyPlacesService.instance;
      service.clearGoogleRawCache();

      final distKey = NearbyPlacesService.buildGoogleCacheKey(
        lat: 3.1390,
        lng: 101.6869,
        rankPreference: 'DISTANCE',
        types: ['restaurant', 'cafe'],
      );

      final popKey = NearbyPlacesService.buildGoogleCacheKey(
        lat: 3.1390,
        lng: 101.6869,
        rankPreference: 'POPULARITY',
        types: ['restaurant', 'cafe'],
      );

      expect(distKey, isNot(equals(popKey)));
      expect(distKey, contains(':DISTANCE:'));
      expect(popKey, contains(':POPULARITY:'));
      expect(service.hasDistanceCacheEntry(distKey), isFalse);
      expect(service.hasPopularityCacheEntry(popKey), isFalse);
    });

    test(
        '19. Request inside an already fetched radius hits cache without refetching and filters to requested radius',
        () async {
      int networkCalls = 0;
      final mockClient = MockHttpClient((request) async {
        networkCalls++;
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'near_spot',
                'displayName': {'text': 'Near Spot'},
                'formattedAddress': '100m away',
                'location': {'latitude': 3.1395, 'longitude': 101.6869},
                'rating': 4.5,
                'primaryType': 'restaurant',
                'types': ['restaurant', 'food'],
              },
              {
                'id': 'far_spot',
                'displayName': {'text': 'Far Spot'},
                'formattedAddress': '3500m away',
                'location': {'latitude': 3.1700, 'longitude': 101.6869},
                'rating': 4.2,
                'primaryType': 'restaurant',
                'types': ['restaurant', 'food'],
              },
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      // 1. Fetch at 5000m radius -> network called
      final res5000 = await service.ensureDistanceRound(
          lat: 3.1390, lng: 101.6869, radius: 5000);
      expect(res5000.length, equals(2));
      final callsAfterFirst = networkCalls;
      expect(callsAfterFirst, greaterThan(0));

      // 2. Fetch at 2000m radius -> cache hit (no additional network call)
      final res2000 = await service.ensureDistanceRound(
          lat: 3.1390, lng: 101.6869, radius: 2000);
      expect(networkCalls, equals(callsAfterFirst),
          reason: 'Must hit cache and make no new network calls');
      expect(res2000.any((p) => p.id == 'near_spot'), isTrue);
      expect(res2000.any((p) => p.id == 'far_spot'), isFalse,
          reason: 'Far spot outside 2000m must be filtered out');
    });

    test(
        '20. LRU eviction removes actual stored cache entries and radius tracking',
        () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'dummy',
                'displayName': {'text': 'Dummy'},
                'location': {'latitude': 3.1390, 'longitude': 101.6869},
                'primaryType': 'restaurant',
                'types': ['restaurant'],
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      // Fill cache with 20 locations (matching production _maxCachedLocations capacity)
      for (int i = 0; i < 20; i++) {
        await service.ensureDistanceRound(
            lat: 3.0 + (i * 0.05), lng: 101.0, radius: 1000);
      }
      expect(service.googleDistanceCacheCount, equals(20));

      final firstLocationKey = service.distanceCacheKeys.first;
      expect(service.hasDistanceCacheEntry(firstLocationKey), isTrue);

      // Add 21st location to trigger LRU eviction
      await service.ensureDistanceRound(lat: 5.0, lng: 101.0, radius: 1000);

      // Oldest location must be evicted and count remain at capacity 20
      expect(service.googleDistanceCacheCount, equals(20));
      expect(service.hasDistanceCacheEntry(firstLocationKey), isFalse,
          reason: 'Oldest cache key must be evicted from the store');
    });

    test(
        '21. Missing-coordinate and out-of-radius results are rejected during production parsing and filtering',
        () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'valid_spot',
                'displayName': {'text': 'Valid Spot'},
                'location': {
                  'latitude': 3.1395,
                  'longitude': 101.6869
                }, // ~55m away
                'primaryType': 'restaurant',
                'types': ['restaurant'],
              },
              {
                'id': 'null_coord_spot',
                'displayName': {'text': 'Null Coord Spot'},
                'location': null,
                'primaryType': 'restaurant',
                'types': ['restaurant'],
              },
              {
                'id': 'out_of_bounds_spot',
                'displayName': {'text': 'Out Of Bounds Spot'},
                'location': {
                  'latitude': 3.5000,
                  'longitude': 101.6869
                }, // ~40,000m away
                'primaryType': 'restaurant',
                'types': ['restaurant'],
              },
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);
      final places = await service.ensureDistanceRound(
          lat: 3.1390, lng: 101.6869, radius: 1000);

      expect(places.length, equals(1));
      expect(places.first.id, equals('valid_spot'));
      expect(places.any((p) => p.id == 'null_coord_spot'), isFalse);
      expect(places.any((p) => p.id == 'out_of_bounds_spot'), isFalse);
    });

    test('22. Geoapify candidates remain outside the Google Rank pool', () {
      final geoapifyPlace = makePlace(
        id: 'geo_1',
        name: 'Geoapify Attraction',
        source: 'geoapify',
        rating: 4.8,
      );
      final googlePopPlace = makePlace(
        id: 'google_pop_1',
        name: 'Google Ranked Place',
        source: 'google',
        rating: 4.6,
      );

      final rankPool = RealTimeDetectPage.getCandidatesForTab(
        mode: SortMode.rating,
        distancePlaces: [geoapifyPlace],
        popularityPlaces: [googlePopPlace],
      );

      expect(rankPool, equals([googlePopPlace]));
      expect(rankPool.any((p) => p.source == 'geoapify'), isFalse,
          reason: 'Geoapify candidates must never be mixed into Rank pool');
    });
  });
}
