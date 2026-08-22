import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';


class LikeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;


  Future<bool> toggleLike(String postId) async {
  try {
    final userId = _auth.currentUser?.uid;

    if (userId == null) {
      throw Exception('User not logged in');
    }

    final postDoc =
        _firestore.collection('posts').doc(postId);

    final likeDoc =
        postDoc.collection('likes').doc(userId);

    return await _firestore.runTransaction<bool>((transaction) async {
      final likeSnapshot = await transaction.get(likeDoc);

      if (likeSnapshot.exists) {
        // Already liked → unlike
        transaction.delete(likeDoc);

        transaction.update(postDoc, {
          'likes': FieldValue.increment(-1),
        });

        return false;
      } else {
        // Not liked → like
        transaction.set(likeDoc, {
          'userId': userId,
          'createdAt': FieldValue.serverTimestamp(),
        });

        transaction.update(postDoc, {
          'likes': FieldValue.increment(1),
        });

        return true;
      }
    });
  } catch (e) {
    throw Exception('Failed to toggle like: $e');
  }
}

  
  Future<void> _likePost(String postId, String userId) async {
    WriteBatch batch = _firestore.batch();

    DocumentReference likeDoc = _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(userId);
    
    batch.set(likeDoc, {
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
    });

  
    DocumentReference postDoc = _firestore.collection('posts').doc(postId);
    batch.update(postDoc, {
      'likes': FieldValue.increment(1),
    });

    await batch.commit();
  }

  Future<void> _unlikePost(String postId, String userId) async {
    WriteBatch batch = _firestore.batch();

    
    DocumentReference likeDoc = _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(userId);
    
    batch.delete(likeDoc);

    DocumentReference postDoc = _firestore.collection('posts').doc(postId);
    batch.update(postDoc, {
      'likes': FieldValue.increment(-1),
    });

    await batch.commit();
  }


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

 
  Future<bool> isLikedByCurrentUser(String postId) async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return false;
    
    return await hasLiked(postId, userId);
  }


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