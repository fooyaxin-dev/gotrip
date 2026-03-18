import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'wikiCache_service.dart';

class WikipediaService {
  static const _headers = {
    'Accept': 'application/json',
    'User-Agent': 'TravelApp/1.0 (your@email.com)',
  };

  static const int _maxImages = 10;

  // ============================================================
  // 🌟 PUBLIC ENTRY (WITH FIREBASE CACHE)
  // ============================================================
  static Future<Map<String, dynamic>> fetchLandmarkHistory(
    String landmarkName,
  ) async {
    // 1️⃣ 查 Firebase cache
    final cached = await WikiCacheService.get(landmarkName);
    if (cached != null) {
      debugPrint('📦 Wikipedia loaded from Firebase cache');
      return cached;
    }

    // 2️⃣ 没有 cache → 调 Wikipedia API
    debugPrint('🌐 Fetching Wikipedia from API');
    final result = await _fetchFromWikipedia(landmarkName);

    // 3️⃣ 成功才写 cache
    if (result['summary'] != null &&
        result['summary'].toString().isNotEmpty) {
      await WikiCacheService.save(landmarkName, result);
    }

    return result;
  }

  // ============================================================
  // 🎫 ADMISSION INFO (from Wikipedia Infobox)
  // Returns admission string if found, null otherwise.
  // Examples: "Free", "£25", "€18 adults / €9 children"
  // ============================================================
  static Future<String?> fetchAdmissionInfo(String landmarkName) async {
    try {
      final title = Uri.encodeComponent(landmarkName.replaceAll(' ', '_'));

      // Fetch raw wikitext — the infobox lives here
      final url = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query'
        '&titles=$title'
        '&prop=revisions'
        '&rvprop=content'
        '&rvslots=main'
        '&format=json'
        '&formatversion=2',
      );

      final response = await http.get(url, headers: _headers);
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final pages = data['query']?['pages'] as List?;
      if (pages == null || pages.isEmpty) return null;

      final content =
          pages[0]['revisions']?[0]?['slots']?['main']?['content'] as String?;
      if (content == null) return null;

      return _extractInfoboxField(content, 'admission');
    } catch (e) {
      debugPrint('⚠️ fetchAdmissionInfo error: $e');
      return null;
    }
  }

  // ============================================================
  // 🔒 ORIGINAL LOGIC (UNTOUCHED)
  // ============================================================
  static Future<Map<String, dynamic>> _fetchFromWikipedia(
    String landmarkName,
  ) async {
    try {
      final title = Uri.encodeComponent(landmarkName.replaceAll(' ', '_'));

      final summaryUrl = Uri.parse(
        'https://en.wikipedia.org/api/rest_v1/page/summary/$title',
      );

      final response = await http.get(summaryUrl, headers: _headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // 1️⃣ summary 的 thumbnail（兜底）
        final String? thumb = data['thumbnail']?['source'];

        // 2️⃣ 页面图片
        final moreImages = await fetchPageImages(landmarkName);

        // 3️⃣ 选择策略
        List<String> finalImages = [];

        if (moreImages.isNotEmpty) {
          final Set<String> seen = {};
          final List<String> uniqueImages = [];

          for (final img in moreImages) {
            if (uniqueImages.length >= _maxImages) break;

            final normalized = _normalizeImageUrl(img);
            if (seen.contains(normalized)) continue;

            seen.add(normalized);
            uniqueImages.add(img);
          }

          finalImages = uniqueImages;
        } else if (thumb != null && thumb.isNotEmpty) {
          finalImages = [thumb];
        }

        return {
          'title': data['title'] ?? landmarkName,
          'summary': data['extract'] ?? 'No historical information available.',
          'images': finalImages,
          'wikiUrl': data['content_urls']?['desktop']?['page'] ?? '',
        };
      } else if (response.statusCode == 404) {
        return await searchWikipedia(landmarkName);
      } else {
        return _emptyResult(landmarkName);
      }
    } catch (e) {
      return _emptyResult(landmarkName);
    }
  }

  // ============================================================
  // 🔁 SEARCH FALLBACK
  // ============================================================
  static Future<Map<String, dynamic>> searchWikipedia(
    String query,
  ) async {
    try {
      final searchUrl = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query'
        '&list=search'
        '&format=json'
        '&srsearch=${Uri.encodeComponent(query)}',
      );

      final response = await http.get(searchUrl, headers: _headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['query']['search'] as List<dynamic>;

        if (results.isNotEmpty) {
          final firstTitle = results.first['title'];
          return _fetchFromWikipedia(firstTitle);
        }
      }
      return _emptyResult(query);
    } catch (e) {
      return _emptyResult(query);
    }
  }

  // ============================================================
  // 🖼️ PAGE IMAGES
  // ============================================================
  static Future<List<String>> fetchPageImages(String landmarkName) async {
    try {
      final title = Uri.encodeComponent(landmarkName.replaceAll(' ', '_'));

      final url = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query'
        '&titles=$title'
        '&prop=images'
        '&imlimit=40'
        '&format=json',
      );

      final response = await http.get(url, headers: _headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final pages = data['query']['pages'] as Map<String, dynamic>;

        if (pages.isNotEmpty) {
          final pageData = pages.values.first;
          final imagesList = pageData['images'] as List<dynamic>?;

          if (imagesList == null || imagesList.isEmpty) return [];

          final List<String> results = [];

          for (final img in imagesList) {
            if (results.length >= 20) break;

            final String imgTitle = img['title'];
            final lower = imgTitle.toLowerCase();

            if (lower.endsWith('.svg') ||
                lower.endsWith('.pdf') ||
                lower.endsWith('.tif') ||
                lower.endsWith('.ogg') ||
                lower.endsWith('.webm') ||
                lower.contains('logo') ||
                lower.contains('icon') ||
                lower.contains('map') ||
                lower.contains('flag') ||
                lower.contains('symbol')) {
              continue;
            }

            final thumbUrl = await _getImageThumbUrl(imgTitle);
            if (thumbUrl.isNotEmpty) {
              results.add(thumbUrl);
            }
          }

          return results;
        }
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  // ============================================================
  // 🔍 IMAGE THUMB
  // ============================================================
  static Future<String> _getImageThumbUrl(String imageTitle) async {
    try {
      final url = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query'
        '&titles=${Uri.encodeComponent(imageTitle)}'
        '&prop=imageinfo'
        '&iiprop=url'
        '&iiurlwidth=800'
        '&format=json',
      );

      final response = await http.get(url, headers: _headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final pages = data['query']['pages'] as Map<String, dynamic>;

        if (pages.isNotEmpty) {
          final pageData = pages.values.first;
          final imageInfo = pageData['imageinfo'] as List<dynamic>?;

          if (imageInfo != null && imageInfo.isNotEmpty) {
            return imageInfo.first['thumburl'] ?? '';
          }
        }
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  // ============================================================
  // 🧹 HELPERS
  // ============================================================

  /// Extracts a named field from a Wikipedia infobox wikitext string.
  /// e.g. _extractInfoboxField(content, 'admission') → "Free" or "£25"
  static String? _extractInfoboxField(String wikitext, String fieldName) {
    // Match "| fieldName = value" — handles spaces and optional newlines
    final pattern = RegExp(
      r'\|\s*' + RegExp.escape(fieldName) + r'\s*=\s*([^\|\}]+)',
      caseSensitive: false,
    );

    final match = pattern.firstMatch(wikitext);
    if (match == null) return null;

    // Strip wikitext markup: [[links]], {{templates}}, <ref>...</ref>, etc.
    var value = match.group(1) ?? '';
    value = value
        .replaceAll(RegExp(r'\[\[(?:[^\]]*\|)?([^\]]*)\]\]'), r'$1') // [[link|text]] → text
        .replaceAll(RegExp(r'\{\{[^\}]*\}\}'), '')                    // {{template}} → ''
        .replaceAll(RegExp(r'<ref[^>]*>.*?<\/ref>', dotAll: true), '') // <ref>...</ref> → ''
        .replaceAll(RegExp(r'<[^>]+>'), '')                           // any remaining HTML tags
        .replaceAll(RegExp(r"'{2,}"), '')                             // bold/italic ''
        .trim();

    return value.isEmpty ? null : value;
  }

  static String _normalizeImageUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}${uri.path}';
    } catch (_) {
      return url;
    }
  }

  static Map<String, dynamic> _emptyResult(String name) {
    return {
      'title': name,
      'summary': 'Failed to retrieve Wikipedia data.',
      'images': <String>[],
      'wikiUrl': '',
    };
  }

  
}