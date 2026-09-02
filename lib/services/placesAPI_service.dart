import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'api_Keys.dart';
import '../models/placeModel.dart';

class PlacesApiService {
  static const String _apiKey = ApiKeys.googlePlacesNew;
  static const String _baseUrl = 'https://places.googleapis.com/v1';

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collectionName = 'place_details';

  // Cache for geo_ → Google Place ID lookups (in-memory, per session)
  // Key: 'geo_placeId', Value: Google Place ID e.g. 'ChIJ...'
  static final Map<String, String> _geoToGoogleIdCache = {};

  static int _totalApiCalls = 0;
  static int _searchNearbyCallCount = 0;
  static int _searchTextCallCount = 0;
  static int _placeDetailsCallCount = 0;
  static int _cacheHits = 0;
  static int _cacheMisses = 0;
  static final Map<String, int> _callsByType = {};

  static Map<String, String> _headers(String fieldMask) {
    return {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': _apiKey,
      'X-Goog-FieldMask': fieldMask,
    };
  }

  static void printStats() {
    print('╔════════════════════════════════════════╗');
    print('║   📊 API Call Statistics               ║');
    print('╠════════════════════════════════════════╣');
    print('║ Total API Calls: $_totalApiCalls');
    print('║ - searchNearby: $_searchNearbyCallCount');
    print('║ - searchText: $_searchTextCallCount');
    print('║ - placeDetails: $_placeDetailsCallCount');
    print('╠════════════════════════════════════════╣');
    print('║ 💾 Cache Performance:');
    print('║ - Cache Hits: $_cacheHits');
    print('║ - Cache Misses: $_cacheMisses');
    if (_cacheHits + _cacheMisses > 0) {
      final hitRate =
          (_cacheHits / (_cacheHits + _cacheMisses) * 100).toStringAsFixed(1);
      print('║ - Hit Rate: $hitRate%');
    }
    print('╠════════════════════════════════════════╣');
    if (_callsByType.isNotEmpty) {
      print('║ Calls by Type:');
      _callsByType.forEach((type, count) {
        print('║   - $type: $count');
      });
    }
    print('╚════════════════════════════════════════╝');
  }

  static void resetStats() {
    _totalApiCalls = 0;
    _searchNearbyCallCount = 0;
    _searchTextCallCount = 0;
    _placeDetailsCallCount = 0;
    _cacheHits = 0;
    _cacheMisses = 0;
    _callsByType.clear();
    print('📊 API stats reset');
  }

  // ── 🔍 Find Google Place ID for a Geoapify place ─────────────────────────
  // Called only when user taps into a Geoapify place's detail page.
  // Uses Text Search with name + coords to find the matching Google Place ID.
  // Result is cached in Firestore so the same place is never looked up twice.
  static Future<String?> findGooglePlaceId({
    required String geoInternalId, // our 'geo_xxx' id — used as cache key
    required String placeName,
    required double lat,
    required double lng,
  }) async {
    // 1. Check in-memory cache first (same session)
    if (_geoToGoogleIdCache.containsKey(geoInternalId)) {
      print('🧠 findGooglePlaceId: in-memory hit for $placeName');
      return _geoToGoogleIdCache[geoInternalId];
    }

    // 2. Check Firestore cache (persists across sessions)
    try {
      final cacheDoc = await _firestore
          .collection('geo_to_google_id')
          .doc(geoInternalId)
          .get();

      if (cacheDoc.exists) {
        final googleId = cacheDoc.data()?['googlePlaceId'] as String?;
        if (googleId != null && googleId.isNotEmpty) {
          print(
              '💾 findGooglePlaceId: Firestore hit for $placeName → $googleId');
          _geoToGoogleIdCache[geoInternalId] = googleId;
          return googleId;
        }
      }
    } catch (e) {
      print('⚠️ findGooglePlaceId: Firestore cache check failed: $e');
    }

    // 3. Call Google Text Search API
    print('🔵 findGooglePlaceId: Text Search for "$placeName" at ($lat, $lng)');
    _totalApiCalls++;
    _searchTextCallCount++;

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/places:searchText'),
        headers: _headers('places.id,places.displayName,places.location'),
        body: jsonEncode({
          'textQuery': placeName,
          'locationBias': {
            'circle': {
              'center': {'latitude': lat, 'longitude': lng},
              'radius': 100.0, // tight radius — we know the coords
            }
          },
          'maxResultCount': 1,
        }),
      );

