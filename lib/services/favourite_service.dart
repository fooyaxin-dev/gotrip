import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show debugPrint;
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
      final cached =
          await _firestore.collection('place_details').doc(placeId).get();

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
        final types =
            (data['types'] as List?)?.map((e) => e.toString()).toList() ?? [];

        if (types.isNotEmpty) {
          // Use set(merge:true) so the doc is created if it doesn't
          // yet exist — fixes the case where types were fetched but
          // never persisted because the previous code used update()
          // (which silently no-ops on a missing document).
          await _firestore
              .collection('place_details')
              .doc(placeId)
              .set({'types': types}, SetOptions(merge: true));
        }
        return types;
      }
    } catch (e) {
      debugPrint('⚠️ Failed to fetch types: $e');
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
    String source = 'place',
    String? googlePlaceId,
  }) async {
    final uid = _userId;

    if (uid == null) {
      throw Exception(
        'You need to be logged in to save favourites',
      );
    }

    final collection =
        _firestore.collection('users').doc(uid).collection('favourites');

    final userDoc = _firestore.collection('users').doc(uid);

    try {
      final finalTypes = (types != null && types.isNotEmpty)
          ? types
          : await _fetchTypesFromApi(placeId);

      // Account may have changed while place types were loading.
      if (_userId != uid) {
        throw Exception(
          'Your account changed while saving this favourite.',
        );
      }

      final favouriteDoc = collection.doc(placeId);

      await _firestore.runTransaction(
        (transaction) async {
          // Check session again before transaction work.
          if (_userId != uid) {
            throw Exception(
              'Your account changed while saving this favourite.',
            );
          }

          final favouriteSnapshot = await transaction.get(favouriteDoc);

          // Already saved → update source/googlePlaceId without double incrementing count.
          if (favouriteSnapshot.exists) {
            final updateData = <String, dynamic>{
              'source': source,
            };
            if (googlePlaceId != null && googlePlaceId.isNotEmpty) {
              updateData['googlePlaceId'] = googlePlaceId;
            }
            transaction.set(
              favouriteDoc,
              updateData,
              SetOptions(merge: true),
            );
            return;
          }

          final userSnapshot = await transaction.get(userDoc);

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

          final favouriteData = <String, dynamic>{
            'placeId': placeId,
            'source': source,
            'name': name,
            'address': address,
            'rating': rating,
            'photoUrl': photoUrl,
            'lat': lat,
            'lng': lng,
            'types': finalTypes,
            'savedAt': FieldValue.serverTimestamp(),
          };

          if (googlePlaceId != null && googlePlaceId.isNotEmpty) {
            favouriteData['googlePlaceId'] = googlePlaceId;
          }

          transaction.set(
            favouriteDoc,
            favouriteData,
          );

          transaction.update(
            userDoc,
            {
              'favouriteCount': FieldValue.increment(1),
            },
          );
        },
      );

      // Don't invalidate B's cache because an A operation
      // happened to finish after an account switch.
      if (_userId == uid) {
        UserActivityDataService.instance.invalidate();
      }

      debugPrint('✅ Favourite added safely');
    } catch (e) {
      debugPrint('❌ addFavourite failed: $e');
      if (e.toString().contains('account changed')) {
        throw Exception('Your account changed. Please try saving again.');
      }
      rethrow;
    }
  }

  static Future<void> removeFavourite(
    String placeId,
  ) async {
    final uid = _userId;

    if (uid == null) {
      throw FirebaseAuthException(
        code: 'unauthenticated',
        message: 'You need to be logged in to manage favourites',
      );
    }

    final collection =
        _firestore.collection('users').doc(uid).collection('favourites');

    final userDoc = _firestore.collection('users').doc(uid);

    final favouriteDoc = collection.doc(placeId);

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

          final favouriteSnapshot = await transaction.get(favouriteDoc);

          // Favourite already removed → nothing to do.
          if (!favouriteSnapshot.exists) {
            return;
          }

          final userSnapshot = await transaction.get(userDoc);

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

          final userData = userSnapshot.data() as Map<String, dynamic>?;

          final currentCount =
              (userData?['favouriteCount'] as num?)?.toInt() ?? 0;

          transaction.delete(favouriteDoc);

          // Never allow the stored counter to go negative.
          if (currentCount > 0) {
            transaction.update(
              userDoc,
              {
                'favouriteCount': FieldValue.increment(-1),
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

      debugPrint('✅ Favourite removed safely');
    } catch (e) {
      debugPrint('❌ removeFavourite failed: $e');
      if (e.toString().contains('account changed')) {
        throw Exception(
            'Your account changed. Please try removing the favourite again.');
      }
      rethrow;
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
      throw FirebaseAuthException(
        code: 'unauthenticated',
        message: 'You need to be logged in to manage favourites',
      );
    }

    final isCurrentlyFavourite = await isFavourite(placeId);

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

    return collection.orderBy('savedAt', descending: true).snapshots().map(
        (snapshot) => snapshot.docs
            .map((doc) => doc.data() as Map<String, dynamic>)
            .toList());
  }

  /// Calculates geodesic distance between two points in metres using Haversine formula.
  static double _haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadiusMeters = 6371000.0;
    final dLat = (lat2 - lat1) * (math.pi / 180.0);
    final dLon = (lon2 - lon1) * (math.pi / 180.0);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * (math.pi / 180.0)) *
            math.cos(lat2 * (math.pi / 180.0)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Pure matcher used for selecting legacy landmark favourite ID among user's favourites.
  /// Considers ONLY candidates with source == 'landmark'.
  /// Priority:
  /// 1. googlePlaceId match (if both non-empty)
  /// 2. exact normalized stored name match (case-insensitive trimmed)
  /// 3. conservative coordinate proximity <= 30 metres
  /// Tie-breaker for multiple duplicate candidates: earliest savedAt timestamp.
  static String? selectMatchingLandmarkFavouriteId(
    List<Map<String, dynamic>> favourites, {
    String? googlePlaceId,
    String? name,
    double? lat,
    double? lng,
  }) {
    final validGpid = googlePlaceId?.trim();
    final hasValidGpid = validGpid != null && validGpid.isNotEmpty;

    final normName = name?.trim().toLowerCase();
    final hasValidName = normName != null && normName.isNotEmpty;

    final hasValidCoords = lat != null && lng != null;

    // Filter strictly for source == 'landmark' documents
    final landmarkCandidates = favourites.where((fav) {
      final source = (fav['source'] as String?)?.trim().toLowerCase();
      return source == 'landmark';
    }).toList();

    if (landmarkCandidates.isEmpty) return null;

    // Sort candidates by savedAt ascending (earliest first) for deterministic tie-breaking
    int compareSavedAt(Map<String, dynamic> a, Map<String, dynamic> b) {
      DateTime extractDate(dynamic raw) {
        if (raw is Timestamp) return raw.toDate();
        if (raw is DateTime) return raw;
        if (raw is String) {
          try {
            return DateTime.parse(raw);
          } catch (_) {}
        }
        return DateTime.fromMillisecondsSinceEpoch(0);
      }

      final dateA = extractDate(a['savedAt']);
      final dateB = extractDate(b['savedAt']);
      return dateA.compareTo(dateB);
    }

    landmarkCandidates.sort(compareSavedAt);

    // 1. Google Place ID match
    if (hasValidGpid) {
      for (final fav in landmarkCandidates) {
        final favGpid = (fav['googlePlaceId'] as String?)?.trim();
        final favPlaceId = (fav['placeId'] as String?)?.trim();
        if (favGpid == validGpid || favPlaceId == validGpid) {
          final matchedId = (fav['placeId'] as String?)?.trim();
          if (matchedId != null && matchedId.isNotEmpty) {
            return matchedId;
          }
        }
      }
    }

    // 2. Exact normalized name match
    if (hasValidName) {
      for (final fav in landmarkCandidates) {
        final favName = (fav['name'] as String?)?.trim().toLowerCase();
        if (favName != null && favName.isNotEmpty && favName == normName) {
          final matchedId = (fav['placeId'] as String?)?.trim();
          if (matchedId != null && matchedId.isNotEmpty) {
            return matchedId;
          }
        }
      }
    }

    // 3. Conservative coordinate match (distance <= 30m)
    if (hasValidCoords) {
      for (final fav in landmarkCandidates) {
        final favLat = (fav['lat'] as num?)?.toDouble();
        final favLng = (fav['lng'] as num?)?.toDouble();
        if (favLat != null && favLng != null) {
          final dist = _haversineDistance(lat, lng, favLat, favLng);
          if (dist <= 30.0) {
            final matchedId = (fav['placeId'] as String?)?.trim();
            if (matchedId != null && matchedId.isNotEmpty) {
              return matchedId;
            }
          }
        }
      }
    }

    return null;
  }

  /// Narrowly scoped, read-only method to find an existing Favourite document ID
  /// for a legacy Landmark History entry.
  static Future<String?> findMatchingLandmarkFavouriteId({
    String? googlePlaceId,
    String? name,
    double? lat,
    double? lng,
  }) async {
    final uid = _userId;
    if (uid == null) return null;

    final collection = _favouritesCollection;
    if (collection == null) return null;

    try {
      final snapshot = await collection.get();
      if (_userId != uid) return null;

      final favourites = snapshot.docs.map((d) {
        final data = d.data() as Map<String, dynamic>? ?? {};
        if (!data.containsKey('placeId')) {
          data['placeId'] = d.id;
        }
        return data;
      }).toList();

      return selectMatchingLandmarkFavouriteId(
        favourites,
        googlePlaceId: googlePlaceId,
        name: name,
        lat: lat,
        lng: lng,
      );
    } catch (e) {
      debugPrint('⚠️ findMatchingLandmarkFavouriteId error: $e');
      return null;
    }
  }

  /// 📡 实时监听某个 place 的收藏状态
  static Stream<bool> getFavouriteStatusStream(String placeId) {
    final collection = _favouritesCollection;
    if (collection == null) return Stream.value(false);
    return collection.doc(placeId).snapshots().map((doc) => doc.exists);
  }
}
