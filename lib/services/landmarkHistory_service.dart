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
    if (_uid == null) {
      debugPrint('⚠️ LandmarkHistoryService.save skipped: user not logged in');
      return;
    }

    // ── FIX ──────────────────────────────────────────────────
    // 这段去重查询 (where + orderBy 不同字段) 需要 Firestore 复合索引。
    // 如果索引缺失/还没建好，Firestore 会抛 FAILED_PRECONDITION。
    // 之前这个异常会被外层 catch 吞掉，导致整次 save() 都失败、
    // 一条 history 都存不进去。现在把这段去重检查单独包一层
    // try-catch：查询失败就当作"没有重复"处理，不阻断真正的保存。
    bool isDuplicate = false;
    try {
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
          isDuplicate = true;
        }
      }
    } catch (e) {
      // 常见原因：缺少复合索引 (name + scannedAt)。
      // 报错信息里会带一个可以直接建索引的链接，例如：
      // https://console.firebase.google.com/.../firestore/indexes?create_composite=...
      debugPrint('⚠️ Duplicate-check query failed (continuing to save anyway): $e');
    }

    if (isDuplicate) {
      debugPrint('⏭️ Skipping duplicate history entry for "$name"');
      return;
    }

    try {
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