      if (response.statusCode != 200) {
        print('❌ findGooglePlaceId: Text Search failed ${response.statusCode}');
        return null;
      }

      final data = json.decode(response.body);
      final places = data['places'] as List?;
      if (places == null || places.isEmpty) {
        print('⚠️ findGooglePlaceId: no results for "$placeName"');
        return null;
      }

      final googleId = places[0]['id'] as String?;
      if (googleId == null || googleId.isEmpty) return null;

      print('✅ findGooglePlaceId: "$placeName" → $googleId');

      // 4. Save to Firestore cache so we never call this again for the same place
      _firestore.collection('geo_to_google_id').doc(geoInternalId).set({
        'googlePlaceId': googleId,
        'placeName': placeName,
        'lat': lat,
        'lng': lng,
        'cachedAt': FieldValue.serverTimestamp(),
      });

      _geoToGoogleIdCache[geoInternalId] = googleId;
      return googleId;
    } catch (e) {
      print('❌ findGooglePlaceId exception: $e');
      return null;
    }
  }

  /// 🟡 searchNearby
  ///
  /// 📏 rankPreference defaults to DISTANCE (Google's own default is
  /// POPULARITY). This matters because maxResultCount is hard-capped at 20
  /// by Google — with POPULARITY ranking, a big/far-reaching `radius` can
  /// let popular-but-far places take up slots in that top-20 and push out
  /// closer-but-less-famous ones. DISTANCE guarantees the 20 returned are
  /// always the 20 physically nearest to (lat, lng), so results stay
  /// correct even when we intentionally fetch at a large radius (to cache
  /// it once) and filter locally to a smaller radius afterwards.
  static Future<List<Map<String, dynamic>>> searchNearby({
    required double lat,
    required double lng,
    List<String>? types,
    int radius = 5000,
    int maxResultCount = 20,
    String rankPreference = 'DISTANCE', // or 'POPULARITY'
  }) async {
    final startTime = DateTime.now();
    _totalApiCalls++;
    _searchNearbyCallCount++;

    final label = types == null ? 'ALL' : types.first;
    print(
        '🟡 API Call #$_totalApiCalls: searchNearby | $label | rank=$rankPreference');

    final Map<String, dynamic> bodyMap = {
      "locationRestriction": {
        "circle": {
          "center": {"latitude": lat, "longitude": lng},
          "radius": radius.toDouble()
        }
      },
      "maxResultCount": maxResultCount,
      "rankPreference": rankPreference,
    };

    if (types != null && types.isNotEmpty) {
      bodyMap["includedTypes"] = types;
    }

    final response = await http.post(
      Uri.parse('$_baseUrl/places:searchNearby'),
      headers: _headers(
        'places.id,places.displayName,places.location,places.formattedAddress,places.types,places.rating,places.userRatingCount,places.photos,places.priceLevel,places.regularOpeningHours.openNow,places.regularOpeningHours.periods,places.utcOffsetMinutes',
      ),
      body: jsonEncode(bodyMap),
    );

    final duration = DateTime.now().difference(startTime);
    if (response.statusCode != 200) {
      throw Exception('searchNearby failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];
    print(
        '✅ searchNearby: ${rawPlaces.length} places (${duration.inMilliseconds}ms)');
    return rawPlaces.map(_normalizePlace).toList();
  }

  /// 🔵 searchText
  static Future<List<Map<String, dynamic>>> searchNearbyWithKeyword({
    required double lat,
    required double lng,
    required String keyword,
    int radius = 5000,
    int maxResultCount = 20,
  }) async {
    final startTime = DateTime.now();
    _totalApiCalls++;
    _searchTextCallCount++;

    print('🔵 API Call #$_totalApiCalls: searchText | Keyword: "$keyword"');

    final url = Uri.parse('$_baseUrl/places:searchText');
    final body = jsonEncode({
      "textQuery": keyword,
      "locationBias": {
        "circle": {
          "center": {"latitude": lat, "longitude": lng},
          "radius": radius.toDouble()
        }
      },
      "maxResultCount": maxResultCount,
    });

    final response = await http.post(
      url,
      headers: _headers(
        'places.id,places.displayName,places.location,places.formattedAddress,places.types,places.rating,places.userRatingCount,places.photos,places.priceLevel,places.regularOpeningHours.openNow,places.regularOpeningHours.periods,places.utcOffsetMinutes',
      ),
      body: body,
    );

    final duration = DateTime.now().difference(startTime);
    if (response.statusCode != 200) {
      throw Exception('searchText failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];
    print(
        '✅ searchText: ${rawPlaces.length} places (${duration.inMilliseconds}ms)');
    return rawPlaces.map(_normalizePlace).toList();
  }

  /// 🔍 Autocomplete
  static Future<List<Map<String, dynamic>>> autocomplete({
    required String input,
    double? lat,
    double? lng,
    int radius = 50000,
  }) async {
    if (input.trim().isEmpty) return [];

    final url = Uri.parse('$_baseUrl/places:autocomplete');
    final body = <String, dynamic>{'input': input};

    if (lat != null && lng != null) {
      body['locationBias'] = {
        'circle': {
          'center': {'latitude': lat, 'longitude': lng},
          'radius': radius.toDouble(),
        }
      };
    }

    final response = await http.post(
      url,
      headers: _headers(
          'suggestions.placePrediction.placeId,suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat'),
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      print('❌ Autocomplete failed: ${response.body}');
      return [];
    }

    final data = json.decode(response.body);
    final suggestions = (data['suggestions'] as List?) ?? [];

    return suggestions
        .map((s) {
          final pred = s['placePrediction'];
          return {
            'placeId': pred['placeId'] ?? '',
            'description': pred['text']?['text'] ?? '',
            'mainText': pred['structuredFormat']?['mainText']?['text'] ?? '',
            'secondaryText':
                pred['structuredFormat']?['secondaryText']?['text'] ?? '',
          };
        })
        .where((s) => (s['placeId'] as String).isNotEmpty)
        .toList();
  }

  /// 📍 Get lat/lng from place ID
  static Future<Map<String, dynamic>?> getPlaceLatLng(String placeId) async {
    final url = Uri.parse('$_baseUrl/places/$placeId');
    final response = await http.get(
      url,
      headers:
          _headers('displayName,formattedAddress,location,types'), // ← 加 types
    );

    if (response.statusCode != 200) {
      print('❌ getPlaceLatLng failed: ${response.body}');
      return null;
    }

    final data = json.decode(response.body);
    return {
      'name': data['displayName']?['text'] ?? '',
      'address': data['formattedAddress'] ?? '',
      'lat': data['location']?['latitude'],
      'lng': data['location']?['longitude'],
      'types': (data['types'] as List?)?.cast<String>() ?? <String>[], // ← 加这行
    };
  }

  /// 📄 Place Details (with Firebase cache)
  static Future<Map<String, dynamic>> getPlaceDetails(String placeId) async {
    final startTime = DateTime.now();
    print('📄 getPlaceDetails: $placeId');

    try {
      print('💾 Checking Firebase cache...');
      final docSnapshot =
          await _firestore.collection(_collectionName).doc(placeId).get();

      if (docSnapshot.exists) {
        final cachedData = docSnapshot.data()!;

        final cachedAt = cachedData['cachedAt'];
        bool isExpired = true;
        if (cachedAt != null && cachedAt is Timestamp) {
          final age = DateTime.now().difference(cachedAt.toDate());
          isExpired = age.inDays > 30;
        }

        final hasTypes = cachedData.containsKey('types') &&
            (cachedData['types'] as List?)?.isNotEmpty == true;
        final hasLocation = cachedData.containsKey('location');

        if (hasTypes && hasLocation && !isExpired) {
          _cacheHits++;
          print(
              '✅ CACHE HIT (${DateTime.now().difference(startTime).inMilliseconds}ms)');
          return cachedData;
        } else {
          print('⚠️ Cache expired or outdated, re-fetching...');
          await _firestore.collection(_collectionName).doc(placeId).delete();
        }
      }

      _cacheMisses++;
      _totalApiCalls++;
      _placeDetailsCallCount++;
      print('🌐 Fetching from Google Places API...');

      final url = Uri.parse('$_baseUrl/places/$placeId');
      final response = await http.get(
        url,
        headers: _headers(
          'displayName,formattedAddress,rating,userRatingCount,photos,regularOpeningHours,websiteUri,internationalPhoneNumber,reviews,types,primaryType,location,utcOffsetMinutes',
        ),
      );

      if (response.statusCode == 404) {
        print('⚠️ Place ID invalid (404): $placeId');
        await _firestore.collection(_collectionName).doc(placeId).delete();
        throw Exception('Place ID no longer valid: $placeId');
      }

      if (response.statusCode != 200) {
        throw Exception('getPlaceDetails failed: ${response.body}');
      }

      final data = json.decode(response.body);

      await _firestore.collection(_collectionName).doc(placeId).set({
        ...data,
        'cachedAt': FieldValue.serverTimestamp(),
      });

      print(
          '✅ Fetched & cached (${DateTime.now().difference(startTime).inMilliseconds}ms)');
      return data;
    } catch (e) {
      print('❌ Error in getPlaceDetails: $e');
      rethrow;
    }
  }

  /// 🆕 把 getPlaceDetails() 的原始 Google 格式转成 PlaceModel。
  /// 专门给 RouteOptimizerPage 的候补池 lazy-hydrate 用——
  /// 存档时只存了 placeId，用户点开 "More Places" tab 才需要
  /// 把这些 id 还原成完整的 PlaceModel（走的还是原本的 Firestore 缓存，
  /// 30 天内基本不会真的打 Google API）。
  static Future<PlaceModel> getPlaceModelDetails(String placeId) async {
    final data = await getPlaceDetails(placeId); // 复用现有缓存逻辑

    final photos = data['photos'] as List?;
    final photoUrl = (photos != null && photos.isNotEmpty)
        ? buildPhotoUrl(photos[0]['name'])
        : null;

    final rawTypes =
        (data['types'] as List?)?.map((e) => e.toString()).toList() ?? [];

    final rawPeriods = (data['regularOpeningHours'] is Map)
        ? (data['regularOpeningHours']['periods'] as List?)
        : null;
    final periods = rawPeriods
        ?.map((p) => OpeningHoursPeriod.fromJson(p))
        .whereType<OpeningHoursPeriod>()
        .toList();

    return PlaceModel(
      id: placeId,
      name: data['displayName']?['text'] ?? 'Unknown',
      address: data['formattedAddress'],
      lat: (data['location']?['latitude'] as num?)?.toDouble(),
      lng: (data['location']?['longitude'] as num?)?.toDouble(),
      rating: (data['rating'] as num?)?.toDouble(),
      photoUrl: photoUrl,
      source: 'google',
      primaryType: data['primaryType'] as String?,
      allTypes: rawTypes,
      isOpenNow: data['regularOpeningHours']?['openNow'] as bool?,
      regularOpeningPeriods: periods,
      utcOffsetMinutes: (data['utcOffsetMinutes'] as num?)?.toInt(),
    );
  }

  static Future<void> clearPlaceCache(String placeId) async {
    try {
      await _firestore.collection(_collectionName).doc(placeId).delete();
      print('🗑️ Cache cleared for place: $placeId');
    } catch (e) {
      print('❌ Failed to clear cache: $e');
    }
  }

  static Future<void> clearAllCache() async {
    try {
      final batch = _firestore.batch();
      final snapshot = await _firestore.collection(_collectionName).get();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      print('🗑️ All cache cleared (${snapshot.docs.length} documents)');
    } catch (e) {
      print('❌ Failed to clear all cache: $e');
    }
  }

  static String buildPhotoUrl(String photoName, {int maxWidth = 800}) {
    return '$_baseUrl/$photoName/media?key=$_apiKey&maxWidthPx=$maxWidth';
  }

  static Map<String, dynamic> _normalizePlace(dynamic p) {
    List<Map<String, String>> photoList = [];
    if (p['photos'] != null && (p['photos'] as List).isNotEmpty) {
      for (var photo in (p['photos'] as List)) {
        photoList.add({'photoUri': buildPhotoUrl(photo['name'])});
      }
    }

    return {
      'id': p['id'],
      'displayName': p['displayName'],
      'formattedAddress': p['formattedAddress'] ?? '',
      'location': {
        'latitude': p['location']['latitude'],
        'longitude': p['location']['longitude'],
      },
      'types': (p['types'] as List?) ?? [],
      'rating': (p['rating'] as num?)?.toDouble(),
      'userRatingCount': (p['userRatingCount'] as num?)?.toInt(),
      'photos': photoList,
      'priceLevel': p['priceLevel'],
      'isOpenNow': p['regularOpeningHours']?['openNow'] as bool?,
      'regularOpeningHours': p['regularOpeningHours'],
      'utcOffsetMinutes': p['utcOffsetMinutes'],
      'source': 'google',
    };
  }
}
