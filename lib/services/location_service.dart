import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/itineraryModel.dart';
import 'arrival_policy.dart';

enum LocationStatus {
  success,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
}

class PlaceArrivalEvent {
  final String placeId;
  final String placeName;
  final int dayIndex;
  final int placeIndex;

  PlaceArrivalEvent({
    required this.placeId,
    required this.placeName,
    required this.dayIndex,
    required this.placeIndex,
  });
}

class LocationService extends ChangeNotifier {
  LocationService._privateConstructor();
  static final LocationService instance = LocationService._privateConstructor();

  Position? currentPosition;
  StreamSubscription<Position>? _positionStream;

  // 🆕 引用计数——多个页面可以同时"申请"持续追踪，
  // 只有当所有申请者都释放（计数归零）才真正停止 GPS 流。
  // 这样 Home tab 和签到页同时打开也不会互相把对方的追踪关掉。
  int _watcherCount = 0;
  bool get isTracking => _positionStream != null;

  double? get currentLat => currentPosition?.latitude;
  double? get currentLng => currentPosition?.longitude;

  /// Pure production check to verify if a cached Position is fresh and valid.
  static bool isPositionFresh(
    Position? pos, {
    Duration maxAge = const Duration(seconds: 10),
    DateTime? now,
  }) {
    if (pos == null) return false;
    if (!pos.latitude.isFinite || !pos.longitude.isFinite) return false;
    if (pos.latitude == 0.0 && pos.longitude == 0.0) return false;
    final currentTime =
        now ?? instance.testNowProvider?.call() ?? DateTime.now();
    final age = currentTime.difference(pos.timestamp);
    return age >= Duration.zero && age <= maxAge;
  }

  // ── Significant move detection ──
  double? _lastFetchLat;
  double? _lastFetchLng;
  static const double _refetchThresholdMetres = 3000; // 3km

  bool _isMovementRefreshPending = false;
  bool get isMovementRefreshPending => _isMovementRefreshPending;
  double? get baselineLat => _lastFetchLat;
  double? get baselineLng => _lastFetchLng;

  @visibleForTesting
  DateTime Function()? testNowProvider;

  @visibleForTesting
  int get watcherCount => _watcherCount;

  @visibleForTesting
  int get watchedPlacesCount => _watchedPlaces.length;

  @visibleForTesting
  bool isPlaceArrived(String placeId) => _alreadyArrived.contains(placeId);

  @visibleForTesting
  int getConsecutiveArrivalFixes(String placeId) {
    for (final w in _watchedPlaces) {
      if (w.placeId == placeId) return w.consecutiveArrivalFixes;
    }
    return 0;
  }

  @visibleForTesting
  Future<Position> Function(
      {LocationAccuracy desiredAccuracy,
      Duration? timeLimit})? testPositionProvider;

  @visibleForTesting
  Future<bool> Function()? testServiceEnabledChecker;

  @visibleForTesting
  Future<LocationPermission> Function()? testPermissionChecker;

  @visibleForTesting
  Future<LocationPermission> Function()? testPermissionRequester;

  @visibleForTesting
  Stream<Position>? testPositionStream;

  @visibleForTesting
  void simulatePositionChange(Position newPos) {
    currentPosition = newPos;
    _checkProximity(newPos);
    _checkSignificantMove(newPos);
  }

  @visibleForTesting
  void resetForTesting() {
    _positionStream?.cancel();
    _positionStream = null;
    _watcherCount = 0;
    currentPosition = null;
    _lastFetchLat = null;
    _lastFetchLng = null;
    _isMovementRefreshPending = false;
    _watchedPlaces.clear();
    _alreadyArrived.clear();
    _watchedItineraryId = null;
    testPositionProvider = null;
    testServiceEnabledChecker = null;
    testPermissionChecker = null;
    testPermissionRequester = null;
    testPositionStream = null;
    testNowProvider = null;
  }

  /// Evaluates the current [currentPosition] against active itinerary watch places.
  ///
  /// Does not expose private mutable collections.
  void evaluateCurrentPositionProximity() {
    final pos = currentPosition;
    if (pos != null) {
      _checkProximity(pos);
    }
  }

