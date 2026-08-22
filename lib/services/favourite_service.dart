import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'api_Keys.dart';
import 'userActivity_service.dart';

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
    final uid = _userId;

    if (uid == null) {
      throw Exception(
        'You need to be logged in to save favourites',
      );
    }

    final collection = _firestore
        .collection('users')
        .doc(uid)
        .collection('favourites');

    final userDoc =
        _firestore.collection('users').doc(uid);

    try {
      final finalTypes =
          (types != null && types.isNotEmpty)
              ? types
              : await _fetchTypesFromApi(placeId);

      // Account may have changed while place types were loading.
      if (_userId != uid) {
        throw Exception(
          'Your account changed while saving this favourite.',
        );
      }

      final favouriteDoc =
          collection.doc(placeId);

      await _firestore.runTransaction(
        (transaction) async {
          // Check session again before transaction work.
          if (_userId != uid) {
            throw Exception(
              'Your account changed while saving this favourite.',
            );
          }

          final favouriteSnapshot =
              await transaction.get(favouriteDoc);

          // Already saved → don't double increment count.
          if (favouriteSnapshot.exists) {
            return;
          }

          final userSnapshot =
              await transaction.get(userDoc);

          if (!userSnapshot.exists) {
            throw Exception(
              'User profile no longer exists.',
            );
          }

          // Account may still change while transaction retries.
          if (_userId != uid) {
            throw Exception(
              'Your account changed while saving this favourite.',
            );
          }

          transaction.set(
            favouriteDoc,
            {
              'placeId': placeId,
              'name': name,
              'address': address,
              'rating': rating,
              'photoUrl': photoUrl,
              'lat': lat,
              'lng': lng,
              'types': finalTypes,
              'savedAt':
                  FieldValue.serverTimestamp(),
            },
          );

          transaction.update(
            userDoc,
            {
              'favouriteCount':
                  FieldValue.increment(1),
            },
          );
        },
      );

      // Don't invalidate B's cache because an A operation
      // happened to finish after an account switch.
      if (_userId == uid) {
        UserActivityDataService.instance.invalidate();
      }

      print('✅ Favourite added safely');
    } catch (e) {
      print('❌ addFavourite failed: $e');

      throw Exception(
        e.toString().contains('account changed')
            ? 'Your account changed. Please try saving again.'
            : 'Failed to save to favourites. Please check your connection.',
      );
    }
  }
  
  static Future<void> removeFavourite(
  String placeId,
) async {
  final uid = _userId;

  if (uid == null) {
    throw Exception(
      'You need to be logged in to manage favourites',
    );
  }

  final collection = _firestore
      .collection('users')
      .doc(uid)
      .collection('favourites');

  final userDoc =
      _firestore.collection('users').doc(uid);

  final favouriteDoc =
      collection.doc(placeId);

  try {
    // Session must still belong to the user who started
    // this remove operation.
    if (_userId != uid) {
      throw Exception(
        'Your account changed while removing this favourite.',
      );
    }

    await _firestore.runTransaction(
      (transaction) async {
        // Firestore transactions may retry, so re-check
        // the authenticated user inside the transaction.
        if (_userId != uid) {
          throw Exception(
            'Your account changed while removing this favourite.',
          );
        }

        final favouriteSnapshot =
            await transaction.get(favouriteDoc);

        // Favourite already removed → nothing to do.
        if (!favouriteSnapshot.exists) {
          return;
        }

        final userSnapshot =
            await transaction.get(userDoc);

        if (!userSnapshot.exists) {
          throw Exception(
            'User profile no longer exists.',
          );
        }

        // Account may have changed while reads were running.
        if (_userId != uid) {
          throw Exception(
            'Your account changed while removing this favourite.',
          );
        }

        final userData =
            userSnapshot.data()
                as Map<String, dynamic>?;

        final currentCount =
            (userData?['favouriteCount'] as num?)
                    ?.toInt() ??
                0;

        transaction.delete(favouriteDoc);

        // Never allow the stored counter to go negative.
        if (currentCount > 0) {
          transaction.update(
            userDoc,
            {
              'favouriteCount':
                  FieldValue.increment(-1),
            },
          );
        }
      },
    );

    // Only invalidate activity cache if this is still
    // the same authenticated session.
    if (_userId == uid) {
      UserActivityDataService.instance.invalidate();
    }

    print('✅ Favourite removed safely');
  } catch (e) {
    print('❌ removeFavourite failed: $e');

    throw Exception(
      e.toString().contains('account changed')
          ? 'Your account changed. Please try removing the favourite again.'
          : 'Failed to remove from favourites. Please check your connection.',
    );
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
    final uid = _userId;

    if (uid == null) {
      throw Exception(
        'You need to be logged in to manage favourites',
      );
    }

    final isCurrentlyFavourite =
        await isFavourite(placeId);

    if (_userId != uid) {
      throw Exception(
        'Your account changed. Please try again.',
      );
    }

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