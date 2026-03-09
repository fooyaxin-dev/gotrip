// services/history_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class HistoryEntry {
  final String id;
  final String placeName;
  final String address;
  final String? photoUrl;
  final DateTime visitedAt;
  final String itineraryId;     // group by trip
  final String itineraryTitle;

  HistoryEntry({
    required this.id,
    required this.placeName,
    required this.address,
    this.photoUrl,
    required this.visitedAt,
    required this.itineraryId,
    required this.itineraryTitle,
  });

  factory HistoryEntry.fromMap(String id, Map<String, dynamic> m) =>
      HistoryEntry(
        id:             id,
        placeName:      m['placeName']      ?? '',
        address:        m['address']        ?? '',
        photoUrl:       m['photoUrl'],
        visitedAt:      (m['visitedAt'] as Timestamp).toDate(),
        itineraryId:    m['itineraryId']    ?? '',
        itineraryTitle: m['itineraryTitle'] ?? '',
      );

  Map<String, dynamic> toMap() => {
    'placeName':      placeName,
    'address':        address,
    'photoUrl':       photoUrl,
    'visitedAt':      Timestamp.fromDate(visitedAt),
    'itineraryId':    itineraryId,
    'itineraryTitle': itineraryTitle,
  };
}

// One card in the collection view
class TripHistory {
  final String itineraryId;
  final String itineraryTitle;
  final List<HistoryEntry> places; // all visited places for this trip
  DateTime get latestVisit =>
      places.map((p) => p.visitedAt).reduce((a, b) => a.isAfter(b) ? a : b);
  String? get coverPhoto =>
      places.firstWhere((p) => p.photoUrl != null,
          orElse: () => places.first).photoUrl;

  TripHistory({
    required this.itineraryId,
    required this.itineraryTitle,
    required this.places,
  });
}

class HistoryService {
  static final HistoryService instance = HistoryService._();
  HistoryService._();

  final _db = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference? get _col => _uid == null
      ? null
      : _db.collection('users').doc(_uid).collection('history');

  Future<void> addEntry({
    required String placeName,
    required String address,
    String? photoUrl,
    required DateTime visitedAt,
    required String itineraryId,
    required String itineraryTitle,
  }) async {
    if (_col == null) return;
    try {
      await _col!.add(HistoryEntry(
        id:             '',
        placeName:      placeName,
        address:        address,
        photoUrl:       photoUrl,
        visitedAt:      visitedAt,
        itineraryId:    itineraryId,
        itineraryTitle: itineraryTitle,
      ).toMap());
    } catch (e) {
      print('❌ HistoryService.addEntry: $e');
    }
  }

  // Returns entries grouped by itinerary, newest trip first
  Future<List<TripHistory>> fetchGrouped() async {
    if (_col == null) return [];
    try {
      final snap = await _col!.orderBy('visitedAt', descending: true).get();
      final entries = snap.docs
          .map((d) => HistoryEntry.fromMap(d.id, d.data() as Map<String, dynamic>))
          .toList();

      // Group by itineraryId
      final Map<String, TripHistory> grouped = {};
      for (final e in entries) {
        if (grouped.containsKey(e.itineraryId)) {
          grouped[e.itineraryId]!.places.add(e);
        } else {
          grouped[e.itineraryId] = TripHistory(
            itineraryId:    e.itineraryId,
            itineraryTitle: e.itineraryTitle,
            places:         [e],
          );
        }
      }

      // Sort trips: most recently visited first
      final trips = grouped.values.toList()
        ..sort((a, b) => b.latestVisit.compareTo(a.latestVisit));

      return trips;
    } catch (e) {
      print('❌ HistoryService.fetchGrouped: $e');
      return [];
    }
  }
}