import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';

class PlacesApiService {
  static const String _apiKey = '';//'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc'; 
  static const String _baseUrl = 'https://places.googleapis.com/v1';

  // Firebase Firestore 实例
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collectionName = 'place_details'; // Firestore 集合名称

  // 📊 API 调用统计
  static int _totalApiCalls = 0;
  static int _searchNearbyCallCount = 0;
  static int _searchTextCallCount = 0;
  static int _placeDetailsCallCount = 0;
  static int _cacheHits = 0; // 缓存命中次数
  static int _cacheMisses = 0; // 缓存未命中次数
  static final Map<String, int> _callsByType = {};

  static Map<String, String> _headers(String fieldMask) {
    return {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': _apiKey,
      'X-Goog-FieldMask': fieldMask,
    };
  }

  // 📈 获取统计信息
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

  // 🔄 重置统计
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

  /// 🟡 一级分类 searchNearby
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

    print('');
    print('🟡 ════════════════════════════════════════');
    print('🟡 API Call #$_totalApiCalls: searchNearby');
    print('🟡 Type: $type');
    print('🟡 Location: ($lat, $lng)');
    print('🟡 Radius: ${radius}m, Max: $maxResultCount');
    print('🟡 ════════════════════════════════════════');

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
      print('❌ searchNearby FAILED: ${response.body}');
      throw Exception('searchNearby failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];
    
    print('✅ Response: ${rawPlaces.length} places found');
    print('⏱️  Duration: ${duration.inMilliseconds}ms');
    print('🟡 ════════════════════════════════════════');

    return rawPlaces.map(_normalizePlace).toList();
  }

  // 🔵 二级关键词 searchText
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

    print('');
    print('🔵 ════════════════════════════════════════');
    print('🔵 API Call #$_totalApiCalls: searchText');
    print('🔵 Keyword: "$keyword"');
    print('🔵 Location: ($lat, $lng)');
    print('🔵 Radius: ${radius}m, Max: $maxResultCount');
    print('🔵 ════════════════════════════════════════');

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
      print('❌ searchText FAILED: ${response.body}');
      throw Exception('searchText failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];

    print('✅ Response: ${rawPlaces.length} places found');
    print('⏱️  Duration: ${duration.inMilliseconds}ms');
    print('🔵 ════════════════════════════════════════');

    return rawPlaces.map(_normalizePlace).toList();
  }

  /// 📄 Place Details (带 Firebase 缓存)
  static Future<Map<String, dynamic>> getPlaceDetails(String placeId) async {
    final startTime = DateTime.now();

    print('');
    print('📄 ════════════════════════════════════════');
    print('📄 getPlaceDetails Request');
    print('📄 Place ID: $placeId');
    print('📄 ════════════════════════════════════════');

    try {
      // 🔍 Step 1: 先查询 Firebase 缓存
      print('💾 Checking Firebase cache...');
      final docSnapshot = await _firestore
          .collection(_collectionName)
          .doc(placeId)
          .get();

      if (docSnapshot.exists) {
        // ✅ 缓存命中
        _cacheHits++;
        final cachedData = docSnapshot.data()!;
        final duration = DateTime.now().difference(startTime);
        
        print('✅ CACHE HIT! Data loaded from Firebase');
        print('⏱️  Duration: ${duration.inMilliseconds}ms');
        print('📊 Cache Stats: Hits=$_cacheHits, Misses=$_cacheMisses');
        print('📄 ════════════════════════════════════════');
        
        return cachedData;
      }

      // ❌ 缓存未命中，需要调用 API
      _cacheMisses++;
      _totalApiCalls++;
      _placeDetailsCallCount++;
      
      print('❌ CACHE MISS! Fetching from Google Places API...');

      // 🌐 Step 2: 调用 Google Places API
      final url = Uri.parse('$_baseUrl/places/$placeId');

      final response = await http.get(
        url,
        headers: _headers(
          'displayName,formattedAddress,rating,photos,regularOpeningHours,websiteUri,internationalPhoneNumber,reviews',
        ),
      );

      if (response.statusCode != 200) {
        print('❌ API Request FAILED: ${response.body}');
        throw Exception('getPlaceDetails failed: ${response.body}');
      }

      final data = json.decode(response.body);

      // 💾 Step 3: 保存到 Firebase 缓存
      print('💾 Saving to Firebase cache...');
      await _firestore
          .collection(_collectionName)
          .doc(placeId)
          .set({
            ...data,
            'cachedAt': FieldValue.serverTimestamp(), // 记录缓存时间
          });

      final duration = DateTime.now().difference(startTime);
      print('✅ API Response received and cached');
      print('⏱️  Duration: ${duration.inMilliseconds}ms');
      print('📊 Cache Stats: Hits=$_cacheHits, Misses=$_cacheMisses');
      print('📄 ════════════════════════════════════════');

      return data;

    } catch (e) {
      print('❌ Error in getPlaceDetails: $e');
      print('📄 ════════════════════════════════════════');
      rethrow;
    }
  }

  /// 🗑️ 清除指定地点的缓存（可选功能）
  static Future<void> clearPlaceCache(String placeId) async {
    try {
      await _firestore.collection(_collectionName).doc(placeId).delete();
      print('🗑️ Cache cleared for place: $placeId');
    } catch (e) {
      print('❌ Failed to clear cache: $e');
    }
  }

  /// 🗑️ 清除所有缓存（谨慎使用！）
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
      final totalCached = snapshot.docs.length;
      
      return {
        'totalCachedPlaces': totalCached,
        'cacheHits': _cacheHits,
        'cacheMisses': _cacheMisses,
        'hitRate': _cacheHits + _cacheMisses > 0 
            ? (_cacheHits / (_cacheHits + _cacheMisses) * 100).toStringAsFixed(1)
            : '0.0',
      };
    } catch (e) {
      print('❌ Failed to get cache stats: $e');
      return {
        'totalCachedPlaces': 0,
        'cacheHits': _cacheHits,
        'cacheMisses': _cacheMisses,
        'hitRate': '0.0',
      };
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
      // 获取所有照片，不只是第一张
      for (var photo in (p['photos'] as List)) {
        final photoName = photo['name'];
        photoList.add({'photoUri': buildPhotoUrl(photoName)});
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