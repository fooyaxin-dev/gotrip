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

  void markArrived(String placeId) {
    _alreadyArrived.add(placeId);
    _watchedPlaces.removeWhere((w) => w.placeId == placeId);
  }

  // ─────────────────────────────────────────────
  // Init & stream
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

    _positionStream?.cancel();
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

    return LocationStatus.success;
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
      notifyListeners(); // ← 同時通知所有監聽者
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