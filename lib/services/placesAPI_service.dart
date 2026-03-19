import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';

class PlacesApiService {
  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc'; // String.fromEnvironment('GOOGLE_API_KEY');
  static const String _baseUrl = 'https://places.googleapis.com/v1';

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collectionName = 'place_details';

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
      final hitRate = (_cacheHits / (_cacheHits + _cacheMisses) * 100).toStringAsFixed(1);
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

  /// 🟡 searchNearby
  static Future<List<Map<String, dynamic>>> searchNearby({
    required double lat,
    required double lng,
    required String type,
    int radius = 5000,
    int maxResultCount = 20,
  }) async {
    final startTime = DateTime.now();
    _totalApiCalls++;
    _searchNearbyCallCount++;
    _callsByType[type] = (_callsByType[type] ?? 0) + 1;

    print('🟡 API Call #$_totalApiCalls: searchNearby | Type: $type');

    final url = Uri.parse('$_baseUrl/places:searchNearby');
    final body = jsonEncode({
      "locationRestriction": {
        "circle": {
          "center": {"latitude": lat, "longitude": lng},
          "radius": radius.toDouble()
        }
      },
      "includedTypes": [type],
      "maxResultCount": maxResultCount,
    });

    final response = await http.post(
      url,
      headers: _headers(
        'places.id,places.displayName,places.location,places.formattedAddress,places.types,places.rating,places.photos',
      ),
      body: body,
    );

    final duration = DateTime.now().difference(startTime);

    if (response.statusCode != 200) {
      throw Exception('searchNearby failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];
    print('✅ searchNearby: ${rawPlaces.length} places (${duration.inMilliseconds}ms)');
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
        'places.id,places.displayName,places.location,places.formattedAddress,places.types,places.rating,places.photos',
      ),
      body: body,
    );

    final duration = DateTime.now().difference(startTime);

    if (response.statusCode != 200) {
      throw Exception('searchText failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];
    print('✅ searchText: ${rawPlaces.length} places (${duration.inMilliseconds}ms)');
    return rawPlaces.map(_normalizePlace).toList();
  }

  /// 🔍 Autocomplete — 用户输入时显示地点建议
  static Future<List<Map<String, dynamic>>> autocomplete({
    required String input,
    double? lat,
    double? lng,
    int radius = 50000, // 50km bias，不是 restrict
  }) async {
    if (input.trim().isEmpty) return [];
 
    final url = Uri.parse('$_baseUrl/places:autocomplete');
 
    final body = <String, dynamic>{
      'input': input,
    };
 
    // 如果有当前位置，加上 location bias（结果会偏向附近）
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
      headers: _headers('suggestions.placePrediction.placeId,suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat'),
      body: jsonEncode(body),
    );
 
    if (response.statusCode != 200) {
      print('❌ Autocomplete failed: ${response.body}');
      return [];
    }
 
    final data = json.decode(response.body);
    final suggestions = (data['suggestions'] as List?) ?? [];
 
    return suggestions.map((s) {
      final pred = s['placePrediction'];
      return {
        'placeId':     pred['placeId'] ?? '',
        'description': pred['text']?['text'] ?? '',
        'mainText':    pred['structuredFormat']?['mainText']?['text'] ?? '',
        'secondaryText': pred['structuredFormat']?['secondaryText']?['text'] ?? '',
      };
    }).where((s) => (s['placeId'] as String).isNotEmpty).toList();
  }
 
  /// 📍 通过 placeId 拿坐标（用于 autocomplete 选完之后定位）
  static Future<Map<String, dynamic>?> getPlaceLatLng(String placeId) async {
    final url = Uri.parse('$_baseUrl/places/$placeId');
    final response = await http.get(
      url,
      headers: _headers('displayName,formattedAddress,location'),
    );
 
    if (response.statusCode != 200) {
      print('❌ getPlaceLatLng failed: ${response.body}');
      return null;
    }
 
    final data = json.decode(response.body);
    return {
      'name':    data['displayName']?['text'] ?? '',
      'address': data['formattedAddress'] ?? '',
      'lat':     data['location']?['latitude'],
      'lng':     data['location']?['longitude'],
    };
  }
 


  /// 📄 Place Details (带 Firebase 缓存)
  static Future<Map<String, dynamic>> getPlaceDetails(String placeId) async {
    final startTime = DateTime.now();
    print('📄 getPlaceDetails: $placeId');

    try {
      print('💾 Checking Firebase cache...');
      final docSnapshot = await _firestore
          .collection(_collectionName)
          .doc(placeId)
          .get();

      if (docSnapshot.exists) {
        final cachedData = docSnapshot.data()!;

        final hasTypes = cachedData.containsKey('types') &&
            (cachedData['types'] as List?)?.isNotEmpty == true;
        final hasLocation = cachedData.containsKey('location');

        if (hasTypes && hasLocation) {
          _cacheHits++;
          print('✅ CACHE HIT (${DateTime.now().difference(startTime).inMilliseconds}ms)');
          return cachedData;
        } else {
          print('⚠️ Cache outdated (missing types or location), re-fetching...');
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
          'displayName,formattedAddress,rating,userRatingCount,photos,regularOpeningHours,websiteUri,internationalPhoneNumber,reviews,types,location',
        ),
      );

      if (response.statusCode != 200) {
        throw Exception('getPlaceDetails failed: ${response.body}');
      }

      final data = json.decode(response.body);

      await _firestore.collection(_collectionName).doc(placeId).set({
        ...data,
        'cachedAt': FieldValue.serverTimestamp(),
      });

      print('✅ Fetched & cached (${DateTime.now().difference(startTime).inMilliseconds}ms)');
      return data;

    } catch (e) {
      print('❌ Error in getPlaceDetails: $e');
      rethrow;
    }
  }
    
  /// 🗑️ 清除指定地点缓存
  static Future<void> clearPlaceCache(String placeId) async {
    try {
      await _firestore.collection(_collectionName).doc(placeId).delete();
      print('🗑️ Cache cleared for place: $placeId');
    } catch (e) {
      print('❌ Failed to clear cache: $e');
    }
  }

  /// 🗑️ 清除所有缓存
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

  /// 📊 获取缓存统计
  static Future<Map<String, dynamic>> getCacheStats() async {
    try {
      final snapshot = await _firestore.collection(_collectionName).get();
      return {
        'totalCachedPlaces': snapshot.docs.length,
        'cacheHits': _cacheHits,
        'cacheMisses': _cacheMisses,
        'hitRate': _cacheHits + _cacheMisses > 0
            ? (_cacheHits / (_cacheHits + _cacheMisses) * 100).toStringAsFixed(1)
            : '0.0',
      };
    } catch (e) {
      return {'totalCachedPlaces': 0, 'cacheHits': _cacheHits, 'cacheMisses': _cacheMisses, 'hitRate': '0.0'};
    }
  }

  /// 🖼️ 生成照片 URL
  static String buildPhotoUrl(String photoName, {int maxWidth = 800}) {
    return '$_baseUrl/$photoName/media?key=$_apiKey&maxWidthPx=$maxWidth';
  }

  /// 🔧 统一整理格式
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
      'photos': photoList,
      'source': 'google',
    };
  }
} 