// services/history_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// ─────────────────────────────────────────────────────────────────────────────
// City Extractor (same logic as dashboard)
// ─────────────────────────────────────────────────────────────────────────────

String _extractCity(String address) {
  if (address.isEmpty) return '';

  // Strategy 1: postcode pattern — "50000 Kuala Lumpur"
  final postcodeRegex = RegExp(r'\d{4,6}\s+([A-Za-z][^,]+)');
  final postcodeMatch = postcodeRegex.firstMatch(address);
  if (postcodeMatch != null) {
    return postcodeMatch.group(1)!.trim();
  }

  // Strategy 2: second-to-last segment
  final parts = address.split(',').map((s) => s.trim()).toList();
  if (parts.length >= 2) {
    final candidate = parts[parts.length - 2];
    if (!RegExp(r'^\d+$').hasMatch(candidate) && candidate.isNotEmpty) {
      return candidate;
    }
  }

  // Strategy 3: last segment
  if (parts.isNotEmpty) return parts.last;
  return '';
}

// ─────────────────────────────────────────────────────────────────────────────
// HistoryEntry
// ─────────────────────────────────────────────────────────────────────────────

class HistoryEntry {
  final String id;
  final String placeName;
  final String address;
  final String? photoUrl;
  final DateTime visitedAt;
  final String itineraryId;
  final String itineraryTitle;
  final String? placeId;      // ← 新增：Google Place ID
  final String? primaryType;  // ← 新增：e.g. 'restaurant', 'park'
  final String? city;         // ← 新增：extracted from address
  final double? lat;   // ★ 新增
  final double? lng;   // ★ 新增

  HistoryEntry({
    required this.id,
    required this.placeName,
    required this.address,
    this.photoUrl,
    required this.visitedAt,
    required this.itineraryId,
    required this.itineraryTitle,
    this.placeId,
    this.primaryType,
    this.city,
    this.lat,   // ★ 新增
    this.lng,   // ★ 新增
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
        placeId:        m['placeId'],
        primaryType:    m['primaryType'],
        city:           m['city'],
        lat:            (m['lat'] as num?)?.toDouble(),  // ★ 新增
        lng:            (m['lng'] as num?)?.toDouble(),  // ★ 新增
      );

  Map<String, dynamic> toMap() => {
    'placeName':      placeName,
    'address':        address,
    'photoUrl':       photoUrl,
    'visitedAt':      Timestamp.fromDate(visitedAt),
    'itineraryId':    itineraryId,
    'itineraryTitle': itineraryTitle,
    'placeId':        placeId,
    'primaryType':    primaryType,
    'city':           city,
    'lat':            lat,
    'lng':            lng,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// TripHistory — one card in the collection view
// ─────────────────────────────────────────────────────────────────────────────

class TripHistory {
  final String itineraryId;
  final String itineraryTitle;
  final List<HistoryEntry> places;

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

// ─────────────────────────────────────────────────────────────────────────────
// HistoryService
// ─────────────────────────────────────────────────────────────────────────────

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
    String? placeId,      // ← 新增
    String? primaryType,  // ← 新增
    double? lat,   // ★ 新增
    double? lng,   // ★ 新增
  }) async {
    if (_col == null) return;

    // Auto-extract city from address
    final city = _extractCity(address);

    try {
      await _col!.add(HistoryEntry(
        id:             '',
        placeName:      placeName,
        address:        address,
        photoUrl:       photoUrl,
        visitedAt:      visitedAt,
        itineraryId:    itineraryId,
        itineraryTitle: itineraryTitle,
        placeId:        placeId,
        primaryType:    primaryType,
        city:           city.isNotEmpty ? city : null,
        lat:            lat,   // ★ 新增
        lng:            lng,   // ★ 新增
      ).toMap());
    } catch (e) {
      print('❌ HistoryService.addEntry: $e');
    }
  }

  // Returns entries grouped by itinerary, newest trip first
  Future<List<TripHistory>> fetchGrouped() async {
    if (_col == null) return [];
    try {
      final snap = await _col!
          .orderBy('visitedAt', descending: true)
          .get();

      final entries = snap.docs
          .map((d) => HistoryEntry.fromMap(
                d.id, d.data() as Map<String, dynamic>))
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