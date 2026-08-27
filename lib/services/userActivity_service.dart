// services/userActivity_service.dart
//
// Shared raw-data layer for Dashboard, Achievement and other modules that
// consume the user's history / itineraries / favourites collections.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

class ActivityDoc {
  final String id;
  final Map<String, dynamic> data;

  const ActivityDoc(this.id, this.data);
}

class UserActivityDataService {
  UserActivityDataService._();
  static final UserActivityDataService instance =
      UserActivityDataService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  List<ActivityDoc>? _historyDocs;
  List<ActivityDoc>? _itineraryDocs;
  List<ActivityDoc>? _favouriteDocs;
  DateTime? _cachedAt;
  String? _cachedUid;

  // Tracks the account whose requests/cache this singleton currently owns.
  String? _sessionUid;

  // Every invalidation, forced refresh or account switch advances this value.
  // A request may commit its result only if its captured generation is still
  // current when all Firestore reads finish.
  int _cacheGeneration = 0;

  // Multiple consumers requesting the same generation share this one Future.
  Future<void>? _inFlightLoad;
  String? _inFlightUid;
  int? _inFlightGeneration;
  bool _inFlightWasForced = false;

  static const Duration _cacheTtl = Duration(seconds: 30);

  bool get _isFresh =>
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl &&
      _historyDocs != null &&
      _itineraryDocs != null &&
      _favouriteDocs != null;

  bool _hasCompleteCacheFor(String uid) =>
      _cachedUid == uid &&
      _historyDocs != null &&
      _itineraryDocs != null &&
      _favouriteDocs != null;

  void _clearCachedData() {
    _historyDocs = null;
    _itineraryDocs = null;
    _favouriteDocs = null;
    _cachedAt = null;
    _cachedUid = null;
  }

  void _detachInFlightLoad() {
    // Firestore reads cannot be cancelled, but detaching means new callers do
    // not join an obsolete request. Its generation check prevents it from
    // committing when it eventually finishes.
    _inFlightLoad = null;
    _inFlightUid = null;
    _inFlightGeneration = null;
    _inFlightWasForced = false;
  }

  void _syncSession(String? uid) {
    if (_sessionUid == uid) return;

    _sessionUid = uid;
    _cacheGeneration++;
    _clearCachedData();
    _detachInFlightLoad();
  }

  /// Call after a successful write that changes history, itineraries or
  /// favourites. Any older read still running becomes unable to repopulate the
  /// cache with its pre-write snapshot.
  void invalidate() {
    _cacheGeneration++;
    _clearCachedData();
    _detachInFlightLoad();

    if (kDebugMode) {
      print(
        '🧹 UserActivityDataService: cache invalidated '
        '(generation=$_cacheGeneration)',
      );
    }
  }

  Future<void>? _matchingInFlightLoad({
    required String uid,
    required int generation,
  }) {
    if (_inFlightLoad != null &&
        _inFlightUid == uid &&
        _inFlightGeneration == generation) {
      return _inFlightLoad;
    }
    return null;
  }

  Future<void> _loadAll({
    bool forceRefresh = false,
  }) async {
    final uid = _uid;
    _syncSession(uid);

    if (uid == null) {
      _historyDocs = <ActivityDoc>[];
      _itineraryDocs = <ActivityDoc>[];
      _favouriteDocs = <ActivityDoc>[];
      _cachedAt = DateTime.now();
      _cachedUid = null;
      return;
    }

    if (!forceRefresh && _cachedUid == uid && _isFresh) {
      if (kDebugMode) {
        print(
          '🧠 UserActivityDataService: cache hit for $uid '
          '(age: ${DateTime.now().difference(_cachedAt!).inSeconds}s)',
        );
      }
      return;
    }

    // Two simultaneous forced refresh calls may share the same already-forced
    // request. A forced refresh must not join an older normal request.
    if (forceRefresh) {
      final currentForcedLoad = _matchingInFlightLoad(
        uid: uid,
        generation: _cacheGeneration,
      );

      if (currentForcedLoad != null && _inFlightWasForced) {
        final joinedGeneration = _cacheGeneration;
        if (kDebugMode) {
          print('⏳ UserActivityDataService: joining forced load for $uid');
        }
        await currentForcedLoad;

        if (_uid == uid &&
            _sessionUid == uid &&
            joinedGeneration != _cacheGeneration &&
            !_hasCompleteCacheFor(uid)) {
          await _loadAll();
        }
        return;
      }

      _cacheGeneration++;
      _clearCachedData();
      _detachInFlightLoad();
    }

    final generation = _cacheGeneration;
    final existingLoad = _matchingInFlightLoad(
      uid: uid,
      generation: generation,
    );

    if (existingLoad != null) {
      if (kDebugMode) {
        print('⏳ UserActivityDataService: joining shared load for $uid');
      }
      await existingLoad;
    } else {
      late final Future<void> task;
      task = _performLoad(
        uid: uid,
        generation: generation,
      ).whenComplete(() {
        // An obsolete request must not clear the reference to a newer load.
        if (identical(_inFlightLoad, task)) {
          _detachInFlightLoad();
        }
      });

      _inFlightLoad = task;
      _inFlightUid = uid;
      _inFlightGeneration = generation;
      _inFlightWasForced = forceRefresh;

      await task;
    }

    // If a write invalidated this generation while it was loading, immediately
    // join/start the current generation rather than returning an empty or stale
    // snapshot to the caller.
    if (_uid == uid &&
        _sessionUid == uid &&
        generation != _cacheGeneration &&
        !_hasCompleteCacheFor(uid)) {
      await _loadAll();
    }
  }

