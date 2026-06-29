// ===== algolia_service.dart =====

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/postModel.dart';

class AlgoliaService {
  static const String _appId = 'B26MRUV66D';
  static const String _adminApiKey = '688761995472f3279ac2a79043d50e0d';
  static const String _searchApiKey = '44f0f52f448de5193815cfab83fa0842';
  static const String _indexName = 'posts';

  static String get _writeUrl =>
      'https://$_appId.algolia.net/1/indexes/$_indexName';
  static String get _searchUrl =>
      'https://$_appId-dsn.algolia.net/1/indexes/$_indexName/query';

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
  // ═══════════════════════════════════════════════════
  static Future<List<Post>> searchPosts(String query) async {
    try {
      // ── Step 1: 问 Algolia 拿匹配的 ID ──
      final response = await http.post(
        Uri.parse(_searchUrl),
        headers: _searchHeaders,
        body: jsonEncode({
          'query':         query,
          'hitsPerPage':   5,
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
      // Firestore whereIn 最多 10 个
      final snapshot = await FirebaseFirestore.instance
          .collection('posts')
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
}