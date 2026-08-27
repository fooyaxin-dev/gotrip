import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';


class LikeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;


  Future<bool> toggleLike(String postId) async {
  final userId = _auth.currentUser?.uid;

  if (userId == null) {
    throw Exception('User not logged in');
  }

  final postDoc =
      _firestore.collection('posts').doc(postId);

  final likeDoc = postDoc
      .collection('likes')
      .doc(userId);

  try {
    return await _firestore.runTransaction<bool>(
      (transaction) async {
        // Firestore requires transaction reads before writes.
        final likeSnapshot =
            await transaction.get(likeDoc);

        final postSnapshot =
            await transaction.get(postDoc);

        if (!postSnapshot.exists) {
          throw Exception(
            'This post no longer exists',
          );
        }

        // The operation belongs to the user who
        // originally started this toggle.
        if (_auth.currentUser?.uid != userId) {
          throw Exception(
            'Account changed during like operation',
          );
        }

        final postData =
            postSnapshot.data()
                as Map<String, dynamic>?;

        final currentLikes =
            (postData?['likes'] as num?)
                    ?.toInt() ??
                0;

        if (likeSnapshot.exists) {
          // ── Unlike ───────────────────────────

          transaction.delete(
            likeDoc,
          );

          // Never allow the counter to become negative.
          transaction.update(
            postDoc,
            {
              'likes':
                  currentLikes > 0
                      ? currentLikes - 1
                      : 0,
            },
          );

          return false;
        }

        // ── Like ───────────────────────────────

        transaction.set(
          likeDoc,
          {
            'userId': userId,
            'createdAt':
                FieldValue.serverTimestamp(),
          },
        );

        transaction.update(
          postDoc,
          {
            'likes': currentLikes + 1,
          },
        );

        return true;
      },
    );
  } catch (e) {
    throw Exception(
      'Failed to toggle like: $e',
    );
  }
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