// services/history_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'userActivity_service.dart';

String _extractCity(String address) {
  if (address.isEmpty) return '';

  final postcodeRegex = RegExp(r'\d{4,6}\s+([A-Za-z][^,]+)');
  final postcodeMatch = postcodeRegex.firstMatch(address);
  if (postcodeMatch != null) {
    return postcodeMatch.group(1)!.trim();
  }

  final parts = address.split(',').map((s) => s.trim()).toList();
  if (parts.length >= 2) {
    final candidate = parts[parts.length - 2];
    if (!RegExp(r'^\d+$').hasMatch(candidate) && candidate.isNotEmpty) {
      return candidate;
    }
  }

  if (parts.isNotEmpty) return parts.last;
  return '';
}

class HistoryEntry {
  final String id;
  final String placeName;
  final String address;
  final String? photoUrl;
  final DateTime visitedAt;
  final String itineraryId;
  final String itineraryTitle;
  final String? placeId;
  final String? primaryType;
  final String? city;
  final double? lat;
  final double? lng;

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
    this.lat,
    this.lng,
  });

  factory HistoryEntry.fromMap(String id, Map<String, dynamic> m) =>
      HistoryEntry(
        id: id,
        placeName: m['placeName'] ?? '',
        address: m['address'] ?? '',
        photoUrl: m['photoUrl'],
        visitedAt: (m['visitedAt'] as Timestamp).toDate(),
        itineraryId: m['itineraryId'] ?? '',
        itineraryTitle: m['itineraryTitle'] ?? '',
        placeId: m['placeId'],
        primaryType: m['primaryType'],
        city: m['city'],
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toMap() => {
        'placeName': placeName,
        'address': address,
        'photoUrl': photoUrl,
        'visitedAt': Timestamp.fromDate(visitedAt),
        'itineraryId': itineraryId,
        'itineraryTitle': itineraryTitle,
        'placeId': placeId,
        'primaryType': primaryType,
        'city': city,
        'lat': lat,
        'lng': lng,
      };
}

class TripHistory {
  final String itineraryId;
  final String itineraryTitle;
  final List<HistoryEntry> places;

  DateTime get latestVisit =>
      places.map((p) => p.visitedAt).reduce((a, b) => a.isAfter(b) ? a : b);

  String? get coverPhoto => places
      .firstWhere(
        (p) => p.photoUrl != null,
        orElse: () => places.first,
      )
      .photoUrl;

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

  /// Creates the canonical history payload used by both normal history writes
  /// and the atomic itinerary check-in batch.
  Map<String, dynamic> buildEntryData({
    required String placeName,
    required String address,
    String? photoUrl,
    required DateTime visitedAt,
    required String itineraryId,
    required String itineraryTitle,
    String? placeId,
    String? primaryType,
    double? lat,
    double? lng,
  }) {
    final city = _extractCity(address);

    return HistoryEntry(
      id: '',
      placeName: placeName,
      address: address,
      photoUrl: photoUrl,
      visitedAt: visitedAt,
      itineraryId: itineraryId,
      itineraryTitle: itineraryTitle,
      placeId: placeId,
      primaryType: primaryType,
      city: city.isNotEmpty ? city : null,
      lat: lat,
      lng: lng,
    ).toMap();
  }

  Future<void> addEntry({
    required String placeName,
    required String address,
    String? photoUrl,
    required DateTime visitedAt,
    required String itineraryId,
    required String itineraryTitle,
    String? placeId,
    String? primaryType,
    double? lat,
    double? lng,
  }) async {
    final uid = _uid;

    if (uid == null) {
      throw Exception('You need to be logged in to save visit history');
    }

    final historyCollection =
        _db.collection('users').doc(uid).collection('history');

    try {
      if (_uid != uid) {
        throw Exception('Your account changed while saving visit history.');
      }

      await historyCollection.add(
        buildEntryData(
          placeName: placeName,
          address: address,
          photoUrl: photoUrl,
          visitedAt: visitedAt,
          itineraryId: itineraryId,
          itineraryTitle: itineraryTitle,
          placeId: placeId,
          primaryType: primaryType,
          lat: lat,
          lng: lng,
        ),
      );

      if (_uid == uid) {
        UserActivityDataService.instance.invalidate();
      }
    } catch (e) {
      print('❌ HistoryService.addEntry: $e');

      if (e.toString().contains('account changed')) {
        throw Exception('Your account changed. Please try the check-in again.');
      }

      throw Exception(
        'Failed to save this visit to your history. '
        'Your check-in may not appear in Dashboard stats.',
      );
    }
  }

  List<TripHistory> _groupAndSort(List<HistoryEntry> entries) {
    final Map<String, TripHistory> grouped = {};
    for (final entry in entries) {
      if (grouped.containsKey(entry.itineraryId)) {
        grouped[entry.itineraryId]!.places.add(entry);
      } else {
        grouped[entry.itineraryId] = TripHistory(
          itineraryId: entry.itineraryId,
          itineraryTitle: entry.itineraryTitle,
          places: [entry],
        );
      }
    }

    final trips = grouped.values.toList()
      ..sort((a, b) => b.latestVisit.compareTo(a.latestVisit));
    return trips;
  }

  Future<List<TripHistory>> fetchGrouped() async {
    final collection = _col;
    if (collection == null) return [];

    try {
      final snap = await collection.orderBy('visitedAt', descending: true).get();
      final entries = snap.docs
          .map(
            (d) => HistoryEntry.fromMap(
              d.id,
              d.data() as Map<String, dynamic>,
            ),
          )
          .toList();
      return _groupAndSort(entries);
    } catch (e) {
      print('❌ HistoryService.fetchGrouped: $e');
      return [];
    }
  }

  Stream<List<TripHistory>> streamGrouped() {
    final collection = _col;
    if (collection == null) return Stream.value([]);

    return collection
        .orderBy('visitedAt', descending: true)
        .snapshots()
        .map((snap) {
      final entries = snap.docs
          .map(
            (d) => HistoryEntry.fromMap(
              d.id,
              d.data() as Map<String, dynamic>,
            ),
          )
          .toList();
      return _groupAndSort(entries);
    });
  }
}
