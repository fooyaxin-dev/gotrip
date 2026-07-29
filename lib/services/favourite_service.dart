import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'api_Keys.dart';

class FavouriteService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

 

  static const String _apiKey = ApiKeys.googlePlacesNew;
  static const String _baseUrl = 'https://places.googleapis.com/v1';

  static String? get _userId => _auth.currentUser?.uid;

  static CollectionReference? get _favouritesCollection {
    final uid = _userId;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('favourites');
  }

  // users/{uid} document 的 reference
  static DocumentReference? get _userDoc {
    final uid = _userId;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid);
  }

  static Future<List<String>> _fetchTypesFromApi(String placeId) async {
    if (placeId.startsWith('geo_')) return [];
    
    try {
      final cached = await _firestore
          .collection('place_details')
          .doc(placeId)
          .get();

      if (cached.exists) {
        final types = (cached.data()!['types'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [];
        if (types.isNotEmpty) return types;
      }

      final url = Uri.parse('$_baseUrl/places/$placeId');
      final response = await http.get(url, headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': _apiKey,
        'X-Goog-FieldMask': 'types',
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final types = (data['types'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [];

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
    final userDoc = _userDoc;
    if (collection == null || userDoc == null) {
      throw Exception('You need to be logged in to save favourites');
    }

    List<String> finalTypes = (types != null && types.isNotEmpty)
        ? types
        : await _fetchTypesFromApi(placeId);

    try {
      final batch = _firestore.batch();

      batch.set(collection.doc(placeId), {
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

      batch.update(userDoc, {
        'favouriteCount': FieldValue.increment(1),
      });

      await batch.commit();
      print('✅ Added favourite, favouriteCount +1');
    } catch (e) {
      print('❌ addFavourite failed: $e');
      throw Exception('Failed to save to favourites. Please check your connection.');
    }
  }

  static Future<void> removeFavourite(String placeId) async {
    final collection = _favouritesCollection;
    final userDoc = _userDoc;
    if (collection == null || userDoc == null) {
      throw Exception('You need to be logged in to manage favourites');
    }

    try {
      final batch = _firestore.batch();

      batch.delete(collection.doc(placeId));

      final userSnapshot = await userDoc.get();
      final currentCount = (userSnapshot.data() as Map<String, dynamic>?)?['favouriteCount'] ?? 0;
      if (currentCount > 0) {
        batch.update(userDoc, {
          'favouriteCount': FieldValue.increment(-1),
        });
      }

      await batch.commit();
      print('✅ Removed favourite, favouriteCount -1');
    } catch (e) {
      print('❌ removeFavourite failed: $e');
      throw Exception('Failed to remove from favourites. Please check your connection.');
    }
  }
    
    
  static Future<bool> isFavourite(String placeId) async {
    final collection = _favouritesCollection;
    if (collection == null) return false;
    final doc = await collection.doc(placeId).get();
    return doc.exists;
  }

  
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