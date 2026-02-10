import 'dart:convert';
import 'package:http/http.dart' as http;

class PlacesApiService {
  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc'; 
  static const String _baseUrl = 'https://places.googleapis.com/v1';

  // 📊 API 调用统计
  static int _totalApiCalls = 0;
  static int _searchNearbyCallCount = 0;
  static int _searchTextCallCount = 0;
  static int _placeDetailsCallCount = 0;
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

  /// 📄 Place Details
  static Future<Map<String, dynamic>> getPlaceDetails(String placeId) async {
    final startTime = DateTime.now();
    _totalApiCalls++;
    _placeDetailsCallCount++;

    print('');
    print('📄 ════════════════════════════════════════');
    print('📄 API Call #$_totalApiCalls: getPlaceDetails');
    print('📄 Place ID: $placeId');
    print('📄 ════════════════════════════════════════');

    final url = Uri.parse('$_baseUrl/places/$placeId');

    final response = await http.get(
      url,
      headers: _headers(
        'displayName,formattedAddress,rating,photos,regularOpeningHours,websiteUri,internationalPhoneNumber,reviews',
      ),
    );

    final duration = DateTime.now().difference(startTime);

    if (response.statusCode != 200) {
      print('❌ getPlaceDetails FAILED: ${response.body}');
      throw Exception('getPlaceDetails failed: ${response.body}');
    }

    print('✅ Place details loaded');
    print('⏱️  Duration: ${duration.inMilliseconds}ms');
    print('📄 ════════════════════════════════════════');

    return json.decode(response.body);
  }

  /// 🖼️ 生成照片 URL
  static String buildPhotoUrl(String photoName, {int maxWidth = 800}) {
    return '$_baseUrl/$photoName/media?key=$_apiKey&maxWidthPx=$maxWidth';
  }

  /// 🔧 统一整理格式
  static Map<String, dynamic> _normalizePlace(dynamic p) {
    List<Map<String, String>> photoList = [];
    if (p['photos'] != null && (p['photos'] as List).isNotEmpty) {
      final photoName = p['photos'][0]['name'];
      photoList.add({'photoUri': buildPhotoUrl(photoName)});
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