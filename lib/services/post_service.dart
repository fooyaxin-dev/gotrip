import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../models/postModel.dart';

class PostService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance; // ✅ 新增

  // ===== 用户统计 (从 UserStatsService 迁移) =====

  Future<void> incrementPostCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;
    try {
      await _firestore.collection('users').doc(userId).update({
        'postCount': FieldValue.increment(1),
      });
    } catch (e) {
      print('Update post count failed: $e');
    }
  }

  Future<void> decrementPostCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      final current = (doc.data() as Map<String, dynamic>?)?['postCount'] ?? 0;
      if (current <= 0) return;
      await _firestore.collection('users').doc(userId).update({
        'postCount': FieldValue.increment(-1),
      });
    } catch (e) {
      print('Update post count failed: $e');
    }
  }

  Future<void> incrementFavouriteCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;
    try {
      await _firestore.collection('users').doc(userId).update({
        'favouriteCount': FieldValue.increment(1),
      });
    } catch (e) {
      print('Update favourite count failed: $e');
    }
  }

  Future<void> decrementFavouriteCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;
    try {
      await _firestore.collection('users').doc(userId).update({
        'favouriteCount': FieldValue.increment(-1),
      });
    } catch (e) {
      print('Update favourite count failed: $e');
    }
  }

  Future<void> incrementRouteCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;
    try {
      await _firestore.collection('users').doc(userId).update({
        'routeCount': FieldValue.increment(1),
      });
    } catch (e) {
      print('Update route count failed: $e');
    }
  }

  Future<void> decrementRouteCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;
    try {
      await _firestore.collection('users').doc(userId).update({
        'routeCount': FieldValue.increment(-1),
      });
    } catch (e) {
      print('Update route count failed: $e');
    }
  }

  // ===== 创建帖子 =====

  Future<List<String>> saveImagesToLocal(List<File> images) async {
    List<String> imagePaths = [];
    try {
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      if (!await postsDir.exists()) {
        await postsDir.create(recursive: true);
      }
      for (int i = 0; i < images.length; i++) {
        String fileName = '${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        String filePath = '${postsDir.path}/$fileName';
        await images[i].copy(filePath);
        imagePaths.add(filePath);
      }
      return imagePaths;
    } catch (e) {
      throw Exception('Failed to save images: $e');
    }
  }

  Future<String> createPost(Post post) async {
    try {
      DocumentReference docRef =
          await _firestore.collection('posts').add(post.toMap());
      return docRef.id;
    } catch (e) {
      throw Exception('Failed to create post: $e');
    }
  }

  // ===== 读取帖子 =====

  Stream<List<Post>> getAllPosts() {
    return _firestore
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  Future<Post?> getPost(String postId) async {
    try {
      DocumentSnapshot doc =
          await _firestore.collection('posts').doc(postId).get();
      if (doc.exists) return Post.fromFirestore(doc);
      return null;
    } catch (e) {
      throw Exception('Failed to fetch post: $e');
    }
  }

  Stream<List<Post>> getUserPosts(String userId) {
    return _firestore
        .collection('posts')
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map((snapshot) {
      List<Post> posts =
          snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
      posts.sort((a, b) {
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });
      return posts;
    });
  }

  Stream<List<Post>> getPostsByTag(String tag) {
    return _firestore
        .collection('posts')
        .where('tags', arrayContains: tag)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  Stream<List<Post>> getPostsByTopic(String topic) {
    return _firestore
        .collection('posts')
        .where('topic', isEqualTo: topic)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  Stream<List<Post>> getPostsByLocation(String location) {
    return _firestore
        .collection('posts')
        .where('location', isEqualTo: location)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  Stream<List<Post>> getPublicPosts() {
    return _firestore
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Post.fromFirestore(doc))
            .where((post) => post.visibility == 'public')
            .toList());
  }

  Stream<List<Post>> getPostsByCity(String city) {
    return _firestore
        .collection('posts')
        .where('city', isEqualTo: city)
        .where('visibility', isEqualTo: 'public')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  Stream<List<Post>> getPostsByWishlistCities(List<String> cities) {
    final limitedCities = cities.take(10).toList();
    if (limitedCities.isEmpty) return Stream.value([]);
    return _firestore
        .collection('posts')
        .where('city', whereIn: limitedCities)
        .where('visibility', isEqualTo: 'public')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  // ===== 更新帖子 =====

  Future<void> updatePost(String postId, Map<String, dynamic> updates) async {
    try {
      await _firestore.collection('posts').doc(postId).update(updates);
    } catch (e) {
      throw Exception('Failed to update post: $e');
    }
  }

  Future<void> toggleLike(String postId, bool isLiked) async {
    try {
      await _firestore.collection('posts').doc(postId).update({
        'likes': FieldValue.increment(isLiked ? 1 : -1),
      });
    } catch (e) {
      throw Exception('Failed to toggle like: $e');
    }
  }

  Future<void> incrementCommentCount(String postId) async {
    try {
      await _firestore.collection('posts').doc(postId).update({
        'comments': FieldValue.increment(1),
      });
    } catch (e) {
      throw Exception('Failed to increment comment count: $e');
    }
  }

  Future<void> incrementShareCount(String postId) async {
    try {
      await _firestore.collection('posts').doc(postId).update({
        'shares': FieldValue.increment(1),
      });
    } catch (e) {
      throw Exception('Failed to increment share count: $e');
    }
  }

  // ===== 删除帖子 =====

  Future<void> deletePost(String postId) async {
    try {
      DocumentSnapshot doc =
          await _firestore.collection('posts').doc(postId).get();
      if (doc.exists) {
        Post post = Post.fromFirestore(doc);
        for (String imagePath in post.images) {
          try {
            File imageFile = File(imagePath);
            if (await imageFile.exists()) await imageFile.delete();
          } catch (e) {
            print('Failed to delete local image: $e');
          }
        }
        await _firestore.collection('posts').doc(postId).delete();
        await decrementPostCount(); // ✅ 直接调用本类方法
      }
    } catch (e) {
      throw Exception('Failed to delete post: $e');
    }
  }

  // ===== 本地存储管理 =====

  Future<int> getLocalStorageSize() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      if (!await postsDir.exists()) return 0;
      int totalSize = 0;
      await for (var entity in postsDir.list(recursive: true)) {
        if (entity is File) totalSize += await entity.length();
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  Future<void> clearLocalImages() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      if (await postsDir.exists()) await postsDir.delete(recursive: true);
    } catch (e) {
      throw Exception('Failed to clear local images: $e');
    }
  }

  Future<void> cleanOrphanedImages() async {
    try {
      QuerySnapshot postsSnapshot = await _firestore.collection('posts').get();
      Set<String> usedImages = {};
      for (var doc in postsSnapshot.docs) {
        Post post = Post.fromFirestore(doc);
        usedImages.addAll(post.images);
      }
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      if (!await postsDir.exists()) return;
      await for (var entity in postsDir.list()) {
        if (entity is File && !usedImages.contains(entity.path)) {
          await entity.delete();
          print('Failed to delete local image: ${entity.path}');
        }
      }
    } catch (e) {
      throw Exception('Failed to clean orphaned images: $e');
    }
  }

  // ===== 高级查询 =====

  Stream<List<Post>> getPopularPosts({int limit = 20}) {
    return _firestore
        .collection('posts')
        .orderBy('likes', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  Future<List<Post>> searchPosts(String keyword) async {
    try {
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('title', isGreaterThanOrEqualTo: keyword)
          .where('title', isLessThanOrEqualTo: keyword + '\uf8ff')
          .get();
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    } catch (e) {
      throw Exception('Failed to search posts: $e');
    }
  }

  Future<List<Post>> getPostsPaginated({
    DocumentSnapshot? lastDocument,
    int limit = 10,
  }) async {
    try {
      Query query = _firestore
          .collection('posts')
          .orderBy('createdAt', descending: true)
          .limit(limit);
      if (lastDocument != null) query = query.startAfterDocument(lastDocument);
      QuerySnapshot snapshot = await query.get();
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    } catch (e) {
      throw Exception('Failed to fetch posts: $e');
    }
  }

  // ===== 统计功能 =====

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

  Future<bool> imageExists(String imagePath) async {
    try {
      return await File(imagePath).exists();
    } catch (e) {
      return false;
    }
  }

  Future<bool> validatePostImages(String postId) async {
    try {
      Post? post = await getPost(postId);
      if (post == null) return false;
      for (String imagePath in post.images) {
        if (!await imageExists(imagePath)) return false;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

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
      throw Exception('Failed to fix broken posts: $e');
    }
  }

  // ===== 批量操作 =====

  Future<void> deleteUserPosts(String userId) async {
    try {
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('userId', isEqualTo: userId)
          .get();
      WriteBatch batch = _firestore.batch();
      for (var doc in snapshot.docs) {
        Post post = Post.fromFirestore(doc);
        for (String imagePath in post.images) {
          try {
            File imageFile = File(imagePath);
            if (await imageFile.exists()) await imageFile.delete();
          } catch (e) {
            print('Failed to delete local image: $e');
          }
        }
        batch.delete(doc.reference);
      }
      await batch.commit();
    } catch (e) {
      throw Exception('Failed to delete user posts: $e');
    }
  }

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
      throw Exception('Failed to export user data: $e');
    }
  }
}