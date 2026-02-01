import 'dart:convert';
import 'package:http/http.dart' as http;

class PlacesApiService {
  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc'; // 建议使用环境变量
  static const String _baseUrl = 'https://places.googleapis.com/v1';

  static Map<String, String> _headers(String fieldMask) {
    return {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': _apiKey,
      'X-Goog-FieldMask': fieldMask,
    };
  }

  /// 🔍 搜索附近地点
  static Future<List<Map<String, dynamic>>> searchNearby({
    required double lat,
    required double lng,
    required String type,
    int radius = 5000,
  }) async {
    final url = Uri.parse('$_baseUrl/places:searchNearby');

    final body = jsonEncode({
      "locationRestriction": {
        "circle": {
          "center": {"latitude": lat, "longitude": lng},
          "radius": radius.toDouble()
        }
      },
      "includedTypes": [type],
      "maxResultCount": 20
    });

    final response = await http.post(
      url,
      headers: _headers(
        'places.id,places.displayName,places.location,places.formattedAddress,places.types,places.rating,places.photos',
      ),
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception('searchNearby failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];

    // 🧹 数据清洗：确保格式与 Foursquare 统一
    return rawPlaces.map((p) {
      List<Map<String, String>> photoList = [];
      if (p['photos'] != null && (p['photos'] as List).isNotEmpty) {
        // 直接在这里把 Google 的 photo name 转成可用的 URL
        final photoName = p['photos'][0]['name'];
        photoList.add({
          'photoUri': buildPhotoUrl(photoName),
        });
      }

      return {
        'id': p['id'],
        'displayName': p['displayName'], // 已经是 {'text': '...'} 格式
        'formattedAddress': p['formattedAddress'] ?? '',
        'location': {
          'latitude': p['location']['latitude'],
          'longitude': p['location']['longitude'],
        },
        'rating': p['rating']?.toDouble(),
        'photos': photoList,
        'source': 'google', // 标记来源方便调试
      };
    }).toList();
  }

  /// 📄 获取 Place 详情 (保持不变，详情页可以单独处理)
  static Future<Map<String, dynamic>> getPlaceDetails(String placeId) async {
    final url = Uri.parse('$_baseUrl/places/$placeId');
    final response = await http.get(
      url,
      headers: _headers(
        'displayName,formattedAddress,rating,photos,regularOpeningHours,websiteUri,internationalPhoneNumber,reviews',
      ),
    );
    if (response.statusCode != 200) throw Exception('getPlaceDetails failed');
    return json.decode(response.body);
  }

  /// 🖼️ 生成照片 URL
  static String buildPhotoUrl(String photoName, {int maxWidth = 800}) {
    return '$_baseUrl/$photoName/media?key=$_apiKey&maxWidthPx=$maxWidth';
  }
}