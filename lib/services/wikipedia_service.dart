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
  // 🌟 PUBLIC ENTRY (WITH FIREBASE CACHE)_getImageThumbUrl
  // ============================================================
  static Future<Map<String, dynamic>> fetchLandmarkHistory(
    String landmarkName,
  ) async {

    final cached = await WikiCacheService.get(landmarkName);
    if (cached != null) {
      debugPrint('📦 Wikipedia loaded from Firebase cache');
      return cached;
    }

    debugPrint('🌐 Fetching Wikipedia from API');
    final result = await _fetchFromWikipedia(landmarkName);

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
  // 🌐 TRANSLATION
  //
  // Strategy:
  //   1. Langlinks  — ask English Wikipedia for the exact title in [langCode]
  //   2. Opensearch — keyword-search the target-language wiki
  //   3. Google Translate (unofficial, no API key) — translate the English
  //      extract directly. Used when the landmark has no Wikipedia page in
  //      the target language (e.g. "Kuala Lumpur City Gallery" in zh).
  //
  // [title]       — landmark name (English)
  // [langCode]    — e.g. 'zh', 'zh-tw', 'ms', 'ja', 'ko', 'fr', 'ar'
  // [englishText] — the English extract already shown on screen; used as
  //                 the translation source when Wikipedia has no page.
  // ============================================================
  static Future<Map<String, dynamic>> fetchSummaryInLanguage(
    String title,
    String langCode,
    String englishText,
  ) async {
    final baseLang = langCode.split('-').first; // 'zh-tw' → 'zh'
    final extraHeaders = <String, String>{
      if (langCode == 'zh-tw') 'Accept-Language': 'zh-TW',
    };

    // ── Layer 1: langlinks ───────────────────────────────────────────────
    final linkedTitle = await _resolveViaLanglinks(title, baseLang);
    debugPrint('🔗 [Langlinks] $linkedTitle');

    final candidate = linkedTitle ?? title;
    final wikiResult = await _fetchWikiSummary(candidate, baseLang, extraHeaders);
    if (wikiResult != null) {
      debugPrint('✅ [Translation] Wikipedia hit for "$candidate"');
      return wikiResult;
    }

    // ── Layer 2: opensearch ──────────────────────────────────────────────
    final searchedTitle = await _opensearch(title, baseLang);
    debugPrint('🔍 [Opensearch] $searchedTitle');
    if (searchedTitle != null) {
      final wikiResult2 =
          await _fetchWikiSummary(searchedTitle, baseLang, extraHeaders);
      if (wikiResult2 != null) {
        debugPrint('✅ [Translation] Wikipedia hit via opensearch');
        return wikiResult2;
      }
    }

    // ── Layer 3: Google Translate the English extract ────────────────────
    debugPrint('🔤 [Translation] No Wikipedia page — falling back to Google Translate');
    final translated = await _googleTranslate(englishText, langCode);
    final translatedTitle = await _googleTranslate(title, langCode);
    if (translated != null) {
      debugPrint('✅ [Translation] Google Translate success');
      return {
        'title':   translatedTitle ?? title,
        'extract': translated,
        'wikiUrl': '',
        'source':  'translated', // lets the UI show a small "Translated" badge
      };
    }

    throw Exception('Translation failed for "$title" ($langCode)');
  }

  /// Asks English Wikipedia for the page title in [baseLang] via langlinks.
  static Future<String?> _resolveViaLanglinks(
      String title, String baseLang) async {
    try {
      final uri = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query'
        '&titles=${Uri.encodeComponent(title)}'
        '&prop=langlinks'
        '&lllang=$baseLang'
        '&lllimit=1'
        '&format=json'
        '&origin=*',
      );
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final pages = data['query']?['pages'] as Map<String, dynamic>?;
      if (pages == null) return null;

      final page = pages.values.first as Map<String, dynamic>;
      final langlinks = page['langlinks'] as List?;
      if (langlinks == null || langlinks.isEmpty) return null;

      return langlinks[0]['*'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Keyword-searches [baseLang].wikipedia.org and returns the top title.
  static Future<String?> _opensearch(String query, String baseLang) async {
    try {
      final uri = Uri.parse(
        'https://$baseLang.wikipedia.org/w/api.php'
        '?action=opensearch'
        '&search=${Uri.encodeComponent(query)}'
        '&limit=1'
        '&format=json'
        '&origin=*',
      );
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as List;
      final titles = data[1] as List?;
      if (titles == null || titles.isEmpty) return null;
      return titles[0] as String?;
    } catch (_) {
      return null;
    }
  }

  /// GETs the REST summary for [title] on [baseLang].wikipedia.org.
  /// Returns null on any failure so callers can try the next layer.
  static Future<Map<String, dynamic>?> _fetchWikiSummary(
    String title,
    String baseLang,
    Map<String, String> extraHeaders,
  ) async {
    try {
      final uri = Uri.parse(
        'https://$baseLang.wikipedia.org/api/rest_v1/page/summary/'
        '${Uri.encodeComponent(title)}',
      );
      final res = await http
          .get(uri, headers: {..._headers, ...extraHeaders})
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final extract = data['extract'] as String? ?? '';
      if (extract.isEmpty) return null; // disambiguation / stub

      return {
        'title':   data['title']                             ?? title,
        'extract': extract,
        'wikiUrl': data['content_urls']?['mobile']?['page'] ?? '',
        'source':  'wikipedia',
      };
    } catch (_) {
      return null;
    }
  }

  /// Translates [text] to [targetLang] using the unofficial Google Translate
  /// endpoint — no API key required, but rate-limited for large volumes.
  /// Returns null on failure.
  static Future<String?> _googleTranslate(
      String text, String targetLang) async {
    try {
      // Map app lang codes → Google Translate codes where they differ
      final gtLang = const {
        'zh-tw': 'zh-TW',
        'zh':    'zh-CN',
        'ms':    'ms',
      }[targetLang] ?? targetLang;

      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single'
        '?client=gtx'
        '&sl=en'
        '&tl=${Uri.encodeComponent(gtLang)}'
        '&dt=t'
        '&q=${Uri.encodeComponent(text)}',
      );

      final res = await http
          .get(uri)
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as List;
      // Response structure: [ [ ["translated", "original", ...], ... ], ... ]
      final segments = data[0] as List;
      final buffer = StringBuffer();
      for (final seg in segments) {
        final chunk = (seg as List)[0];
        if (chunk is String) buffer.write(chunk);
      }
      final result = buffer.toString().trim();
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }


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


// 🖼️ PAGE IMAGES — 批量版本
// 原来：每张图单独一个请求（最多 20 个串行请求）
// 现在：先拿图片列表，再一次性批量拿所有 URL（共 2 个请求）
// ============================================================
  static Future<List<String>> fetchPageImages(String landmarkName) async {
    try {
      final title = Uri.encodeComponent(landmarkName.replaceAll(' ', '_'));

      // 第 1 个请求：拿图片 title 列表
      final listUrl = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query'
        '&titles=$title'
        '&prop=images'
        '&imlimit=40'
        '&format=json',
      );

      final listResponse = await http.get(listUrl, headers: _headers);
      if (listResponse.statusCode != 200) return [];

      final listData = jsonDecode(listResponse.body);
      final pages = listData['query']['pages'] as Map<String, dynamic>;
      if (pages.isEmpty) return [];

      final imagesList =
          pages.values.first['images'] as List<dynamic>? ?? [];
      if (imagesList.isEmpty) return [];

      // 过滤掉不需要的文件类型
      final filteredTitles = imagesList
          .map((img) => img['title'] as String)
          .where((t) => !_shouldSkipImage(t))
          .take(20) // 最多取 20 个候选，批量请求不能太长
          .toList();

      if (filteredTitles.isEmpty) return [];

      // 第 2 个请求：一次性批量拿所有图片 URL
      return await _getBatchImageUrls(filteredTitles);
    } catch (e) {
      debugPrint('⚠️ fetchPageImages error: $e');
      return [];
    }
  }

  // 过滤逻辑抽出来，复用性更好
  static bool _shouldSkipImage(String title) {
    final lower = title.toLowerCase();
    return lower.endsWith('.svg') ||
        lower.endsWith('.pdf') ||
        lower.endsWith('.tif') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.webm') ||
        lower.contains('logo') ||
        lower.contains('icon') ||
        lower.contains('map') ||
        lower.contains('flag') ||
        lower.contains('symbol');
  }

  // 批量请求：用 | 拼接所有 title，一次拿回所有 URL
  static Future<List<String>> _getBatchImageUrls(
    List<String> imageTitles,
  ) async {
    try {
      // Wikipedia API 支持用 | 分隔多个 title
      final joined =
          imageTitles.map(Uri.encodeComponent).join('%7C'); // %7C = |

      final url = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query'
        '&titles=$joined'
        '&prop=imageinfo'
        '&iiprop=url'
        '&iiurlwidth=800'
        '&format=json',
      );

      final response = await http.get(url, headers: _headers);
      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body);
      final pages = data['query']['pages'] as Map<String, dynamic>;

      final List<String> results = [];
      final Set<String> seen = {};

      for (final page in pages.values) {
        if (results.length >= _maxImages) break;

        final imageInfo = page['imageinfo'] as List<dynamic>?;
        if (imageInfo == null || imageInfo.isEmpty) continue;

        final thumbUrl = imageInfo.first['thumburl'] as String? ?? '';
        if (thumbUrl.isEmpty) continue;

        final normalized = _normalizeImageUrl(thumbUrl);
        if (seen.contains(normalized)) continue;

        seen.add(normalized);
        results.add(thumbUrl);
      }

      return results;
    } catch (e) {
      debugPrint('⚠️ _getBatchImageUrls error: $e');
      return [];
    }
  }


  // ============================================================
  // 🧹 HELPERS
  // ============================================================

  static String? _extractInfoboxField(String wikitext, String fieldName) {
    final pattern = RegExp(
      r'\|\s*' + RegExp.escape(fieldName) + r'\s*=\s*([^\|\}]+)',
      caseSensitive: false,
    );

    final match = pattern.firstMatch(wikitext);
    if (match == null) return null;

    var value = match.group(1) ?? '';
    value = value
        .replaceAll(RegExp(r'\[\[(?:[^\]]*\|)?([^\]]*)\]\]'), r'$1')
        .replaceAll(RegExp(r'\{\{[^\}]*\}\}'), '')
        .replaceAll(RegExp(r'<ref[^>]*>.*?<\/ref>', dotAll: true), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r"'{2,}"), '')
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