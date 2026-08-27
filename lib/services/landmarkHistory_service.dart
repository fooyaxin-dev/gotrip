import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class LandmarkHistoryEntry {
  final String id;
  final String name;
  final String? imageBase64; // store thumbnail only
  final double? lat;
  final double? lng;
  final String? wikiUrl;
  final String? address;
  final double? rating;
  final String? photoUrl;   // Google Places photo
  final DateTime scannedAt;
  final String detectionMethod; // 'vision' | 'gemini'

  const LandmarkHistoryEntry({
    required this.id,
    required this.name,
    this.imageBase64,
    this.lat,
    this.lng,
    this.wikiUrl,
    this.address,
    this.rating,
    this.photoUrl,
    required this.scannedAt,
    required this.detectionMethod,
  });

  factory LandmarkHistoryEntry.fromFirestore(
      String id, Map<String, dynamic> data) {
    return LandmarkHistoryEntry(
      id:              id,
      name:            data['name'] as String? ?? '',
      imageBase64:     data['imageBase64'] as String?,
      lat:             (data['lat'] as num?)?.toDouble(),
      lng:             (data['lng'] as num?)?.toDouble(),
      wikiUrl:         data['wikiUrl'] as String?,
      address:         data['address'] as String?,
      rating:          (data['rating'] as num?)?.toDouble(),
      photoUrl:        data['photoUrl'] as String?,
      scannedAt:       (data['scannedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      detectionMethod: data['detectionMethod'] as String? ?? 'unknown',
    );
  }

  Map<String, dynamic> toFirestore() => {
    'name':            name,
    'imageBase64':     imageBase64,
    'lat':             lat,
    'lng':             lng,
    'wikiUrl':         wikiUrl,
    'address':         address,
    'rating':          rating,
    'photoUrl':        photoUrl,
    'scannedAt':       FieldValue.serverTimestamp(),
    'detectionMethod': detectionMethod,
  };
}

class LandmarkHistoryService {
  static final _db  = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;

  static String? get _uid => _auth.currentUser?.uid;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('users').doc(_uid).collection('landmark_history');

  // ── Save a new scan ──────────────────────────────────────────
  static Future<void> save({
  required String name,
  String? imageBase64Thumbnail,
  double? lat,
  double? lng,
  String? wikiUrl,
  String? address,
  double? rating,
  String? photoUrl,
  required String detectionMethod,
}) async {
  final uid = _uid;

  if (uid == null) {
    return;
  }

  final collection = _db
      .collection('users')
      .doc(uid)
      .collection('landmark_history');

  final docId = _makeDocId(
    name,
    lat,
    lng,
  );

  try {
    if (_uid != uid) {
      return;
    }

    await collection.doc(docId).set(
      {
        'name': name,
        'imageBase64': imageBase64Thumbnail,
        'lat': lat,
        'lng': lng,
        'wikiUrl': wikiUrl,
        'address': address,
        'rating': rating,
        'photoUrl': photoUrl,
        'scannedAt':
            FieldValue.serverTimestamp(),
        'detectionMethod': detectionMethod,
      },
      SetOptions(
        merge: true,
      ),
    );

    if (_uid != uid) {
      debugPrint(
        '⚠️ Landmark history save finished '
        'after account switch.',
      );
    }
  } catch (e) {
    debugPrint(
      '⚠️ LandmarkHistoryService.save error: $e',
    );

    rethrow;
  }
}


  static String _makeDocId(String name, double? lat, double? lng) {
    final normalized = name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    if (lat != null && lng != null) {
      // 经纬度取小数点后3-4位做粗粒度归一，避免GPS漂移导致同一地点算不同ID
      final latKey = lat.toStringAsFixed(3);
      final lngKey = lng.toStringAsFixed(3);
      return '${normalized}_${latKey}_$lngKey';
    }
    return normalized;
  }

  // ── Fetch history (latest first) ────────────────────────────
  static Future<List<LandmarkHistoryEntry>> fetch({
  int limit = 20,
}) async {
  final uid = _uid;

  if (uid == null) {
    return [];
  }

  final collection = _db
      .collection('users')
      .doc(uid)
      .collection('landmark_history');

  try {
    final snap = await collection
        .orderBy(
          'scannedAt',
          descending: true,
        )
        .limit(limit)
        .get();

    // Don't return A's history into B's screen
    // if the account changed while loading.
    if (_uid != uid) {
      return [];
    }

    return snap.docs
        .map(
          (d) =>
              LandmarkHistoryEntry.fromFirestore(
            d.id,
            d.data(),
          ),
        )
        .toList();
  } catch (e) {
    debugPrint(
      '⚠️ LandmarkHistoryService.fetch error: $e',
    );

    return [];
  }
}

  // ── Delete one entry ─────────────────────────────────────────
  static Future<void> delete(
  String entryId,
) async {
  final uid = _uid;

  if (uid == null) {
    return;
  }

  final collection = _db
      .collection('users')
      .doc(uid)
      .collection('landmark_history');

  if (_uid != uid) {
    return;
  }

  await collection
      .doc(entryId)
      .delete();
}

  // ── Clear all history ────────────────────────────────────────
  static Future<void> clearAll() async {
  final uid = _uid;

  if (uid == null) {
    return;
  }

  final collection = _db
      .collection('users')
      .doc(uid)
      .collection('landmark_history');

  try {
    final snap =
        await collection.get();

    // User may have changed while Firestore
    // was loading the history documents.
    if (_uid != uid) {
      return;
    }

    if (snap.docs.isEmpty) {
      return;
    }

    final batch = _db.batch();

    for (final doc in snap.docs) {
      batch.delete(
        doc.reference,
      );
    }

    // Final safety check before destructive write.
    if (_uid != uid) {
      return;
    }

    await batch.commit();
  } catch (e) {
    debugPrint(
      '⚠️ LandmarkHistoryService.clearAll error: $e',
    );

    rethrow;
  }
}

}