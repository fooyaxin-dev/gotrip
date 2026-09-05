// ===== algolia_service.dart =====

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/postModel.dart';
import 'api_Keys.dart';

class AlgoliaService {
  static const String _appId = ApiKeys.algoliaAppId;
  static const String _adminApiKey = ApiKeys.algoliaAdminKey;
  static const String _searchApiKey = ApiKeys.algoliaSearchKey;
  static const String _indexName = 'posts';

  static String get _writeUrl =>
      'https://$_appId.algolia.net/1/indexes/$_indexName';
  static String get _searchUrl =>
      'https://$_appId-dsn.algolia.net/1/indexes/$_indexName/query';
  static String get _settingsUrl =>
      'https://$_appId.algolia.net/1/indexes/$_indexName/settings';

  static Map<String, String> get _adminHeaders => {
        'X-Algolia-Application-Id': _appId,
        'X-Algolia-API-Key': _adminApiKey,
        'Content-Type': 'application/json',
      };

  static Map<String, String> get _searchHeaders => {
        'X-Algolia-Application-Id': _appId,
        'X-Algolia-API-Key': _searchApiKey,
        'Content-Type': 'application/json',
      };

  // ═══════════════════════════════════════════════════
  // 同步帖子到 Algolia
  // ═══════════════════════════════════════════════════
  static Future<void> syncPost(
      String postId, Map<String, dynamic> postData) async {
    try {
      final algoliaData = {
        'objectID':  postId,
        'title':     postData['title']    ?? '',
        'content':   postData['content']  ?? '',
        'tags':      postData['tags']     ?? [],
        'city':      postData['city']     ?? '',
        'location':  postData['location'] ?? '',
        'userName':  postData['isAnonymous'] == true
            ? 'Anonymous'
            : (postData['userName'] ?? ''),
        'likes':      postData['likes']      ?? 0,
        'visibility': postData['visibility'] ?? 'public',
        'createdAt':  DateTime.now().millisecondsSinceEpoch,
      };

      final response = await http.put(
        Uri.parse('$_writeUrl/$postId'),
        headers: _adminHeaders,
        body: jsonEncode(algoliaData),
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        print('Algolia sync failed: ${response.statusCode} ${response.body}');
      } else {
        print('✅ Algolia sync success: $postId');
      }
    } catch (e) {
      print('Algolia sync error: $e');
    }
  }

  // ═══════════════════════════════════════════════════
  // 删除帖子
  // ═══════════════════════════════════════════════════
  static Future<void> deletePost(String postId) async {
    try {
      final response = await http.delete(
        Uri.parse('$_writeUrl/$postId'),
        headers: _adminHeaders,
      );
      if (response.statusCode != 200) {
        print('Algolia delete failed: ${response.body}');
      }
    } catch (e) {
      print('Algolia delete error: $e');
    }
  }

  // ═══════════════════════════════════════════════════
  // 搜索帖子
  // 1. 先从 Algolia 拿 objectID 列表
  // 2. 用 ID 从 Firestore 取完整 Post 数据
  //
  // hitsPerPage:
  //   - dropdown 即时建议用小数字（如 5）
  //   - 提交搜索（点击/回车）用大一点的数字（如 10）
  //   - ⚠️ 不要超过 10：下面 Firestore whereIn 查询硬性上限就是 10 个 ID，
  //     超过会直接抛异常。如果以后想要支持更多结果，需要把 Firestore
  //     查询改成按 10 个一批分批查询（此处未实现）。
  // ═══════════════════════════════════════════════════
  static Future<List<Post>> searchPosts(
    String query, {
    int hitsPerPage = 5,
  }) async {
    try {
      // ── Step 1: 问 Algolia 拿匹配的 ID ──
      final response = await http.post(
        Uri.parse(_searchUrl),
        headers: _searchHeaders,
        body: jsonEncode({
          'query':         query,
          'hitsPerPage':   hitsPerPage,
          'filters':       'visibility:public',
          'typoTolerance': true,
          // 只需要 objectID，其他从 Firestore 取
          'attributesToRetrieve': ['objectID'],
        }),
      );

      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body);
      final hits = data['hits'] as List? ?? [];
      if (hits.isEmpty) return [];

      final ids = hits.map((h) => h['objectID'] as String).toList();

      // ── Step 2: 用 ID 从 Firestore 批量取完整 Post ──
      // Firestore whereIn 最多 10 个，hitsPerPage 不应超过 10
      final snapshot = await FirebaseFirestore.instance
          .collection('posts')
          .where('visibility', isEqualTo: 'public')
          .where(FieldPath.documentId, whereIn: ids)
          .get();

      // 按 Algolia 搜索排名顺序排列
      final postMap = {
        for (final doc in snapshot.docs)
          doc.id: Post.fromFirestore(doc)
      };

      final posts = ids
          .where((id) => postMap.containsKey(id))
          .map((id) => postMap[id]!)
          .toList();

      return posts;
    } catch (e) {
      print('Algolia search error: $e');
      return [];
    }
  }

  // ═══════════════════════════════════════════════════
  // 配置索引设置
  // 只需要在 main.dart 里跑一次（确认 Algolia Dashboard 生效后即可移除调用）
  // ═══════════════════════════════════════════════════
  static Future<void> configureIndex() async {
    try {
      final settings = {
        // 只有这几个字段参与文字搜索匹配，likes/createdAt/visibility 都不搜
        'searchableAttributes': [
          'title',
          'content',
          'tags',
          'city',
          'location',
          'userName',
        ],
        // 允许用来做 filters 的字段
        'attributesForFaceting': [
          'filterOnly(visibility)',
        ],
      };

      final response = await http.put(
        Uri.parse(_settingsUrl),
        headers: _adminHeaders,
        body: jsonEncode(settings),
      );

      if (response.statusCode != 200) {
        print('Algolia settings failed: ${response.statusCode} ${response.body}');
      } else {
        print('✅ Algolia index settings configured');
      }
    } catch (e) {
      print('Algolia settings error: $e');
    }
  }
}