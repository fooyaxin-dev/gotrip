// services/journal_meta_service.dart
//
// Stores the user's OWN curated photo picks for a journal day-page,
// separate from the automatic check-in photos in HistoryEntry.
// If no doc exists for a given (itineraryId, day), the journal page
// falls back to the auto check-in photos — see journalPage.dart.

import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class JournalDayMeta {
  final List<String>? photos; // null = not customised -> caller falls back to auto
  final String? notes;        // null = not customised -> caller falls back to auto
  const JournalDayMeta({required this.photos, required this.notes});
}

class JournalMetaService {
  static final JournalMetaService instance = JournalMetaService._();
  JournalMetaService._();

  final _db = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // Public — journalBook.dart needs this to key its batch-fetched map.
  String docId(String itineraryId, DateTime day) {
    final d = '${day.year}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';
    return '${itineraryId}_$d';
  }

  DocumentReference<Map<String, dynamic>>? _doc(String itineraryId, DateTime day) {
    final uid = _uid;
    if (uid == null) return null;
    return _db
        .collection('users')
        .doc(uid)
        .collection('journalDays')
        .doc(docId(itineraryId, day));
  }

  /// One query for the WHOLE book instead of one per page — call this once
  /// when the book opens, keyed by docId(itineraryId, day). Avoids the
  /// "shows auto content, then pops to custom content a few seconds later"
  /// flash you get from letting each page fetch independently.
  Future<Map<String, JournalDayMeta>> fetchAllMeta() async {
    final uid = _uid;
    if (uid == null) return {};
    try {
      final snap = await _db.collection('users').doc(uid).collection('journalDays').get();
      final map = <String, JournalDayMeta>{};
      for (final doc in snap.docs) {
        final data = doc.data();
        final list = data['photos'];
        final photos = list is List ? list.map((e) => e.toString()).toList() : null;
        final notes = data['notes'] as String?;
        map[doc.id] = JournalDayMeta(photos: photos, notes: notes);
      }
      return map;
    } catch (e) {
      print('❌ JournalMetaService.fetchAllMeta: $e');
      return {};
    }
  }

  /// Single read for both fields — photos and notes live in the same
  /// doc so editing one never has to know about (or clobber) the other.
  /// Both come back null when the user has never customised that field;
  /// the caller falls back to auto-generated content in that case.
  Future<JournalDayMeta> fetchMeta(String itineraryId, DateTime day) async {
    final doc = _doc(itineraryId, day);
    if (doc == null) return const JournalDayMeta(photos: null, notes: null);
    try {
      final snap = await doc.get();
      if (!snap.exists) return const JournalDayMeta(photos: null, notes: null);
      final data = snap.data();
      final list = data?['photos'];
      final photos = list is List ? list.map((e) => e.toString()).toList() : null;
      final notes = data?['notes'] as String?;
      return JournalDayMeta(photos: photos, notes: notes);
    } catch (e) {
      print('❌ JournalMetaService.fetchMeta: $e');
      return const JournalDayMeta(photos: null, notes: null);
    }
  }

  /// merge: true so saving photos never wipes out notes, and vice versa.
  Future<void> savePhotos(String itineraryId, DateTime day, List<String> photos) async {
    final doc = _doc(itineraryId, day);
    if (doc == null) {
      throw Exception('You need to be logged in to edit your journal photos');
    }
    await doc.set({
      'photos': photos,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> saveNotes(String itineraryId, DateTime day, String notes) async {
    final doc = _doc(itineraryId, day);
    if (doc == null) {
      throw Exception('You need to be logged in to edit your journal');
    }
    await doc.set({
      'notes': notes,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Uploads a picked gallery image to Storage and returns its download URL.
  Future<String> uploadPhoto(String itineraryId, DateTime day, File file) async {
    final uid = _uid;
    if (uid == null) throw Exception('You need to be logged in to upload photos');
    final id = docId(itineraryId, day);
    final ref = FirebaseStorage.instance.ref(
      'users/$uid/journal_photos/$id/${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    final task = await ref.putFile(file);
    return task.ref.getDownloadURL();
  }
}