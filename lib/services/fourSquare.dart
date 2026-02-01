import 'dart:convert';
import 'package:http/http.dart' as http;

class FoursquareApiService {
  // 建议正式发布前把 API Key 放到 .env 文件
  static const String _apiKey = 'CAHMTZAVGH3PC2LNSVCA52YHDEDWLJAB5NEOABQVRP2RLM1I'; 
  static const String _baseUrl = 'https://api.foursquare.com/v3/places';

  static Map<String, String> _headers() {
    return {
      'Accept': 'application/json',
      'Authorization': 'Bearer $_apiKey',
    };
  }

 static Future<List<Map<String, dynamic>>> searchNearby({
  required double lat,
  required double lng,
  int radius = 5000,
  String? categoryId,
  int limit = 20,
}) async {
  final queryParams = {
    'll': '$lat,$lng',
    'radius': radius.toString(),
    'limit': limit.toString(),
    // 你可以加 query，例如二级类别关键字
    // 'query': 'korean', 
    'fields': 'fsq_id,name,location,geocodes,categories,rating,photos',
  };

  // 只有当 categoryId 有值时再加，不要传空字符串
  if (categoryId != null && categoryId.isNotEmpty) {
    queryParams['categories'] = categoryId;
  }

  final uri =
      Uri.parse('https://api.foursquare.com/v3/places/search')
          .replace(queryParameters: queryParams);

  final response = await http.get(uri, headers: _headers());
  if (response.statusCode != 200) {
    throw Exception('Foursquare search failed: ${response.body}');
  }

  final data = json.decode(response.body);
  final List rawResults = data['results'] ?? [];

  return rawResults.map((p) {
    String? photoUrl;
    if (p['photos'] != null && (p['photos'] as List).isNotEmpty) {
      final firstPhoto = p['photos'][0];
      photoUrl =
          "${firstPhoto['prefix']}original${firstPhoto['suffix']}";
    }
    return {
      'id': p['fsq_id'],
      'displayName': {'text': p['name']},
      'location': {
        'latitude':
            (p['geocodes']?['main']?['latitude']) ?? 0,
        'longitude':
            (p['geocodes']?['main']?['longitude']) ?? 0,
      },
      'formattedAddress': p['location']?['formatted_address'],
      'rating': p['rating'],
      'photos': photoUrl != null ? [
        {'photoUri': photoUrl}
      ] : [],
    };
  }).toList();
}


}