  /// Updates movement baseline coordinates and clears pending refresh flag.
  /// Called by MainPage and RealTimeDetectPage only after nearby places have been
  /// successfully loaded for lat/lng.
  void updateMovementBaseline(double lat, double lng) {
    _lastFetchLat = lat;
    _lastFetchLng = lng;
    _isMovementRefreshPending = false;
  }

  /// Releases the pending movement refresh state without advancing the baseline.
  /// Called when a nearby-place reload fails, so that the location refresh can
  /// be retried without requiring the user to move another 3 km.
  void releaseMovementPending() {
    _isMovementRefreshPending = false;
  }

  // ── Proximity tracking ──
  static double get arrivalRadiusMetres => ArrivalPolicy.arrivalRadiusMetres;

  final StreamController<PlaceArrivalEvent> _arrivalController =
      StreamController<PlaceArrivalEvent>.broadcast();
  Stream<PlaceArrivalEvent> get arrivalStream => _arrivalController.stream;

  final Set<String> _alreadyArrived = {};
  List<_WatchedPlace> _watchedPlaces = [];
  String? _watchedItineraryId;

  /// Rebuilds the proximity watch list and returns whether continuous GPS is
  /// actually needed for today's itinerary day.
  bool watchItinerary(ItineraryModel itinerary) {
    _watchedPlaces = [];

    // Only clear already-arrived set when a different itinerary is being
    // watched. Clearing unconditionally caused the same arrival dialog to
    // appear again whenever _refreshItineraryTracking() was re-called (e.g.
    // after a UI rebuild or after closing a dialog).
    if (_watchedItineraryId != itinerary.id) {
      _watchedItineraryId = itinerary.id;
      _alreadyArrived.clear();
    }

    // Only today's scheduled day may trigger proximity arrivals. Watching all
    // itinerary days allowed a Day 2/Day 3 place to trigger while travelling
    // on Day 1. Future and already-finished itineraries therefore watch none.
    final now = testNowProvider?.call() ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final activeDayIndex = itinerary.days.indexWhere((day) {
      final parsed = DateTime.tryParse(day.date);
      if (parsed == null) return false;
      final scheduledDate = DateTime(parsed.year, parsed.month, parsed.day);
      return scheduledDate == today;
    });

    if (activeDayIndex == -1) {
      debugPrint(
        '📍 Arrival watch inactive: itinerary has no day scheduled for today.',
      );
      return false;
    }

    final activeDay = itinerary.days[activeDayIndex];
    for (int p = 0; p < activeDay.places.length; p++) {
      final place = activeDay.places[p];
      if (!place.isVisited && place.lat != null && place.lng != null) {
        _watchedPlaces.add(_WatchedPlace(
          placeId: place.placeId,
          placeName: place.name,
          lat: place.lat!,
          lng: place.lng!,
          dayIndex: activeDayIndex,
          placeIndex: p,
        ));
      }
    }

    debugPrint(
      '📍 Arrival watch active for Day ${activeDay.dayNumber}: '
      '${_watchedPlaces.length} unvisited place(s).',
    );

    return _watchedPlaces.isNotEmpty;
  }

  void pauseItineraryProximity() {
    // Keep the shared GPS stream running for other modules,
    // but temporarily stop itinerary arrival detection.
    _watchedPlaces = [];
  }

  void markArrived(String placeId) {
    _alreadyArrived.add(placeId);
    _watchedPlaces.removeWhere((w) => w.placeId == placeId);
  }

  void rearmArrival(String placeId) {
    _alreadyArrived.remove(placeId);
    for (final w in _watchedPlaces) {
      if (w.placeId == placeId) {
        w.consecutiveArrivalFixes = 0;
      }
    }
  }

  // ─────────────────────────────────────────────
  // Init & Refresh — 显式 GPS 刷新
  // ─────────────────────────────────────────────

