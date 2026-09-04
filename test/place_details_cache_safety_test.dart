import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:gotrip/services/placesAPI_service.dart';

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

  final fixedNow = DateTime(2026, 9, 5, 12, 0, 0);

  late Map<String, Map<String, dynamic>> mockStore;
  late List<String> deletedDocIds;
  late int apiCallCount;

  setUp(() {
    PlacesApiService.resetTestOverrides();
    PlacesApiService.resetStats();

    mockStore = {};
    deletedDocIds = [];
    apiCallCount = 0;

    PlacesApiService.customNow = () => fixedNow;

    PlacesApiService.customCacheReader = (id) async {
      final doc = mockStore[id];
      if (doc == null) return null;
      return Map<String, dynamic>.from(doc);
    };

    PlacesApiService.customCacheWriter = (id, data, {bool merge = true}) async {
      if (merge && mockStore.containsKey(id)) {
        mockStore[id] = {...mockStore[id]!, ...data};
      } else {
        mockStore[id] = Map<String, dynamic>.from(data);
      }
    };

    PlacesApiService.customCacheDeleter = (id) async {
      deletedDocIds.add(id);
      mockStore.remove(id);
    };
  });

  tearDown(() {
    PlacesApiService.resetTestOverrides();
  });

  Map<String, dynamic> makeCompletePlaceData({
    required String placeId,
    required DateTime cachedAtTime,
    String displayName = 'Old Stored Place',
    String formattedAddress = '123 Old Street',
    double rating = 4.2,
    Map<String, dynamic>? extraFields,
  }) {
    return {
      'id': placeId,
      'displayName': {'text': displayName, 'languageCode': 'en'},
      'formattedAddress': formattedAddress,
      'location': {'latitude': 3.1390, 'longitude': 101.6869},
      'types': ['restaurant', 'food'],
      'rating': rating,
      'cachedAt': Timestamp.fromDate(cachedAtTime),
      ...?extraFields,
    };
  }

  group('PlacesApiService Cache Safety & 30-Day TTL Tests', () {
    test('1. Cache younger than 30 days returns cache with zero API calls',
        () async {
      final freshTime =
          fixedNow.subtract(const Duration(days: 29, hours: 23, minutes: 59));
      mockStore['place_fresh'] = makeCompletePlaceData(
        placeId: 'place_fresh',
        cachedAtTime: freshTime,
        displayName: 'Fresh Place Cached',
      );

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response('{"displayName": {"text": "API Place"}}', 200);
      });

      final result =
          await PlacesApiService.getPlaceDetails('place_fresh', client: client);

      expect(apiCallCount, equals(0));
      expect(result['displayName']['text'], equals('Fresh Place Cached'));
    });

    test('2. Cache exactly 30 days old triggers one refresh attempt', () async {
      final exactly30DaysAgo = fixedNow.subtract(const Duration(days: 30));
      mockStore['place_30d'] = makeCompletePlaceData(
        placeId: 'place_30d',
        cachedAtTime: exactly30DaysAgo,
        displayName: 'Old 30d Place',
      );

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response(
          jsonEncode({
            'id': 'place_30d',
            'displayName': {'text': 'Refreshed 30d Place'},
            'formattedAddress': '456 New Road',
            'location': {'latitude': 3.14, 'longitude': 101.69},
            'types': ['restaurant'],
          }),
          200,
        );
      });

      final result =
          await PlacesApiService.getPlaceDetails('place_30d', client: client);

      expect(apiCallCount, equals(1));
      expect(result['displayName']['text'], equals('Refreshed 30d Place'));
    });

    test('3. Successful refresh merges new data and advances cachedAt',
        () async {
      final oldTime = fixedNow.subtract(const Duration(days: 35));
      mockStore['place_refresh'] = makeCompletePlaceData(
        placeId: 'place_refresh',
        cachedAtTime: oldTime,
        displayName: 'Old Name',
      );

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response(
          jsonEncode({
            'id': 'place_refresh',
            'displayName': {'text': 'Fresh API Name'},
            'formattedAddress': '999 Updated Ave',
            'location': {'latitude': 3.15, 'longitude': 101.70},
            'types': ['restaurant'],
            'rating': 4.9,
          }),
          200,
        );
      });

      final result = await PlacesApiService.getPlaceDetails('place_refresh',
          client: client);

      expect(result['displayName']['text'], equals('Fresh API Name'));
      expect(result['rating'], equals(4.9));

      final stored = mockStore['place_refresh']!;
      expect(stored['displayName']['text'], equals('Fresh API Name'));
      expect(stored['cachedAt'], isA<Timestamp>());
      final storedTime = (stored['cachedAt'] as Timestamp).toDate();
      expect(storedTime, equals(fixedNow));
      expect(storedTime.isAfter(oldTime), isTrue);
    });

    test('4. Expired complete cache is not deleted before API request',
        () async {
      final expiredTime = fixedNow.subtract(const Duration(days: 45));
      mockStore['place_no_predelete'] = makeCompletePlaceData(
        placeId: 'place_no_predelete',
        cachedAtTime: expiredTime,
      );

      bool cacheWasPresentDuringApiCall = false;

      final client = MockHttpClient((req) async {
        apiCallCount++;
        cacheWasPresentDuringApiCall =
            mockStore.containsKey('place_no_predelete');
        return http.Response(
          jsonEncode({
            'id': 'place_no_predelete',
            'displayName': {'text': 'API Result'},
            'formattedAddress': 'New Address',
            'location': {'latitude': 3.1, 'longitude': 101.6},
            'types': ['restaurant'],
          }),
          200,
        );
      });

      await PlacesApiService.getPlaceDetails('place_no_predelete',
          client: client);

      expect(cacheWasPresentDuringApiCall, isTrue);
      expect(deletedDocIds, isEmpty);
    });

    test('5. HTTP 500 with expired complete cache returns the old cache',
        () async {
      final expiredTime = fixedNow.subtract(const Duration(days: 40));
      mockStore['place_500'] = makeCompletePlaceData(
        placeId: 'place_500',
        cachedAtTime: expiredTime,
        displayName: 'Preserved Old Place 500',
      );

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response('Internal Server Error', 500);
      });

      final result =
          await PlacesApiService.getPlaceDetails('place_500', client: client);

      expect(apiCallCount, equals(1));
      expect(result['displayName']['text'], equals('Preserved Old Place 500'));
      expect(mockStore.containsKey('place_500'), isTrue);
      expect(deletedDocIds, isEmpty);
    });

    test(
        '6. Network exception with expired complete cache returns the old cache',
        () async {
      final expiredTime = fixedNow.subtract(const Duration(days: 40));
      mockStore['place_net_err'] = makeCompletePlaceData(
        placeId: 'place_net_err',
        cachedAtTime: expiredTime,
        displayName: 'Preserved Old Place NetErr',
      );

      final client = MockHttpClient((req) async {
        apiCallCount++;
        throw const SocketException('No Internet Connection');
      });

      final result = await PlacesApiService.getPlaceDetails('place_net_err',
          client: client);

      expect(apiCallCount, equals(1));
      expect(
          result['displayName']['text'], equals('Preserved Old Place NetErr'));
      expect(mockStore.containsKey('place_net_err'), isTrue);
      expect(deletedDocIds, isEmpty);
    });

    test(
        '7. HTTP 404 with expired complete cache returns and preserves the old cache',
        () async {
      final expiredTime = fixedNow.subtract(const Duration(days: 50));
      mockStore['place_404'] = makeCompletePlaceData(
        placeId: 'place_404',
        cachedAtTime: expiredTime,
        displayName: 'Preserved Stale 404 Place',
      );

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response('{"error": "Not Found"}', 404);
      });

      final result =
          await PlacesApiService.getPlaceDetails('place_404', client: client);

      expect(apiCallCount, equals(1));
      expect(
          result['displayName']['text'], equals('Preserved Stale 404 Place'));
      expect(mockStore.containsKey('place_404'), isTrue);
      expect(deletedDocIds, isEmpty);
    });

    test('8. API failure does not advance cachedAt', () async {
      final originalCachedAt = fixedNow.subtract(const Duration(days: 35));
      mockStore['place_fail_no_advance'] = makeCompletePlaceData(
        placeId: 'place_fail_no_advance',
        cachedAtTime: originalCachedAt,
      );

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response('Gateway Timeout', 504);
      });

      await PlacesApiService.getPlaceDetails('place_fail_no_advance',
          client: client);

      final stored = mockStore['place_fail_no_advance']!;
      final storedTime = (stored['cachedAt'] as Timestamp).toDate();
      expect(storedTime, equals(originalCachedAt));
    });

    test(
        '9. Firestore write failure after API success returns the old complete cache',
        () async {
      final oldTime = fixedNow.subtract(const Duration(days: 32));
      mockStore['place_write_fail'] = makeCompletePlaceData(
        placeId: 'place_write_fail',
        cachedAtTime: oldTime,
        displayName: 'Old Cache Before Write Fail',
      );

      PlacesApiService.customCacheWriter =
          (id, data, {bool merge = true}) async {
        throw Exception(
            'Simulated Firestore write permission-denied / network error');
      };

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response(
          jsonEncode({
            'id': 'place_write_fail',
            'displayName': {'text': 'Fresh API Data'},
            'formattedAddress': 'Some Address',
            'location': {'latitude': 3.1, 'longitude': 101.6},
            'types': ['cafe'],
          }),
          200,
        );
      });

      final result = await PlacesApiService.getPlaceDetails('place_write_fail',
          client: client);

      expect(apiCallCount, equals(1));
      expect(
          result['displayName']['text'], equals('Old Cache Before Write Fail'));
    });

    test('10. Firestore write failure does not delete the old cache', () async {
      final oldTime = fixedNow.subtract(const Duration(days: 32));
      mockStore['place_write_no_delete'] = makeCompletePlaceData(
        placeId: 'place_write_no_delete',
        cachedAtTime: oldTime,
      );

      PlacesApiService.customCacheWriter =
          (id, data, {bool merge = true}) async {
        throw Exception('Simulated Firestore write failure');
      };

      final client = MockHttpClient((req) async {
        return http.Response('{"id": "place_write_no_delete"}', 200);
      });

      await PlacesApiService.getPlaceDetails('place_write_no_delete',
          client: client);

      expect(mockStore.containsKey('place_write_no_delete'), isTrue);
      expect(deletedDocIds, isEmpty);
    });

    test('11. A types-only incomplete stub is not treated as complete',
        () async {
      // Stub written by favourite_service (only has types, no location)
      mockStore['place_stub'] = {
        'types': ['restaurant', 'cafe'],
      };

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response(
          jsonEncode({
            'id': 'place_stub',
            'displayName': {'text': 'Complete From API'},
            'formattedAddress': 'Full Address',
            'location': {'latitude': 3.14, 'longitude': 101.68},
            'types': ['restaurant', 'cafe'],
          }),
          200,
        );
      });

      final result =
          await PlacesApiService.getPlaceDetails('place_stub', client: client);

      expect(apiCallCount, equals(1));
      expect(result['displayName']['text'], equals('Complete From API'));
    });

    test('12. A types-only stub is not deleted before API request', () async {
      mockStore['place_stub_nodelete'] = {
        'types': ['restaurant'],
      };

      bool stubPresentDuringCall = false;

      final client = MockHttpClient((req) async {
        apiCallCount++;
        stubPresentDuringCall = mockStore.containsKey('place_stub_nodelete');
        return http.Response(
          jsonEncode({
            'id': 'place_stub_nodelete',
            'displayName': {'text': 'API Result'},
            'location': {'latitude': 3.1, 'longitude': 101.6},
            'types': ['restaurant'],
          }),
          200,
        );
      });

      await PlacesApiService.getPlaceDetails('place_stub_nodelete',
          client: client);

      expect(stubPresentDuringCall, isTrue);
      expect(deletedDocIds, isEmpty);
    });

    test('13. API success safely merges details into the incomplete stub',
        () async {
      mockStore['place_stub_merge'] = {
        'types': ['bakery'],
        'stubMeta': 'keep_this_metadata',
      };

      final client = MockHttpClient((req) async {
        apiCallCount++;
        return http.Response(
          jsonEncode({
            'id': 'place_stub_merge',
            'displayName': {'text': 'Bakery Name'},
            'location': {'latitude': 3.12, 'longitude': 101.65},
            'types': ['bakery', 'food'],
          }),
          200,
        );
      });

      await PlacesApiService.getPlaceDetails('place_stub_merge',
          client: client);

      final stored = mockStore['place_stub_merge']!;
      expect(stored['stubMeta'], equals('keep_this_metadata'));
      expect(stored['displayName']['text'], equals('Bakery Name'));
      expect(stored['cachedAt'], isNotNull);
    });

    test(
        '14. Missing/incomplete cache plus API failure preserves the existing thrown error behaviour',
        () async {
      // 14a. Non-existent cache + HTTP 500 -> throws
      final client500 = MockHttpClient((req) async {
        return http.Response('Server Error', 500);
      });
      expect(
        () => PlacesApiService.getPlaceDetails('non_existent_place',
            client: client500),
        throwsA(isA<Exception>()),
      );

      // 14b. Incomplete stub + network exception -> throws
      mockStore['stub_with_error'] = {
        'types': ['cafe']
      };
      final clientNetErr = MockHttpClient((req) async {
        throw const SocketException('Offline');
      });
      expect(
        () => PlacesApiService.getPlaceDetails('stub_with_error',
            client: clientNetErr),
        throwsA(isA<SocketException>()),
      );

      // 14c. Non-existent cache + HTTP 404 -> throws specific 404 Exception
      final client404 = MockHttpClient((req) async {
        return http.Response('Not Found', 404);
      });
      expect(
        () =>
            PlacesApiService.getPlaceDetails('missing_404', client: client404),
        throwsA(predicate(
            (e) => e.toString().contains('Place ID no longer valid'))),
      );
    });

    test(
        '15. Successful write uses merge semantics and preserves an unrelated existing document field',
        () async {
      final expiredTime = fixedNow.subtract(const Duration(days: 35));
      mockStore['place_unrelated_field'] = makeCompletePlaceData(
        placeId: 'place_unrelated_field',
        cachedAtTime: expiredTime,
        displayName: 'Old Place',
        extraFields: {
          'userCustomNote': 'Preserve this user custom note',
          'favoriteFlag': true,
        },
      );

      final client = MockHttpClient((req) async {
        return http.Response(
          jsonEncode({
            'id': 'place_unrelated_field',
            'displayName': {'text': 'New Place From API'},
            'formattedAddress': 'New Address',
            'location': {'latitude': 3.13, 'longitude': 101.68},
            'types': ['tourist_attraction'],
          }),
          200,
        );
      });

      await PlacesApiService.getPlaceDetails('place_unrelated_field',
          client: client);

      final stored = mockStore['place_unrelated_field']!;
      expect(
          stored['userCustomNote'], equals('Preserve this user custom note'));
      expect(stored['favoriteFlag'], isTrue);
      expect(stored['displayName']['text'], equals('New Place From API'));
    });

    test(
        '16. Existing getPlaceDetails(placeId) public signature remains compatible',
        () async {
      // Calling without the optional client parameter compiles and functions normally
      final freshTime = fixedNow.subtract(const Duration(days: 10));
      mockStore['place_signature_compat'] = makeCompletePlaceData(
        placeId: 'place_signature_compat',
        cachedAtTime: freshTime,
        displayName: 'Signature Compat Place',
      );

      // Invoke without client parameter
      final result =
          await PlacesApiService.getPlaceDetails('place_signature_compat');

      expect(result['displayName']['text'], equals('Signature Compat Place'));
    });
  });
}
