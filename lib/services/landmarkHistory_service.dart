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
    String? imageBase64Thumbnail, // pass a compressed thumbnail, not full image
    double? lat,
    double? lng,
    String? wikiUrl,
    String? address,
    double? rating,
    String? photoUrl,
    required String detectionMethod,
  }) async {
    if (_uid == null) return;
    try {
      // Avoid duplicate: if same landmark scanned within last 10 minutes, skip
      final recent = await _col
          .where('name', isEqualTo: name)
          .orderBy('scannedAt', descending: true)
          .limit(1)
          .get();

      if (recent.docs.isNotEmpty) {
        final lastScanned =
            (recent.docs.first['scannedAt'] as Timestamp?)?.toDate();
        if (lastScanned != null &&
            DateTime.now().difference(lastScanned).inMinutes < 10) {
          debugPrint('⏭️ Skipping duplicate history entry for "$name"');
          return;
        }
      }

      await _col.add({
        'name':            name,
        'imageBase64':     imageBase64Thumbnail,
        'lat':             lat,
        'lng':             lng,
        'wikiUrl':         wikiUrl,
        'address':         address,
        'rating':          rating,
        'photoUrl':        photoUrl,
        'scannedAt':       FieldValue.serverTimestamp(),
        'detectionMethod': detectionMethod,
      });
      debugPrint('✅ Landmark history saved: $name');
    } catch (e) {
      debugPrint('⚠️ LandmarkHistoryService.save error: $e');
    }
  }

  // ── Fetch history (latest first) ────────────────────────────
  static Future<List<LandmarkHistoryEntry>> fetch({int limit = 20}) async {
    if (_uid == null) return [];
    try {
      final snap = await _col
          .orderBy('scannedAt', descending: true)
          .limit(limit)
          .get();
      return snap.docs
          .map((d) => LandmarkHistoryEntry.fromFirestore(d.id, d.data()))
          .toList();
    } catch (e) {
      debugPrint('⚠️ LandmarkHistoryService.fetch error: $e');
      return [];
    }
  }

  // ── Delete one entry ─────────────────────────────────────────
  static Future<void> delete(String entryId) async {
    if (_uid == null) return;
    await _col.doc(entryId).delete();
  }

  // ── Clear all history ────────────────────────────────────────
  static Future<void> clearAll() async {
    if (_uid == null) return;
    final snap = await _col.get();
    final batch = _db.batch();
    for (final doc in snap.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }
}