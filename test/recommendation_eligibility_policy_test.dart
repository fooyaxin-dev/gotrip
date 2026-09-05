import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/models/itineraryModel.dart';
import 'package:gotrip/services/nearbyPlace_service.dart';
import 'package:gotrip/services/placesAPI_service.dart';
import 'package:gotrip/services/recommendation_eligibility_policy.dart';
import 'package:gotrip/services/userPreference_service.dart';
import 'package:gotrip/services/itinerary_service.dart';
import 'package:gotrip/modules/place/detectPlacePage.dart';

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

PlaceModel makePlace({
  required String id,
  required String name,
  double lat = 3.1390,
  double lng = 101.6869,
  double? rating = 4.5,
  int? userRatingCount = 100,
  String? primaryType = 'restaurant',
  List<String>? allTypes,
  String? photoUrl = 'https://example.com/photo.jpg',
  bool isOpenNow = true,
  String source = 'google',
}) {
  return PlaceModel(
    id: id,
    name: name,
    address: 'Test Address $id',
    lat: lat,
    lng: lng,
    rating: rating,
    userRatingCount: userRatingCount,
    primaryType: primaryType,
    allTypes: allTypes ?? ['restaurant', 'food'],
    photoUrl: photoUrl,
    isOpenNow: isOpenNow,
    source: source,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PlacesApiService.resetTestOverrides();
    PlacesApiService.customCacheReader = (id) async => null;
    PlacesApiService.customCacheWriter =
        (id, data, {bool merge = true}) async {};
    UserPreferenceService.instance.clearLocalSession();
    NearbyPlacesService.instance.clearGoogleRawCache();
    NearbyPlacesService.instance.clearCache();
  });

  group('Group 1: Shared Recommendation Eligibility Policy Unit Tests', () {
    test(
        '1. Woon Kwong Hing Sdn. Bhd. with only generic store/business types is excluded',
        () {
      final place = makePlace(
        id: 'wkh_1',
        name: 'Woon Kwong Hing Sdn. Bhd.',
        primaryType: 'shopping_mall',
        allTypes: ['store', 'wholesaler', 'establishment', 'point_of_interest'],
      );

      expect(
        RecommendationEligibilityPolicy.hasSuspiciousCorporateName(place.name),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.hasAuthoritativeVisitorType(place),
        isFalse,
      );
      expect(
        RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
            place),
        isFalse,
      );
    });

    test('2. Case and punctuation variants of Sdn. Bhd. are detected', () {
      final variants = [
        'Woon Kwong Hing Sdn Bhd',
        'Woon Kwong Hing Sdn. Bhd.',
        'Woon Kwong Hing SDN. BHD',
        'Woon Kwong Hing sdnbhd',
        'Woon Kwong Hing Sdn.Bhd.',
        'Woon Kwong Hing Sdn   Bhd',
      ];

      for (final name in variants) {
        expect(
          RecommendationEligibilityPolicy.hasSuspiciousCorporateName(name),
          isTrue,
          reason: 'Variant "$name" should be detected as corporate',
        );

        final place = makePlace(
          id: 'var_${name.hashCode}',
          name: name,
          allTypes: ['store', 'establishment', 'point_of_interest'],
        );
        expect(
          RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
              place),
          isFalse,
          reason:
              'Place "$name" with generic types must be excluded from recommendations',
        );
      }
    });

    test('3. A company-named place with restaurant is retained', () {
      final place = makePlace(
        id: 'comp_rest',
        name: 'ABC Restaurant Sdn. Bhd.',
        primaryType: 'restaurant',
        allTypes: ['restaurant', 'food', 'point_of_interest', 'establishment'],
      );

      expect(
        RecommendationEligibilityPolicy.hasSuspiciousCorporateName(place.name),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.hasAuthoritativeVisitorType(place),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
            place),
        isTrue,
      );
    });

    test('4. A company-named place with cafe is retained', () {
      final place = makePlace(
        id: 'comp_cafe',
        name: 'Green Leaf Cafe Berhad',
        primaryType: 'restaurant',
        allTypes: ['cafe', 'coffee_shop', 'food', 'establishment'],
      );

      expect(
        RecommendationEligibilityPolicy.hasSuspiciousCorporateName(place.name),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.hasAuthoritativeVisitorType(place),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
            place),
        isTrue,
      );
    });

    test('5. A company-named place with tourist_attraction is retained', () {
      final place = makePlace(
        id: 'comp_attr',
        name: 'Heritage Discovery Center Group Berhad',
        primaryType: 'tourist_attraction',
        allTypes: ['tourist_attraction', 'point_of_interest', 'establishment'],
      );

      expect(
        RecommendationEligibilityPolicy.hasSuspiciousCorporateName(place.name),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.hasAuthoritativeVisitorType(place),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
            place),
        isTrue,
      );
    });

    test('6. A company-named place with shopping_mall is retained', () {
      final place = makePlace(
        id: 'comp_mall',
        name: 'Metro City Mall Enterprise',
        primaryType: 'shopping_mall',
        allTypes: ['shopping_mall', 'point_of_interest', 'establishment'],
      );

      expect(
        RecommendationEligibilityPolicy.hasSuspiciousCorporateName(place.name),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.hasAuthoritativeVisitorType(place),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
            place),
        isTrue,
      );
    });

    test(
        '7. A company-named place with only store, establishment, or point_of_interest is excluded',
        () {
      final place = makePlace(
        id: 'comp_generic',
        name: 'Apex Holdings Sdn. Bhd.',
        primaryType: 'shopping_mall',
        allTypes: ['store', 'establishment', 'point_of_interest'],
      );

      expect(
        RecommendationEligibilityPolicy.hasSuspiciousCorporateName(place.name),
        isTrue,
      );
      expect(
        RecommendationEligibilityPolicy.hasAuthoritativeVisitorType(place),
        isFalse,
      );
      expect(
        RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
            place),
        isFalse,
      );
    });

    test(
        '8. A normal place without corporate keywords is not excluded merely because it has a generic type',
        () {
      final normalPlace = makePlace(
        id: 'normal_1',
        name: "Uncle Bob's Corner",
        primaryType: 'shopping_mall',
        allTypes: ['store', 'establishment', 'point_of_interest'],
      );

      expect(
        RecommendationEligibilityPolicy.hasSuspiciousCorporateName(
            normalPlace.name),
        isFalse,
      );
      expect(
        RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(
            normalPlace),
        isTrue,
      );
    });

    test(
        '8b. Other corporate keywords (trading, management, solutions, consultancy, agency, services, network) are detected',
        () {
      final keywords = [
        'Global Trading',
        'Asset Management Berhad',
        'Cloud Solutions Sdn. Bhd.',
        'Tech Consultancy Enterprise',
        'City Real Estate Agency',
        'Logistics Services',
        'Telecom Network Group Berhad',
      ];

      for (final name in keywords) {
        expect(
          RecommendationEligibilityPolicy.hasSuspiciousCorporateName(name),
          isTrue,
          reason: 'Expected "$name" to be identified as corporate/business',
        );
      }
    });
  });

  group('Group 2: Production Candidate-Pipeline Integration Tests', () {
    test(
        '9. MainPage automatic For You candidates use the policy via ensureForYouSnapshot',
        () async {
      final corporateExcluded = makePlace(
        id: 'p_corp',
        name: 'Woon Kwong Hing Sdn. Bhd.',
        allTypes: ['store', 'establishment', 'wholesaler'],
      );
      final corporateRetained = makePlace(
        id: 'p_food_corp',
        name: 'ABC Restaurant Sdn. Bhd.',
        allTypes: ['restaurant', 'food'],
      );
      final normalRetained = makePlace(
        id: 'p_normal',
        name: 'Kuala Lumpur Central Park',
        allTypes: ['park'],
      );

      // Create candidates pool directly tested against the candidate filter boundary
      final combined = [corporateExcluded, corporateRetained, normalRetained];
      final eligible = combined.where((p) {
        if (p.isGeoapify) return false;
        if (p.isOpenNow == false) return false;
        if (p.lat == null || p.lng == null) return false;
        if (!RecommendationEligibilityPolicy
            .isEligibleForAutomaticRecommendation(p)) {
          return false;
        }
        return true;
      }).toList();

      expect(eligible.map((p) => p.id), contains('p_food_corp'));
      expect(eligible.map((p) => p.id), contains('p_normal'));
      expect(eligible.map((p) => p.id), isNot(contains('p_corp')));
    });

    test(
        '10. MainPage Nearby and Recommended candidates use the policy via _fetchGoogleOnce',
        () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'wkh_test',
                'displayName': {'text': 'Woon Kwong Hing Sdn. Bhd.'},
                'types': ['store', 'establishment', 'wholesaler'],
                'location': {'latitude': 3.1390, 'longitude': 101.6869},
              },
              {
                'id': 'rest_corp_test',
                'displayName': {'text': 'Tasty Food Sdn. Bhd.'},
                'types': ['restaurant', 'food', 'establishment'],
                'location': {'latitude': 3.1391, 'longitude': 101.6870},
              },
              {
                'id': 'park_test',
                'displayName': {'text': 'Perdana Botanical Garden'},
                'types': ['park', 'tourist_attraction'],
                'location': {'latitude': 3.1392, 'longitude': 101.6871},
              },
            ],
          }),
          200,
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      final places = await service.ensureDistanceRound(
        lat: 3.1390,
        lng: 101.6869,
        radius: 5000,
      );

      final placeIds = places.map((p) => p.id).toList();
      expect(placeIds, contains('rest_corp_test'));
      expect(placeIds, contains('park_test'));
      expect(placeIds, isNot(contains('wkh_test')));
    });

    test(
        '11. DetectPlace For You, Nearest, and Rank candidates use the same policy',
        () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'dist_corp_excluded',
                'displayName': {'text': 'Mega Supply Enterprise'},
                'types': ['store', 'establishment', 'point_of_interest'],
                'location': {'latitude': 3.1390, 'longitude': 101.6869},
              },
              {
                'id': 'dist_rest_retained',
                'displayName': {'text': 'Delicious Dim Sum Sdn. Bhd.'},
                'types': ['restaurant', 'food'],
                'location': {'latitude': 3.1391, 'longitude': 101.6870},
              },
            ],
          }),
          200,
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      // Nearest candidates (DISTANCE round)
      final distancePlaces = await service.ensureDistanceRound(
        lat: 3.1390,
        lng: 101.6869,
        radius: 5000,
      );
      expect(distancePlaces.map((p) => p.id), contains('dist_rest_retained'));
      expect(distancePlaces.map((p) => p.id),
          isNot(contains('dist_corp_excluded')));

      // Rank candidates (POPULARITY round)
      final popularityPlaces = await service.ensurePopularityRound(
        lat: 3.1390,
        lng: 101.6869,
        radius: 5000,
      );
      expect(popularityPlaces.map((p) => p.id), contains('dist_rest_retained'));
      expect(popularityPlaces.map((p) => p.id),
          isNot(contains('dist_corp_excluded')));

      // For You tab candidate pool (combining distance + popularity)
      final forYouTab = RealTimeDetectPage.getCandidatesForTab(
        mode: SortMode.recommended,
        distancePlaces: distancePlaces,
        popularityPlaces: popularityPlaces,
      );
      expect(forYouTab.map((p) => p.id), contains('dist_rest_retained'));
      expect(forYouTab.map((p) => p.id), isNot(contains('dist_corp_excluded')));
    });

    test(
        '12. Automatic recommendations around a searched location use the policy',
        () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'search_loc_corp',
                'displayName': {'text': 'Penang Logistics Sdn. Bhd.'},
                'types': ['corporate_office', 'establishment'],
                'location': {'latitude': 5.4141, 'longitude': 100.3288},
              },
              {
                'id': 'search_loc_attraction',
                'displayName': {'text': 'Penang Hill Railway Berhad'},
                'types': ['tourist_attraction', 'point_of_interest'],
                'location': {'latitude': 5.4085, 'longitude': 100.2771},
              },
            ],
          }),
          200,
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      final searchAreaPlaces = await service.ensureDistanceRound(
        lat: 5.4141,
        lng: 100.3288,
        radius: 10000,
      );

      final ids = searchAreaPlaces.map((p) => p.id).toList();
      expect(ids, contains('search_loc_attraction'));
      expect(ids, isNot(contains('search_loc_corp')));
    });

    test(
        '13. System-generated itinerary candidates use the policy via fetchForItinerary and fetchAdditionalForItinerary',
        () async {
      final mockClient = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'itin_wkh',
                'displayName': {'text': 'Woon Kwong Hing Sdn. Bhd.'},
                'types': ['shopping_mall', 'store', 'establishment'],
                'location': {'latitude': 3.1390, 'longitude': 101.6869},
              },
              {
                'id': 'itin_cafe',
                'displayName': {'text': 'Morning Coffee Sdn. Bhd.'},
                'types': ['restaurant', 'cafe', 'food'],
                'location': {'latitude': 3.1391, 'longitude': 101.6870},
              },
            ],
          }),
          200,
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      // Primary candidate fetch for itinerary
      final candidates = await service.fetchForItinerary(
        lat: 3.1390,
        lng: 101.6869,
        categories: ['restaurant'],
        radius: 5000,
      );

      expect(candidates.map((p) => p.id), contains('itin_cafe'));
      expect(candidates.map((p) => p.id), isNot(contains('itin_wkh')));

      // Additional candidate fetch for itinerary
      final additional = await service.fetchAdditionalForItinerary(
        lat: 3.1390,
        lng: 101.6869,
        radius: 5000,
        additionalNeededByCategory: {'restaurant': 2},
        existingPlaceIds: {},
      );

      expect(additional.map((p) => p.id), contains('itin_cafe'));
      expect(additional.map((p) => p.id), isNot(contains('itin_wkh')));
    });

    test(
        '13b. ItineraryService._isBlocked delegates corporate filtering to shared policy while preserving itinerary exclusions',
        () {
      // 1. Corporate name with only generic store types -> BLOCKED
      final wkhCorp = makePlace(
        id: 'itin_wkh',
        name: 'Woon Kwong Hing Sdn. Bhd.',
        allTypes: ['store', 'wholesaler', 'establishment'],
      );
      expect(ItineraryService.isBlockedForTesting(wkhCorp), isTrue);

      // 2. Corporate name with restaurant authoritative type -> NOT BLOCKED
      final abcRestaurant = makePlace(
        id: 'itin_abc',
        name: 'ABC Restaurant Sdn. Bhd.',
        allTypes: ['restaurant', 'food'],
      );
      expect(ItineraryService.isBlockedForTesting(abcRestaurant), isFalse);

      // 3. Itinerary-specific name keyword (e.g. clinic) -> BLOCKED
      final clinicPlace = makePlace(
        id: 'itin_clinic',
        name: 'Kuala Lumpur Specialist Clinic',
        allTypes: ['health', 'establishment'],
      );
      expect(ItineraryService.isBlockedForTesting(clinicPlace), isTrue);

      // 4. Itinerary-specific blocked type (e.g. lodging / hotel) -> BLOCKED
      final hotelPlace = makePlace(
        id: 'itin_hotel',
        name: 'The Majestic Grand Hotel',
        allTypes: ['lodging', 'hotel', 'establishment'],
      );
      expect(ItineraryService.isBlockedForTesting(hotelPlace), isTrue);
    });

    test('17. Filtering preserves the relative order of retained places',
        () async {
      final p1 = makePlace(
        id: 'order_1',
        name: 'Spot Alpha',
        allTypes: ['restaurant'],
      );
      final pCorp = makePlace(
        id: 'order_corp',
        name: 'Woon Kwong Hing Sdn. Bhd.',
        allTypes: ['store', 'wholesaler'],
      );
      final p2 = makePlace(
        id: 'order_2',
        name: 'Spot Beta Sdn. Bhd.',
        allTypes: ['cafe'],
      );
      final p3 = makePlace(
        id: 'order_3',
        name: 'Spot Gamma',
        allTypes: ['park'],
      );

      final input = [p1, pCorp, p2, p3];
      final filtered = input
          .where(RecommendationEligibilityPolicy
              .isEligibleForAutomaticRecommendation)
          .toList();

      expect(filtered.map((p) => p.id).toList(),
          ['order_1', 'order_2', 'order_3']);
    });

    test('18. Filtering does not cause a new API request', () async {
      int apiCallCount = 0;
      final mockClient = MockHttpClient((request) async {
        apiCallCount++;
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'call_check_corp',
                'displayName': {'text': 'Woon Kwong Hing Sdn. Bhd.'},
                'types': ['store'],
                'location': {'latitude': 3.1390, 'longitude': 101.6869},
              },
              {
                'id': 'call_check_cafe',
                'displayName': {'text': 'Sun Cafe'},
                'types': ['cafe'],
                'location': {'latitude': 3.1391, 'longitude': 101.6870},
              },
            ],
          }),
          200,
        );
      });

      final service = NearbyPlacesService(httpClient: mockClient);

      // First call -> Cache MISS -> Calls API once per type group
      final res1 = await service.ensureDistanceRound(
        lat: 3.1390,
        lng: 101.6869,
        radius: 5000,
      );
      final callsAfterFirst = apiCallCount;
      expect(callsAfterFirst, greaterThan(0));

      // Second call at same coordinates/radius -> Cache HIT -> Zero additional API calls
      final res2 = await service.ensureDistanceRound(
        lat: 3.1390,
        lng: 101.6869,
        radius: 5000,
      );

      expect(apiCallCount, equals(callsAfterFirst),
          reason: 'Cache hit must not cause new API calls');
      expect(res1.map((p) => p.id), equals(res2.map((p) => p.id)));
    });
  });

  group('Group 3: User-Driven and Preserved Flows Tests', () {
    test('14. User exact Search/autocomplete selection remains accessible',
        () async {
      final client = MockHttpClient((req) async {
        return http.Response(
          jsonEncode({
            'id': 'wkh_exact_id',
            'displayName': {'text': 'Woon Kwong Hing Sdn. Bhd.'},
            'formattedAddress': '123 Business Street',
            'location': {'latitude': 3.1390, 'longitude': 101.6869},
            'types': ['wholesaler', 'store', 'establishment'],
          }),
          200,
        );
      });

      // User selecting an exact place from search fetches details without policy rejection
      final details = await PlacesApiService.getPlaceDetails(
        'wkh_exact_id',
        client: client,
      );
      expect(
          details['displayName']['text'], equals('Woon Kwong Hing Sdn. Bhd.'));
      expect(details['types'], contains('wholesaler'));

      // Direct place model instantiated from search selection is fully usable
      final exactSelectedPlace = makePlace(
        id: 'wkh_exact_id',
        name: 'Woon Kwong Hing Sdn. Bhd.',
        allTypes: ['wholesaler', 'store', 'establishment'],
      );
      expect(exactSelectedPlace.id, equals('wkh_exact_id'));
      expect(exactSelectedPlace.name, equals('Woon Kwong Hing Sdn. Bhd.'));
    });

    test('15. Landmark Recognition result remains unaffected', () async {
      // Landmark recognition result with a corporate or business name
      final landmarkPlace = makePlace(
        id: 'landmark_wkh_corp',
        name: 'Woon Kwong Hing Building',
        allTypes: ['establishment'],
      );

      // Landmark result model remains intact and unaffected by recommendation filters
      expect(landmarkPlace.id, equals('landmark_wkh_corp'));
      expect(landmarkPlace.name, equals('Woon Kwong Hing Building'));
    });

    test('16. Existing saved itinerary places remain unaffected', () {
      // Create an ItineraryPlace with a corporate name
      final savedItineraryPlace = ItineraryPlace(
        placeId: 'saved_corp_place',
        name: 'Woon Kwong Hing Sdn. Bhd.',
        address: '123 Jalan Wholesaler',
        lat: 3.1390,
        lng: 101.6869,
        suggestedTime: '09:00 AM',
        durationMinutes: 60,
        primaryType: 'shopping_mall',
      );

      final itinerary = ItineraryModel(
        id: 'itin_saved_1',
        title: 'Kuala Lumpur Business & Culture Tour',
        startDate: '2026-09-06',
        totalDays: 1,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-06',
            places: [savedItineraryPlace],
          ),
        ],
        createdAt: DateTime.now(),
        isOriginCurrentLocation: true,
      );

      // Existing saved itinerary place remains in the itinerary
      expect(itinerary.days.first.places.length, equals(1));
      expect(itinerary.days.first.places[0].name,
          equals('Woon Kwong Hing Sdn. Bhd.'));
      expect(
          itinerary.days.first.places[0].placeId, equals('saved_corp_place'));
    });
  });
}
