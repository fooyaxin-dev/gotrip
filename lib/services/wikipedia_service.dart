import 'dart:convert';
import 'package:http/http.dart' as http;

class WikipediaService {
  static Future<Map<String, String>> fetchLandmarkHistory(
      String landmarkName) async {
    try {
      // URL encode（防止特殊字符报错）
      final title = Uri.encodeComponent(landmarkName.replaceAll(' ', '_'));

      final url = Uri.parse(
        'https://en.wikipedia.org/api/rest_v1/page/summary/$title',
      );

      final response = await http.get(
        url,
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'TravelApp/1.0 (your@email.com)', // Wikipedia 要求
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'title': data['title'] ?? landmarkName,
          'summary': data['extract'] ?? 'No historical information available.',
          'thumbnail': data['thumbnail']?['source'] ?? '',
          'wikiUrl': data['content_urls']?['desktop']?['page'] ?? '',
        };
      } else if (response.statusCode == 404) {
        // Wikipedia 没有对应页面 → 尝试搜索
        return await searchWikipedia(landmarkName);
      } else {
        return {
          'title': landmarkName,
          'summary': 'Failed to retrieve Wikipedia data.',
          'thumbnail': '',
          'wikiUrl': '',
        };
      }
    } catch (e) {
      return {
        'title': landmarkName,
        'summary': 'Error fetching Wikipedia data.',
        'thumbnail': '',
        'wikiUrl': '',
      };
    }
  }

  /// 当直接 title 不匹配时，调用搜索 API 尝试找到最近的匹配
  static Future<Map<String, String>> searchWikipedia(String query) async {
    try {
      final searchUrl = Uri.parse(
          'https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srsearch=${Uri.encodeComponent(query)}');

      final response = await http.get(searchUrl, headers: {
        'User-Agent': 'TravelApp/1.0 (your@email.com)',
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['query']['search'] as List<dynamic>;
        if (results.isNotEmpty) {
          final firstTitle = results[0]['title'];
          // 再去拿 summary
          return fetchLandmarkHistory(firstTitle);
        }
      }
      return {
        'title': query,
        'summary': 'No historical information found.',
        'thumbnail': '',
        'wikiUrl': '',
      };
    } catch (e) {
      return {
        'title': query,
        'summary': 'Error searching Wikipedia.',
        'thumbnail': '',
        'wikiUrl': '',
      };
    }
  }
}
