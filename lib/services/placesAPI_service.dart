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

  static Future<List<Map<String, dynamic>>> bootstrapAllNearby({
    required double lat,
    required double lng,
    int radius = 5000,
    int maxResultCount = 40,
  }) async {
    final url = Uri.parse('$_baseUrl/places:searchText');

    // ✅ 这个 query 是“覆盖你 app 一级分类”的关键
    const query =
        'restaurants cafes coffee bakery dessert shopping mall supermarket hotel lodging museum park tourist attraction bank hospital gas station';

    final body = jsonEncode({
      "textQuery": query,
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

    if (response.statusCode != 200) {
      throw Exception('bootstrapAllNearby failed: ${response.body}');
    }

    final data = json.decode(response.body);
    final List rawPlaces = data['places'] ?? [];

    return rawPlaces.map((p) {
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
    }).toList();
  }


  /// 🔍 二级筛选：Text Search（支持 keyword）
  static Future<List<Map<String, dynamic>>> searchNearby({
  required double lat,
  required double lng,
  required String type,
  int radius = 5000,
  int maxResultCount = 20,
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
    "maxResultCount": maxResultCount,
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

  return rawPlaces.map((p) {
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
  }).toList();
}

  /// 📄 获取 Place 详情（详情页用）
static Future<Map<String, dynamic>> getPlaceDetails(String placeId) async {
  final url = Uri.parse('$_baseUrl/places/$placeId');

  final response = await http.get(
    url,
    headers: _headers(
      'displayName,formattedAddress,rating,photos,'
      'regularOpeningHours,websiteUri,internationalPhoneNumber,reviews',
    ),
  );

  if (response.statusCode != 200) {
    throw Exception('getPlaceDetails failed: ${response.body}');
  }

  return json.decode(response.body);
}




  /// 📄 获取 Place 详情 (保持不变，详情页可以单独处理)
  static Future<List<Map<String, dynamic>>> searchNearbyWithKeyword({
  required double lat,
  required double lng,
  required String keyword,
  int radius = 5000,
  int maxResultCount = 20,
}) async {
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

  if (response.statusCode != 200) {
    throw Exception('searchText failed: ${response.body}');
  }

  final data = json.decode(response.body);
  final List rawPlaces = data['places'] ?? [];

  return rawPlaces.map((p) {
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
  }).toList();
}

  /// 🖼️ 生成 Google Places 照片 URL
static String buildPhotoUrl(String photoName, {int maxWidth = 800}) {
  return '$_baseUrl/$photoName/media'
         '?key=$_apiKey'
         '&maxWidthPx=$maxWidth';
}


}