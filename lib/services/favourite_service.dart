import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FavouriteService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // 获取当前用户 ID
  static String? get _userId => _auth.currentUser?.uid;

  // 收藏集合路径: users/{userId}/favourites/{placeId}
  static CollectionReference? get _favouritesCollection {
    final uid = _userId;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('favourites');
  }

  /// ❤️ 添加收藏
  static Future<void> addFavourite({
    required String placeId,
    required String name,
    required String address,
    double? rating,
    String? photoUrl,
    double? lat,
    double? lng,
  }) async {
    final collection = _favouritesCollection;
    if (collection == null) throw Exception('User not logged in');

    await collection.doc(placeId).set({
      'placeId': placeId,
      'name': name,
      'address': address,
      'rating': rating,
      'photoUrl': photoUrl,
      'lat': lat,
      'lng': lng,
      'savedAt': FieldValue.serverTimestamp(),
    });
  }

  /// 💔 移除收藏
  static Future<void> removeFavourite(String placeId) async {
    final collection = _favouritesCollection;
    if (collection == null) throw Exception('User not logged in');

    await collection.doc(placeId).delete();
  }

  /// 🔍 检查某个 place 是否已收藏（单次查询）
  static Future<bool> isFavourite(String placeId) async {
    final collection = _favouritesCollection;
    if (collection == null) return false;

    final doc = await collection.doc(placeId).get();
    return doc.exists;
  }

  /// 🔄 切换收藏状态，返回新状态 (true = 已收藏)
  static Future<bool> toggleFavourite({
    required String placeId,
    required String name,
    required String address,
    double? rating,
    String? photoUrl,
    double? lat,
    double? lng,
  }) async {
    final isCurrentlyFavourite = await isFavourite(placeId);

    if (isCurrentlyFavourite) {
      await removeFavourite(placeId);
      return false;
    } else {
      await addFavourite(
        placeId: placeId,
        name: name,
        address: address,
        rating: rating,
        photoUrl: photoUrl,
        lat: lat,
        lng: lng,
      );
      return true;
    }
  }

  /// 📋 实时监听收藏列表（Stream，用于 FavouritePage）
  static Stream<List<Map<String, dynamic>>> getFavouritesStream() {
    final collection = _favouritesCollection;
    if (collection == null) return Stream.value([]);

    return collection
        .orderBy('savedAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => doc.data() as Map<String, dynamic>)
          .toList();
    });
  }

  /// 📋 实时监听某个 place 的收藏状态（Stream，用于 Heart Button）
  static Stream<bool> getFavouriteStatusStream(String placeId) {
    final collection = _favouritesCollection;
    if (collection == null) return Stream.value(false);

    return collection.doc(placeId).snapshots().map((doc) => doc.exists);
  }
}