  Future<void> _performLoad({
    required String uid,
    required int generation,
  }) async {
    try {
      final results = await Future.wait([
        _db.collection('users').doc(uid).collection('history').get(),
        _db.collection('users').doc(uid).collection('itineraries').get(),
        _db.collection('users').doc(uid).collection('favourites').get(),
      ]);

      if (!_canCommit(uid: uid, generation: generation)) {
        if (kDebugMode) {
          print(
            '🚫 UserActivityDataService: discarded obsolete load '
            'for $uid (generation=$generation)',
          );
        }
        return;
      }

      final historyDocs = results[0].docs
          .map((doc) => ActivityDoc(doc.id, doc.data()))
          .toList();
      final itineraryDocs = results[1].docs
          .map((doc) => ActivityDoc(doc.id, doc.data()))
          .toList();
      final favouriteDocs = results[2].docs
          .map((doc) => ActivityDoc(doc.id, doc.data()))
          .toList();

      if (!_canCommit(uid: uid, generation: generation)) return;

      _historyDocs = historyDocs;
      _itineraryDocs = itineraryDocs;
      _favouriteDocs = favouriteDocs;
      _cachedUid = uid;
      _cachedAt = DateTime.now();

      if (kDebugMode) {
        print(
          '🌐 UserActivityDataService: fresh read for $uid '
          '(history: ${historyDocs.length}, '
          'itineraries: ${itineraryDocs.length}, '
          'favourites: ${favouriteDocs.length}, '
          'generation: $generation)',
        );
      }
    } catch (error) {
      // Errors from an obsolete request/account must not affect the active
      // account or fail a caller that is about to retry the current generation.
      if (!_canCommit(uid: uid, generation: generation)) return;

      if (kDebugMode) {
        print('❌ UserActivityDataService load failed: $error');
      }
      rethrow;
    }
  }

  bool _canCommit({
    required String uid,
    required int generation,
  }) =>
      _uid == uid &&
      _sessionUid == uid &&
      _cacheGeneration == generation;

  Future<List<ActivityDoc>> getHistoryDocs({
    bool forceRefresh = false,
  }) async {
    final requestedUid = _uid;
    await _loadAll(forceRefresh: forceRefresh);

    if (_uid != requestedUid) return const <ActivityDoc>[];
    return List<ActivityDoc>.unmodifiable(
      _historyDocs ?? const <ActivityDoc>[],
    );
  }

  Future<List<ActivityDoc>> getItineraryDocs({
    bool forceRefresh = false,
  }) async {
    final requestedUid = _uid;
    await _loadAll(forceRefresh: forceRefresh);

    if (_uid != requestedUid) return const <ActivityDoc>[];
    return List<ActivityDoc>.unmodifiable(
      _itineraryDocs ?? const <ActivityDoc>[],
    );
  }

  Future<List<ActivityDoc>> getFavouriteDocs({
    bool forceRefresh = false,
  }) async {
    final requestedUid = _uid;
    await _loadAll(forceRefresh: forceRefresh);

    if (_uid != requestedUid) return const <ActivityDoc>[];
    return List<ActivityDoc>.unmodifiable(
      _favouriteDocs ?? const <ActivityDoc>[],
    );
  }

  Future<({
    List<ActivityDoc> history,
    List<ActivityDoc> itineraries,
    List<ActivityDoc> favourites,
  })> getAll({
    bool forceRefresh = false,
  }) async {
    final requestedUid = _uid;
    await _loadAll(forceRefresh: forceRefresh);

    if (_uid != requestedUid) {
      return (
        history: const <ActivityDoc>[],
        itineraries: const <ActivityDoc>[],
        favourites: const <ActivityDoc>[],
      );
    }

    return (
      history: List<ActivityDoc>.unmodifiable(
        _historyDocs ?? const <ActivityDoc>[],
      ),
      itineraries: List<ActivityDoc>.unmodifiable(
        _itineraryDocs ?? const <ActivityDoc>[],
      ),
      favourites: List<ActivityDoc>.unmodifiable(
        _favouriteDocs ?? const <ActivityDoc>[],
      ),
    );
  }
}
