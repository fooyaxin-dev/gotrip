import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// 用户统计服务
class UserStatsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ===== 更新统计 =====
  
  /// 增加帖子数量
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

  /// 减少帖子数量
  Future<void> decrementPostCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      final current = (doc.data() as Map<String, dynamic>?)?['postCount'] ?? 0;
      
      if (current <= 0) return; // ✅ 已经是 0，不再递减
      
      await _firestore.collection('users').doc(userId).update({
        'postCount': FieldValue.increment(-1),
      });
    } catch (e) {
      print('Update post count failed: $e');
    }
  }

  /// 增加收藏数量
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

  /// 减少收藏数量
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

  /// 增加路线数量
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

  /// 减少路线数量
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

  // ===== 获取统计 =====
  
  /// 获取当前用户的统计信息
  Future<Map<String, int>> getUserStats() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) {
      return {'postCount': 0, 'favouriteCount': 0, 'routeCount': 0};
    }

    try {
      DocumentSnapshot doc = await _firestore
          .collection('users')
          .doc(userId)
          .get();

      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return {
          'postCount': data['postCount'] ?? 0,
          'favouriteCount': data['favouriteCount'] ?? 0,
          'routeCount': data['routeCount'] ?? 0,
        };
      }
    } catch (e) {
      print('Get user stats failed: $e');
    }

    return {'postCount': 0, 'favouriteCount': 0, 'routeCount': 0};
  }

  /// 实时监听用户统计
  Stream<Map<String, int>> getUserStatsStream() {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) {
      return Stream.value({'postCount': 0, 'favouriteCount': 0, 'routeCount': 0});
    }

    return _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .map((doc) {
      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return {
          'postCount': data['postCount'] ?? 0,
          'favouriteCount': data['favouriteCount'] ?? 0,
          'routeCount': data['routeCount'] ?? 0,
        };
      }
      return {'postCount': 0, 'favouriteCount': 0, 'routeCount': 0};
    });
  }

  // ===== 重新计算统计 (修复不一致) =====
  
  /// 重新计算帖子数量
  Future<void> recalculatePostCount() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      // 统计实际帖子数
      QuerySnapshot snapshot = await _firestore
          .collection('posts')
          .where('userId', isEqualTo: userId)
          .get();

      int actualCount = snapshot.docs.length;

      // 更新到用户文档
      await _firestore.collection('users').doc(userId).update({
        'postCount': actualCount,
      });

      print('✅ Recount post: $actualCount');
    } catch (e) {
      print('Update post count failed: $e');
    }
  }

  /// 初始化用户统计 (如果不存在)
  Future<void> initializeUserStats() async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      DocumentSnapshot doc = await _firestore
          .collection('users')
          .doc(userId)
          .get();

      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        
        // 如果字段不存在,初始化为0
        Map<String, dynamic> updates = {};
        
        if (!data.containsKey('postCount')) {
          updates['postCount'] = 0;
        }
        if (!data.containsKey('favouriteCount')) {
          updates['favouriteCount'] = 0;
        }
        if (!data.containsKey('routeCount')) {
          updates['routeCount'] = 0;
        }

        if (updates.isNotEmpty) {
          await _firestore.collection('users').doc(userId).update(updates);
        }
      }
    } catch (e) {
      print('Initialize user stats failed: $e');
    }
  }
}