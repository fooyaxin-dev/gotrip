import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/itineraryModel.dart';

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

  // ── Significant move detection ──
  double? _lastFetchLat;
  double? _lastFetchLng;
  static const double _refetchThresholdMetres = 10000; // 10km

  // ── Proximity tracking ──
  static const double _arrivalRadiusMetres = 50;

  final StreamController<PlaceArrivalEvent> _arrivalController =
      StreamController<PlaceArrivalEvent>.broadcast();
  Stream<PlaceArrivalEvent> get arrivalStream => _arrivalController.stream;

  final Set<String> _alreadyArrived = {};
  List<_WatchedPlace> _watchedPlaces = [];

  void watchItinerary(ItineraryModel itinerary) {
    _watchedPlaces = [];
    _alreadyArrived.clear();

    for (int d = 0; d < itinerary.days.length; d++) {
      final day = itinerary.days[d];
      for (int p = 0; p < day.places.length; p++) {
        final place = day.places[p];
        if (!place.isVisited && place.lat != null && place.lng != null) {
          _watchedPlaces.add(_WatchedPlace(
            placeId: place.placeId,
            placeName: place.name,
            lat: place.lat!,
            lng: place.lng!,
            dayIndex: d,
            placeIndex: p,
          ));
        }
      }
    }
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
  }


  // ─────────────────────────────────────────────
  // Init — 只负责权限检查 + 拿"这一次"的定位快照
  //
  // 🔧 CHANGED: 不再自动开启持续追踪的 GPS 流。之前这里直接
  // Geolocator.getPositionStream(...).listen(...) 起了一条常驻订阅，
  // 导致只要调用过 initLocation() 一次（比如 Home tab 一打开），
  // GPS 就会以 high accuracy 持续跑到 app 被杀掉为止——这也是手机
  // 发热的主因之一。现在持续追踪改成显式的 startTracking()/
  // stopTracking()，由真正需要"实时位置"的页面自己申请。
  // ─────────────────────────────────────────────

  Future<LocationStatus> initLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return LocationStatus.serviceDisabled;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return LocationStatus.permissionDenied;
    }
    if (permission == LocationPermission.deniedForever) return LocationStatus.permissionDeniedForever;

    currentPosition = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    _lastFetchLat = currentPosition?.latitude;
    _lastFetchLng = currentPosition?.longitude;

    return LocationStatus.success;
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

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position pos) {
      currentPosition = pos;
      _checkProximity(pos);
      _checkSignificantMove(pos);
    });
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

    final dist = _distanceMetres(
      _lastFetchLat!, _lastFetchLng!,
      pos.latitude, pos.longitude,
    );

    if (dist >= _refetchThresholdMetres) {
      print('📍 Moved ${dist.toStringAsFixed(0)}m — notifying all listeners');
      _lastFetchLat = pos.latitude;
      _lastFetchLng = pos.longitude;
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────
  // Proximity check
  // ─────────────────────────────────────────────

  void _checkProximity(Position pos) {
    for (final watched in _watchedPlaces) {
      if (_alreadyArrived.contains(watched.placeId)) continue;

      final dist = _distanceMetres(
        pos.latitude, pos.longitude,
        watched.lat, watched.lng,
      );

      if (dist <= _arrivalRadiusMetres) {
        _alreadyArrived.add(watched.placeId);
        _arrivalController.add(PlaceArrivalEvent(
          placeId: watched.placeId,
          placeName: watched.placeName,
          dayIndex: watched.dayIndex,
          placeIndex: watched.placeIndex,
        ));
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

  _WatchedPlace({
    required this.placeId,
    required this.placeName,
    required this.lat,
    required this.lng,
    required this.dayIndex,
    required this.placeIndex,
  });
}