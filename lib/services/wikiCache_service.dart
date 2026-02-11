import 'package:cloud_firestore/cloud_firestore.dart';

class WikiCacheService {
  static final _db = FirebaseFirestore.instance;

  static String _docId(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  static Future<Map<String, dynamic>?> get(String landmark) async {
    final doc = await _db
        .collection('wiki_landmarks')
        .doc(_docId(landmark))
        .get();

    if (!doc.exists) return null;
    return doc.data();
  }

  static Future<void> save(
    String landmark,
    Map<String, dynamic> data,
  ) async {
    await _db
        .collection('wiki_landmarks')
        .doc(_docId(landmark))
        .set({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
