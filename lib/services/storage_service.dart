// services/storage_service.dart
//
// 负责把发帖时选中的图片/视频上传到 Firebase Storage，
// 返回可公开访问的下载 URL，存进 Firestore 的 post 文档里。
//
// 之前的问题：addPost.dart 只把媒体存到手机本地
// (path_provider)，然后把「本地路径」写进 Firestore。
// 别人刷到你的帖子时，Image.file(那个本地路径) 在他们手机上
// 根本不存在 —— 图片对所有人（除了发帖者自己）都是坏的。
//
// 现在改成：先传到 Storage，拿到 https:// 开头的下载链接，
// 再把链接存进 Firestore —— 所有人都能通过网络加载到同一张图。

import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path/path.dart' as p;

class StorageService {
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

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
}