  Future<LocationStatus> initLocation({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return refreshCurrentLocation(timeout: timeout);
  }

  /// Explicitly requests a fresh GPS fix from the hardware/system.
  /// Never uses cached or last-known positions.
  /// Does not destroy existing [currentPosition] if acquisition fails.
  Future<LocationStatus> refreshCurrentLocation({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final serviceChecker =
        testServiceEnabledChecker ?? Geolocator.isLocationServiceEnabled;
    bool serviceEnabled = await serviceChecker();
    if (!serviceEnabled) return LocationStatus.serviceDisabled;

    final permChecker = testPermissionChecker ?? Geolocator.checkPermission;
    LocationPermission permission = await permChecker();
    if (permission == LocationPermission.denied) {
      final permRequester =
          testPermissionRequester ?? Geolocator.requestPermission;
      permission = await permRequester();
      if (permission == LocationPermission.denied) {
        return LocationStatus.permissionDenied;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationStatus.permissionDeniedForever;
    }

    try {
      final posProvider = testPositionProvider;
      final Position freshPos;
      if (posProvider != null) {
        freshPos = await posProvider(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: timeout,
        );
      } else {
        freshPos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: timeout,
        );
      }

      currentPosition = freshPos;
      _checkProximity(freshPos);
      return LocationStatus.success;
    } catch (e) {
      debugPrint('📍 refreshCurrentLocation failed: $e');
      return LocationStatus.serviceDisabled;
    }
  }

  // ─────────────────────────────────────────────
  // 🆕 引用计数式追踪控制
  //
  // 谁需要持续更新的位置（Home tab 的"移动提示"、行程签到页的
  // 到达检测），就调用一次 startTracking()；不再需要时调用
  // stopTracking()。多方同时申请时共享同一条 GPS 订阅，只有当
  // 所有申请者都释放后才真正关闭。
  // ─────────────────────────────────────────────

  void startTracking() {
    _watcherCount++;
    if (_positionStream != null) return; // 已经在跑，不用重复订阅

    final stream = testPositionStream ??
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        );

    _positionStream = stream.listen(
      (Position pos) {
        currentPosition = pos;
        _checkProximity(pos);
        _checkSignificantMove(pos);
      },
      onError: (err) {
        debugPrint('📍 Location stream error: $err');
      },
      cancelOnError: false,
    );
  }

  void stopTracking() {
    if (_watcherCount <= 0) return;
    _watcherCount--;
    if (_watcherCount <= 0) {
      _watcherCount = 0;
      _positionStream?.cancel();
      _positionStream = null;
    }
  }

  // ─────────────────────────────────────────────
  // Significant move → notify all listeners
  // ─────────────────────────────────────────────

  void _checkSignificantMove(Position pos) {
    if (_lastFetchLat == null || _lastFetchLng == null) return;
    if (_isMovementRefreshPending) return;

    final dist = _distanceMetres(
      _lastFetchLat!,
      _lastFetchLng!,
      pos.latitude,
      pos.longitude,
    );

    if (dist >= _refetchThresholdMetres - 0.001) {
      debugPrint(
          '📍 Moved ${dist.toStringAsFixed(0)}m — notifying all listeners');
      _isMovementRefreshPending = true;
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────
  // Proximity check
  // ─────────────────────────────────────────────

  void _checkProximity(Position pos) {
    final accuracy = pos.accuracy;
    for (final watched in _watchedPlaces) {
      if (_alreadyArrived.contains(watched.placeId)) continue;

      final dist = _distanceMetres(
        pos.latitude,
        pos.longitude,
        watched.lat,
        watched.lng,
      );

      final isQualifying = ArrivalPolicy.isQualifyingFix(
        distanceMetres: dist,
        accuracyMetres: accuracy,
      );

      if (isQualifying) {
        watched.consecutiveArrivalFixes++;
        if (watched.consecutiveArrivalFixes >=
            ArrivalPolicy.requiredConsecutiveFixes) {
          _alreadyArrived.add(watched.placeId);
          watched.consecutiveArrivalFixes = 0;
          _arrivalController.add(PlaceArrivalEvent(
            placeId: watched.placeId,
            placeName: watched.placeName,
            dayIndex: watched.dayIndex,
            placeIndex: watched.placeIndex,
          ));
        }
      } else {
        watched.consecutiveArrivalFixes = 0;
      }
    }
  }

  double _distanceMetres(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _rad(double deg) => deg * pi / 180;

  @override
  void dispose() {
    _positionStream?.cancel();
    _arrivalController.close();
    super.dispose();
  }
}

class _WatchedPlace {
  final String placeId;
  final String placeName;
  final double lat;
  final double lng;
  final int dayIndex;
  final int placeIndex;
  int consecutiveArrivalFixes = 0;

  _WatchedPlace({
    required this.placeId,
    required this.placeName,
    required this.lat,
    required this.lng,
    required this.dayIndex,
    required this.placeIndex,
  });
}
