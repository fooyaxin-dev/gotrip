// services/location_service.dart
import 'dart:async';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import '../modules/itinerary/itineraryModel.dart';

enum LocationStatus {
  success,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
}

// Emitted when user arrives near a place
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

class LocationService {
  LocationService._privateConstructor();
  static final LocationService instance =
      LocationService._privateConstructor();

  Position? currentPosition;
  StreamSubscription<Position>? _positionStream;

  double? get currentLat => currentPosition?.latitude;
  double? get currentLng => currentPosition?.longitude;

  // ─────────────────────────────────────────────
  // Proximity tracking
  // ─────────────────────────────────────────────

  // Radius in metres — same feeling as Waze
  static const double _arrivalRadiusMetres = 100;

  // Internal controller — page listens to this
  final StreamController<PlaceArrivalEvent> _arrivalController =
      StreamController<PlaceArrivalEvent>.broadcast();

  Stream<PlaceArrivalEvent> get arrivalStream => _arrivalController.stream;

  // Tracks which placeIds we've already fired so we don't spam the user
  final Set<String> _alreadyArrived = {};

  // The places we're currently watching (unvisited only)
  List<_WatchedPlace> _watchedPlaces = [];

  // Call this from ItineraryDetailPage when the itinerary changes
  void watchItinerary(ItineraryModel itinerary) {
    _watchedPlaces = [];
    _alreadyArrived.clear();

    for (int d = 0; d < itinerary.days.length; d++) {
      final day = itinerary.days[d];
      for (int p = 0; p < day.places.length; p++) {
        final place = day.places[p];
        if (!place.isVisited && place.lat != null && place.lng != null) {
          _watchedPlaces.add(_WatchedPlace(
            placeId:    place.placeId,
            placeName:  place.name,
            lat:        place.lat!,
            lng:        place.lng!,
            dayIndex:   d,
            placeIndex: p,
          ));
        }
      }
    }
  }

  // Remove a place from watch list once confirmed visited
  void markArrived(String placeId) {
    _alreadyArrived.add(placeId);
    _watchedPlaces.removeWhere((w) => w.placeId == placeId);
  }

  // ─────────────────────────────────────────────
  // Init & stream
  // ─────────────────────────────────────────────

  Future<LocationStatus> initLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return LocationStatus.serviceDisabled;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return LocationStatus.permissionDenied;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationStatus.permissionDeniedForever;
    }

    currentPosition = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 10, // fire every 10m movement
      ),
    ).listen((Position pos) {
      currentPosition = pos;
      _checkProximity(pos);
    });

    return LocationStatus.success;
  }

  // ─────────────────────────────────────────────
  // Proximity check — called on every GPS update
  // ─────────────────────────────────────────────

  void _checkProximity(Position pos) {
    for (final watched in _watchedPlaces) {
      if (_alreadyArrived.contains(watched.placeId)) continue;

      final dist = _distanceMetres(
        pos.latitude, pos.longitude,
        watched.lat,  watched.lng,
      );

      if (dist <= _arrivalRadiusMetres) {
        _alreadyArrived.add(watched.placeId); // prevent re-firing
        _arrivalController.add(PlaceArrivalEvent(
          placeId:    watched.placeId,
          placeName:  watched.placeName,
          dayIndex:   watched.dayIndex,
          placeIndex: watched.placeIndex,
        ));
      }
    }
  }

  // Haversine formula — accurate enough for short distances
  double _distanceMetres(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0; // Earth radius in metres
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) *
            sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _rad(double deg) => deg * pi / 180;

  // ─────────────────────────────────────────────

  void dispose() {
    _positionStream?.cancel();
    _arrivalController.close();
  }
}

// Internal helper class
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