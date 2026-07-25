// services/storage_service.dart
//
// 负责两件事：
//   1. 发帖时把图片/视频上传到 Firebase Storage，返回下载 URL
//      （解决：别人刷到你的帖子时图片是空的，因为原来存的是本地路径）
//   2. 行程生成/保存时，把 Google Places 返回的、会过期的临时图片链接
//      下载下来重新上传到 Storage，换成永久链接
//      （解决：行程里的地点照片过几天就变成占位符）
//
// 第 2 点用 placeId 做缓存 key —— 同一个地点在不同用户/不同行程里
// 出现，只会真正下载/上传一次，之后全部复用同一张图。

import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class StorageService {
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  static const String _photoCacheCollection = 'place_photo_cache';

  // ═══════════════════════════════════════════════════════════════════
  // 1. 帖子图片/视频上传（发帖用）
  // ═══════════════════════════════════════════════════════════════════

  /// 上传单个文件到 posts/{uid}/{timestamp}_{原文件名}.{ext}
  /// 成功返回下载 URL，失败返回 null（不会抛异常中断发帖流程）。
  static Future<String?> uploadPostMedia(
    File file, {
    required bool isVideo,
  }) async {
    final uid = _uid;
    if (uid == null) {
      print('❌ StorageService: user not logged in');
      return null;
    }

    try {
      final ext = isVideo ? 'mp4' : 'jpg';
      final baseName = p.basenameWithoutExtension(file.path);
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_$baseName.$ext';
      final ref = _storage.ref().child('posts/$uid/$fileName');

      final uploadTask = await ref.putFile(
        file,
        SettableMetadata(
          contentType: isVideo ? 'video/mp4' : 'image/jpeg',
        ),
      );

      final url = await uploadTask.ref.getDownloadURL();
      print('✅ Uploaded ${isVideo ? "video" : "image"}: $fileName');
      return url;
    } catch (e) {
      print('❌ StorageService.uploadPostMedia failed for ${file.path}: $e');
      return null;
    }
  }

  /// 批量并行上传。任何一个文件上传失败只会跳过它自己，
  /// 不会导致整批全部失败 —— 用户不应该因为一张图片网络抖动
  /// 就发不出帖子。
  ///
  /// 返回 (imageUrls, videoUrls)，按类型分开、成功的那些。
  static Future<({List<String> imageUrls, List<String> videoUrls})>
      uploadPostMediaBatch(
    List<({File file, bool isVideo})> items,
  ) async {
    if (items.isEmpty) {
      return (imageUrls: <String>[], videoUrls: <String>[]);
    }

    final results = await Future.wait(
      items.map((item) => uploadPostMedia(item.file, isVideo: item.isVideo)),
    );

    final imageUrls = <String>[];
    final videoUrls = <String>[];

    for (int i = 0; i < items.length; i++) {
      final url = results[i];
      if (url == null) continue; // 上传失败的直接跳过
      if (items[i].isVideo) {
        videoUrls.add(url);
      } else {
        imageUrls.add(url);
      }
    }

    return (imageUrls: imageUrls, videoUrls: videoUrls);
  }

  /// 删帖时一并清理 Storage 里的文件，避免产生孤儿文件占用空间。
  /// 对旧帖子（本地路径，不是 URL）会自动跳过，不会报错。
  static Future<void> deletePostMedia(List<String> urls) async {
    for (final url in urls) {
      if (!url.startsWith('http')) continue; // 旧的本地路径，不用处理
      try {
        await _storage.refFromURL(url).delete();
      } catch (e) {
        print('⚠️ Failed to delete storage file ($url): $e');
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // 2. 行程地点照片「永久化」（行程生成/保存用）
  // ═══════════════════════════════════════════════════════════════════

  /// 把 [sourceUrl]（Google Places 返回的、可能几天后就过期的图片链接）
  /// 下载下来重新上传到 Firebase Storage，返回一个不会过期的永久链接。
  ///
  /// 用 [placeId] 做缓存 key —— 同一个地点只会真正下载/上传一次，
  /// 后续调用直接命中缓存，零网络开销。
  ///
  /// 任何环节失败（没网、下载超时、上传失败）都会 fallback 返回
  /// [sourceUrl] 本身 —— 保证调用方永远拿到一个可用的 URL（哪怕只是
  /// 「暂时可用」），不会因为这一步失败就让整个行程生成/保存中断。
  static Future<String> resolvePermanentPlacePhoto({
    required String placeId,
    required String sourceUrl,
  }) async {
    if (placeId.isEmpty || sourceUrl.isEmpty) return sourceUrl;

    // ── 先查缓存：这个地点是不是已经有人转存过了 ──
    try {
      final cached =
          await _db.collection(_photoCacheCollection).doc(placeId).get();
      if (cached.exists) {
        final url = cached.data()?['storageUrl'] as String?;
        if (url != null && url.isNotEmpty) {
          print('🧠 resolvePermanentPlacePhoto: cache hit for $placeId');
          return url;
        }
      }
    } catch (e) {
      print('⚠️ resolvePermanentPlacePhoto: cache check failed: $e');
      // 查缓存失败不致命，继续往下走，当作没缓存处理
    }

    // ── 没缓存：下载 Google 图片 → 上传到 Storage → 写缓存 ──
    try {
      final response = await http
          .get(Uri.parse(sourceUrl))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        print('⚠️ resolvePermanentPlacePhoto: download failed '
            '(${response.statusCode}) for $placeId');
        return sourceUrl; // 至少眼下这个 URL 还能用，先用着
      }

      final ref = _storage.ref().child('place_photos/$placeId.jpg');
      await ref.putData(
        response.bodyBytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final permanentUrl = await ref.getDownloadURL();

      // 写缓存 —— 之后任何行程/任何用户引用同一个 placeId 都直接复用
      await _db.collection(_photoCacheCollection).doc(placeId).set({
        'storageUrl': permanentUrl,
        'cachedAt': FieldValue.serverTimestamp(),
      });

      print('✅ resolvePermanentPlacePhoto: cached permanent photo for $placeId');
      return permanentUrl;
    } catch (e) {
      print('⚠️ resolvePermanentPlacePhoto failed for $placeId: $e '
          '— falling back to source URL');
      return sourceUrl;
    }
  }
}