import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// 点赞服务
class LikeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ===== 点赞/取消点赞 =====
  
  /// 切换点赞状态
  Future<bool> toggleLike(String postId) async {
    try {
      String? userId = _auth.currentUser?.uid;
      if (userId == null) {
        throw Exception('User not logged in');
      }

      // 检查是否已点赞
      bool isLiked = await hasLiked(postId, userId);

      if (isLiked) {
        // 取消点赞
        await _unlikePost(postId, userId);
        return false;
      } else {
        // 点赞
        await _likePost(postId, userId);
        return true;
      }
    } catch (e) {
      throw Exception('Failed to toggle like: $e');
    }
  }

  /// 点赞帖子
  Future<void> _likePost(String postId, String userId) async {
    WriteBatch batch = _firestore.batch();

    // 1. 添加到点赞记录
    DocumentReference likeDoc = _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(userId);
    
    batch.set(likeDoc, {
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
    });

    // 2. 增加帖子的点赞数
    DocumentReference postDoc = _firestore.collection('posts').doc(postId);
    batch.update(postDoc, {
      'likes': FieldValue.increment(1),
    });

    await batch.commit();
  }

  /// 取消点赞
  Future<void> _unlikePost(String postId, String userId) async {
    WriteBatch batch = _firestore.batch();

    // 1. 删除点赞记录
    DocumentReference likeDoc = _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(userId);
    
    batch.delete(likeDoc);

    // 2. 减少帖子的点赞数
    DocumentReference postDoc = _firestore.collection('posts').doc(postId);
    batch.update(postDoc, {
      'likes': FieldValue.increment(-1),
    });

    await batch.commit();
  }

  // ===== 查询点赞状态 =====
  
  /// 检查当前用户是否点赞了某个帖子
  Future<bool> hasLiked(String postId, String userId) async {
    try {
      DocumentSnapshot doc = await _firestore
          .collection('posts')
          .doc(postId)
          .collection('likes')
          .doc(userId)
          .get();

      return doc.exists;
    } catch (e) {
      return false;
    }
  }

  /// 检查当前用户是否点赞了某个帖子 (使用当前登录用户)
  Future<bool> isLikedByCurrentUser(String postId) async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return false;
    
    return await hasLiked(postId, userId);
  }

  /// 获取帖子的点赞用户列表
  Future<List<String>> getLikedUsers(String postId) async {
    try {
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .doc(postId)
          .collection('likes')
          .get();

      return snapshot.docs.map((doc) => doc.id).toList();
    } catch (e) {
      return [];
    }
  }

  /// 实时监听点赞状态
  Stream<bool> likeStatusStream(String postId) {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) {
      return Stream.value(false);
    }

    return _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(userId)
        .snapshots()
        .map((doc) => doc.exists);
  }

  /// 实时监听点赞数
  Stream<int> likeCountStream(String postId) {
    return _firestore
        .collection('posts')
        .doc(postId)
        .snapshots()
        .map((doc) {
      if (doc.exists) {
        return (doc.data() as Map<String, dynamic>)['likes'] ?? 0;
      }
      return 0;
    });
  }

  // ===== 批量查询 =====
  
  /// 批量检查用户是否点赞了多个帖子
  Future<Map<String, bool>> checkMultipleLikes(List<String> postIds) async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) {
      return {};
    }

    Map<String, bool> likeStatus = {};

    for (String postId in postIds) {
      bool liked = await hasLiked(postId, userId);
      likeStatus[postId] = liked;
    }

    return likeStatus;
  }
}