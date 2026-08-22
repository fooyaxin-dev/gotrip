// services/userActivity_service.dart
//
// Shared raw-data layer for anything that needs to read the user's
// `history` / `itineraries` / `favourites` collections.
//
// Both DashboardPage and AchievementService independently queried these
// same three collections and recomputed their own view of the data. When
// a user switched between Dashboard and Profile (or Home) within a few
// seconds, that meant 2 full Firestore reads of the same underlying data
// for no reason — nothing had changed in between.
//
// This service does the actual `.get()` calls ONCE and caches the raw
// docs for a short TTL. Consumers still do their own computation on top
// (Dashboard needs month/filter slicing, Achievement needs all-time
// aggregates) — only the "read from Firestore" step is shared.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

/// A lightweight (docId, data) pair — avoids exposing Firestore's
/// QueryDocumentSnapshot type to every consumer.
class ActivityDoc {
  final String id;
  final Map<String, dynamic> data;
  const ActivityDoc(this.id, this.data);
}

class UserActivityDataService {
  UserActivityDataService._();
  static final UserActivityDataService instance = UserActivityDataService._();

  final _db = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  List<ActivityDoc>? _historyDocs;
  List<ActivityDoc>? _itineraryDocs;
  List<ActivityDoc>? _favouriteDocs;
  DateTime? _cachedAt;
  String? _cachedUid;

  static const _cacheTtl = Duration(seconds: 30);

  bool get _isFresh =>
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl &&
      _historyDocs != null &&
      _itineraryDocs != null &&
      _favouriteDocs != null;

  /// Call this after any write that changes history/itineraries/favourites
  /// (check-in, favourite toggle, itinerary save/delete) so the next read
  /// is guaranteed fresh instead of serving a stale cache.
  void invalidate() {
    _historyDocs = null;
    _itineraryDocs = null;
    _favouriteDocs = null;
    _cachedAt = null;
    _cachedUid = null;
}

  Future<void> _loadAll({
    bool forceRefresh = false,
  }) async {
    final uid = _uid;

    // ── No logged-in user ─────────────────────────────
    if (uid == null) {
      _historyDocs = [];
      _itineraryDocs = [];
      _favouriteDocs = [];
      _cachedAt = DateTime.now();
      _cachedUid = null;
      return;
    }

    // ── Cache can ONLY be reused by the same user ─────
    final sameUser = _cachedUid == uid;

    if (!forceRefresh && sameUser && _isFresh) {
      if (kDebugMode) {
        print(
          '🧠 UserActivityDataService: cache hit '
          'for $uid '
          '(age: ${DateTime.now().difference(_cachedAt!).inSeconds}s)',
        );
      }

      return;
    }

    // Account changed while app process is still alive.
    // Never expose the previous user's cached activity.
    if (!sameUser) {
      _historyDocs = null;
      _itineraryDocs = null;
      _favouriteDocs = null;
      _cachedAt = null;
    }

    final results = await Future.wait([
      _db
          .collection('users')
          .doc(uid)
          .collection('history')
          .get(),

      _db
          .collection('users')
          .doc(uid)
          .collection('itineraries')
          .get(),

      _db
          .collection('users')
          .doc(uid)
          .collection('favourites')
          .get(),
    ]);

    // User may have logged out / switched account while
    // Firestore requests were still running.
    if (_uid != uid) {
      return;
    }

    _historyDocs = (results[0] as QuerySnapshot)
        .docs
        .map(
          (d) => ActivityDoc(
            d.id,
            d.data() as Map<String, dynamic>,
          ),
        )
        .toList();

    _itineraryDocs = (results[1] as QuerySnapshot)
        .docs
        .map(
          (d) => ActivityDoc(
            d.id,
            d.data() as Map<String, dynamic>,
          ),
        )
        .toList();

    _favouriteDocs = (results[2] as QuerySnapshot)
        .docs
        .map(
          (d) => ActivityDoc(
            d.id,
            d.data() as Map<String, dynamic>,
          ),
        )
        .toList();

    _cachedUid = uid;
    _cachedAt = DateTime.now();

    if (kDebugMode) {
      print(
        '🌐 UserActivityDataService: fresh read '
        'for $uid '
        '(history: ${_historyDocs!.length}, '
        'itineraries: ${_itineraryDocs!.length}, '
        'favourites: ${_favouriteDocs!.length})',
      );
    }
  }
  
  Future<List<ActivityDoc>> getHistoryDocs({bool forceRefresh = false}) async {
    await _loadAll(forceRefresh: forceRefresh);
    return _historyDocs!;
  }

  Future<List<ActivityDoc>> getItineraryDocs({bool forceRefresh = false}) async {
    await _loadAll(forceRefresh: forceRefresh);
    return _itineraryDocs!;
  }

  Future<List<ActivityDoc>> getFavouriteDocs({bool forceRefresh = false}) async {
    await _loadAll(forceRefresh: forceRefresh);
    return _favouriteDocs!;
  }

  /// Convenience — fetch all three at once (this is what Dashboard needs).
  Future<({
    List<ActivityDoc> history,
    List<ActivityDoc> itineraries,
    List<ActivityDoc> favourites,
  })> getAll({bool forceRefresh = false}) async {
    await _loadAll(forceRefresh: forceRefresh);
    return (history: _historyDocs!, itineraries: _itineraryDocs!, favourites: _favouriteDocs!);
  }
}