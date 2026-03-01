import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class FavouriteService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';
  static const String _baseUrl = 'https://places.googleapis.com/v1';

  static String? get _userId => _auth.currentUser?.uid;

  static CollectionReference? get _favouritesCollection {
    final uid = _userId;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('favourites');
  }

  /// 🔍 直接从 Google API fetch types（只请求 types 字段，最便宜）
  static Future<List<String>> _fetchTypesFromApi(String placeId) async {
    try {
      // Step 1: 先看 place_details 缓存有没有
      final cached = await _firestore
          .collection('place_details')
          .doc(placeId)
          .get();

      if (cached.exists) {
        final types = (cached.data()!['types'] as List?)
            ?.map((e) => e.toString())
            .toList() ?? [];
        if (types.isNotEmpty) {
          print('✅ Got types from place_details cache: $types');
          return types;
        }
      }

      // Step 2: 缓存也没有，直接 call Google API（只要 types 字段）
      print('🌐 Fetching types from Google API for $placeId...');
      final url = Uri.parse('$_baseUrl/places/$placeId');
      final response = await http.get(url, headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': _apiKey,
        'X-Goog-FieldMask': 'types', // 只要 types，最省钱
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final types = (data['types'] as List?)
            ?.map((e) => e.toString())
            .toList() ?? [];
        print('✅ Got types from API: $types');

        // 顺便更新 place_details 缓存里的 types
        if (types.isNotEmpty && cached.exists) {
          await _firestore
              .collection('place_details')
              .doc(placeId)
              .update({'types': types});
        }

        return types;
      }
    } catch (e) {
      print('⚠️ Failed to fetch types: $e');
    }
    return [];
  }

  /// ❤️ 添加收藏
  /// 如果 types 是空的，自动去 fetch
  static Future<void> addFavourite({
    required String placeId,
    required String name,
    required String address,
    double? rating,
    String? photoUrl,
    double? lat,
    double? lng,
    List<String>? types,
  }) async {
    final collection = _favouritesCollection;
    if (collection == null) throw Exception('User not logged in');

    // ✅ 如果 types 是空的，自动补
    List<String> finalTypes = (types != null && types.isNotEmpty)
        ? types
        : await _fetchTypesFromApi(placeId);

    print('💾 Saving favourite with types: $finalTypes');

    await collection.doc(placeId).set({
      'placeId': placeId,
      'name': name,
      'address': address,
      'rating': rating,
      'photoUrl': photoUrl,
      'lat': lat,
      'lng': lng,
      'types': finalTypes,
      'savedAt': FieldValue.serverTimestamp(),
    });
  }

  /// 💔 移除收藏
  static Future<void> removeFavourite(String placeId) async {
    final collection = _favouritesCollection;
    if (collection == null) throw Exception('User not logged in');
    await collection.doc(placeId).delete();
  }

  /// 🔍 检查是否已收藏
  static Future<bool> isFavourite(String placeId) async {
    final collection = _favouritesCollection;
    if (collection == null) return false;
    final doc = await collection.doc(placeId).get();
    return doc.exists;
  }

  /// 🔄 切换收藏状态
  static Future<bool> toggleFavourite({
    required String placeId,
    required String name,
    required String address,
    double? rating,
    String? photoUrl,
    double? lat,
    double? lng,
    List<String>? types,
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
        types: types,
      );
      return true;
    }
  }

  /// 📋 实时监听收藏列表
  static Stream<List<Map<String, dynamic>>> getFavouritesStream() {
    final collection = _favouritesCollection;
    if (collection == null) return Stream.value([]);

    return collection
        .orderBy('savedAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => doc.data() as Map<String, dynamic>)
            .toList());
  }

  /// 📡 实时监听某个 place 的收藏状态
  static Stream<bool> getFavouriteStatusStream(String placeId) {
    final collection = _favouritesCollection;
    if (collection == null) return Stream.value(false);
    return collection.doc(placeId).snapshots().map((doc) => doc.exists);
  }
}