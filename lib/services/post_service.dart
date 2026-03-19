import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../modules/interaction/postModel.dart';
import '../../services/userPost_service.dart'; // 导入统计服务

/// Firebase 服务类 - 本地存储版本 (不使用 Firebase Storage)
class PostService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final UserStatsService _statsService = UserStatsService(); // 统计服务

  // ===== 创建帖子 =====
  
  /// 保存图片到本地存储
  Future<List<String>> saveImagesToLocal(List<File> images) async {
    List<String> imagePaths = [];
    
    try {
      // 获取应用文档目录
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      
      // 创建 posts 目录（如果不存在）
      if (!await postsDir.exists()) {
        await postsDir.create(recursive: true);
      }
      
      for (int i = 0; i < images.length; i++) {
        // 生成唯一文件名
        String fileName = '${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        String filePath = '${postsDir.path}/$fileName';
        
        // 复制图片到本地存储
        await images[i].copy(filePath);
        imagePaths.add(filePath);
      }
      
      return imagePaths;
    } catch (e) {
      throw Exception('保存图片失败: $e');
    }
  }

  /// 创建新帖子
  Future<String> createPost(Post post) async {
    try {
      // 添加到 Firestore
      DocumentReference docRef = await _firestore
          .collection('posts')
          .add(post.toMap());
      
      return docRef.id;
    } catch (e) {
      throw Exception('创建帖子失败: $e');
    }
  }

  // ===== 读取帖子 =====
  
  /// 获取所有帖子 (按时间倒序)
  Stream<List<Post>> getAllPosts() {
    return _firestore
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    });
  }

  /// 获取单个帖子
  Future<Post?> getPost(String postId) async {
    try {
      DocumentSnapshot doc = await _firestore
          .collection('posts')
          .doc(postId)
          .get();
      
      if (doc.exists) {
        return Post.fromFirestore(doc);
      }
      return null;
    } catch (e) {
      throw Exception('获取帖子失败: $e');
    }
  }

  /// 获取用户的帖子
  Stream<List<Post>> getUserPosts(String userId) {
    // 简化查询,只用 where,在客户端排序
    return _firestore
        .collection('posts')
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map((snapshot) {
      // 在客户端排序 (按创建时间降序)
      List<Post> posts = snapshot.docs
          .map((doc) => Post.fromFirestore(doc))
          .toList();
      
      // 手动排序
      posts.sort((a, b) {
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });
      
      return posts;
    });
  }

  /// 根据标签搜索帖子
  Stream<List<Post>> getPostsByTag(String tag) {
    return _firestore
        .collection('posts')
        .where('tags', arrayContains: tag)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    });
  }

  /// 根据话题搜索帖子
  Stream<List<Post>> getPostsByTopic(String topic) {
    return _firestore
        .collection('posts')
        .where('topic', isEqualTo: topic)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    });
  }

  /// 根据地点搜索帖子
  Stream<List<Post>> getPostsByLocation(String location) {
    return _firestore
        .collection('posts')
        .where('location', isEqualTo: location)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    });
  }

  /// 根据可见范围过滤
  Stream<List<Post>> getPublicPosts() {
    // 简化查询,不需要索引
    return _firestore
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      // 在客户端过滤 (先获取所有,再过滤公开的)
      return snapshot.docs
          .map((doc) => Post.fromFirestore(doc))
          .where((post) => post.visibility == '公开')
          .toList();
    });
  }

  // ===== 更新帖子 =====
  
  /// 更新帖子
  Future<void> updatePost(String postId, Map<String, dynamic> updates) async {
    try {
      await _firestore
          .collection('posts')
          .doc(postId)
          .update(updates);
    } catch (e) {
      throw Exception('更新帖子失败: $e');
    }
  }

  /// 点赞/取消点赞
  Future<void> toggleLike(String postId, bool isLiked) async {
    try {
      await _firestore.collection('posts').doc(postId).update({
        'likes': FieldValue.increment(isLiked ? 1 : -1),
      });
    } catch (e) {
      throw Exception('点赞失败: $e');
    }
  }

  /// 增加评论数
  Future<void> incrementCommentCount(String postId) async {
    try {
      await _firestore.collection('posts').doc(postId).update({
        'comments': FieldValue.increment(1),
      });
    } catch (e) {
      throw Exception('更新评论数失败: $e');
    }
  }

  /// 增加转发数
  Future<void> incrementShareCount(String postId) async {
    try {
      await _firestore.collection('posts').doc(postId).update({
        'shares': FieldValue.increment(1),
      });
    } catch (e) {
      throw Exception('更新转发数失败: $e');
    }
  }

  // ===== 删除帖子 =====
  
  /// 删除帖子及其本地图片
  Future<void> deletePost(String postId) async {
    try {
      // 1. 获取帖子数据
      DocumentSnapshot doc = await _firestore
          .collection('posts')
          .doc(postId)
          .get();
      
      if (doc.exists) {
        Post post = Post.fromFirestore(doc);
        
        // 2. 删除本地图片文件
        for (String imagePath in post.images) {
          try {
            File imageFile = File(imagePath);
            if (await imageFile.exists()) {
              await imageFile.delete();
            }
          } catch (e) {
            print('删除本地图片失败: $e');
          }
        }
        
        // 3. 删除帖子文档
        await _firestore.collection('posts').doc(postId).delete();
        
        // 4. 减少用户的帖子计数 ← 新增
        await _statsService.decrementPostCount();
      }
    } catch (e) {
      throw Exception('删除帖子失败: $e');
    }
  }

  // ===== 本地存储管理 =====
  
  /// 获取本地存储的图片总大小 (字节)
  Future<int> getLocalStorageSize() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      
      if (!await postsDir.exists()) {
        return 0;
      }
      
      int totalSize = 0;
      await for (var entity in postsDir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      
      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// 清理所有本地图片
  Future<void> clearLocalImages() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      
      if (await postsDir.exists()) {
        await postsDir.delete(recursive: true);
      }
    } catch (e) {
      throw Exception('清理本地图片失败: $e');
    }
  }

  /// 清理孤立的图片 (没有对应帖子的图片)
  Future<void> cleanOrphanedImages() async {
    try {
      // 1. 获取所有帖子的图片路径
      QuerySnapshot postsSnapshot = await _firestore.collection('posts').get();
      Set<String> usedImages = {};
      
      for (var doc in postsSnapshot.docs) {
        Post post = Post.fromFirestore(doc);
        usedImages.addAll(post.images);
      }
      
      // 2. 获取本地所有图片
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      
      if (!await postsDir.exists()) {
        return;
      }
      
      // 3. 删除未被使用的图片
      await for (var entity in postsDir.list()) {
        if (entity is File) {
          if (!usedImages.contains(entity.path)) {
            await entity.delete();
            print('删除孤立图片: ${entity.path}');
          }
        }
      }
    } catch (e) {
      throw Exception('清理孤立图片失败: $e');
    }
  }

  // ===== 高级查询 =====
  
  /// 获取热门帖子 (按点赞数排序)
  Stream<List<Post>> getPopularPosts({int limit = 20}) {
    return _firestore
        .collection('posts')
        .orderBy('likes', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    });
  }

  /// 搜索帖子 (标题包含关键词)
  Future<List<Post>> searchPosts(String keyword) async {
    try {
      // Firestore 简单前缀匹配
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('title', isGreaterThanOrEqualTo: keyword)
          .where('title', isLessThanOrEqualTo: keyword + '\uf8ff')
          .get();
      
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    } catch (e) {
      throw Exception('搜索失败: $e');
    }
  }

  /// 分页获取帖子
  Future<List<Post>> getPostsPaginated({
    DocumentSnapshot? lastDocument,
    int limit = 10,
  }) async {
    try {
      Query query = _firestore
          .collection('posts')
          .orderBy('createdAt', descending: true)
          .limit(limit);
      
      if (lastDocument != null) {
        query = query.startAfterDocument(lastDocument);
      }
      
      QuerySnapshot snapshot = await query.get();
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    } catch (e) {
      throw Exception('获取帖子失败: $e');
    }
  }

  // ===== 统计功能 =====
  
  /// 获取用户帖子总数
  Future<int> getUserPostCount(String userId) async {
    try {
      AggregateQuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('userId', isEqualTo: userId)
          .count()
          .get();
      
      return snapshot.count ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// 获取某个标签的帖子数量
  Future<int> getTagPostCount(String tag) async {
    try {
      AggregateQuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('tags', arrayContains: tag)
          .count()
          .get();
      
      return snapshot.count ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// 获取用户的总点赞数
  Future<int> getUserTotalLikes(String userId) async {
    try {
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('userId', isEqualTo: userId)
          .get();
      
      int totalLikes = 0;
      for (var doc in snapshot.docs) {
        Post post = Post.fromFirestore(doc);
        totalLikes += post.likes;
      }
      
      return totalLikes;
    } catch (e) {
      return 0;
    }
  }

  // ===== 本地图片验证 =====
  
  /// 检查图片文件是否存在
  Future<bool> imageExists(String imagePath) async {
    try {
      File file = File(imagePath);
      return await file.exists();
    } catch (e) {
      return false;
    }
  }

  /// 验证帖子的所有图片是否存在
  Future<bool> validatePostImages(String postId) async {
    try {
      Post? post = await getPost(postId);
      if (post == null) return false;
      
      for (String imagePath in post.images) {
        if (!await imageExists(imagePath)) {
          return false;
        }
      }
      
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 修复损坏的帖子 (删除图片丢失的帖子)
  Future<int> fixBrokenPosts() async {
    try {
      QuerySnapshot snapshot = await _firestore.collection('posts').get();
      int fixedCount = 0;
      
      for (var doc in snapshot.docs) {
        Post post = Post.fromFirestore(doc);
        bool allImagesExist = true;
        
        for (String imagePath in post.images) {
          if (!await imageExists(imagePath)) {
            allImagesExist = false;
            break;
          }
        }
        
        if (!allImagesExist) {
          await doc.reference.delete();
          fixedCount++;
        }
      }
      
      return fixedCount;
    } catch (e) {
      throw Exception('修复失败: $e');
    }
  }

  // ===== 批量操作 =====
  
  /// 批量删除用户的帖子
  Future<void> deleteUserPosts(String userId) async {
    try {
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('userId', isEqualTo: userId)
          .get();
      
      WriteBatch batch = _firestore.batch();
      
      for (var doc in snapshot.docs) { 
        Post post = Post.fromFirestore(doc);
        
        // 删除本地图片
        for (String imagePath in post.images) {
          try {
            File imageFile = File(imagePath);
            if (await imageFile.exists()) {
              await imageFile.delete();
            }
          } catch (e) {
            print('删除图片失败: $e');
          }
        }
        
        // 添加到批量删除
        batch.delete(doc.reference);
      }
      
      await batch.commit();
    } catch (e) {
      throw Exception('批量删除失败: $e');
    }
  }

  /// 导出用户数据 (包括本地图片路径)
  Future<Map<String, dynamic>> exportUserData(String userId) async {
    try {
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('userId', isEqualTo: userId)
          .get();
      
      List<Map<String, dynamic>> posts = [];
      for (var doc in snapshot.docs) {
        Post post = Post.fromFirestore(doc);
        posts.add(post.toMap());
      }
      
      return {
        'userId': userId,
        'totalPosts': posts.length,
        'posts': posts,
        'exportDate': DateTime.now().toIso8601String(),
      };
    } catch (e) {
      throw Exception('导出失败: $e');
    }
  }
}