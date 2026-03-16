//它只管列表估算，不管导航精度

// services/route_service.dart
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'placeModal.dart';
import 'location_service.dart';

enum TravelMode { walk, drive, motor }

class RouteResult {
  final double distanceMeters;
  final int durationSeconds;
  final List<dynamic> polylinePoints;
  final dynamic bounds;

  RouteResult({ 
    required this.distanceMeters,
    required this.durationSeconds,
    this.polylinePoints = const [],
    this.bounds,
  });
}

class RouteService {
  static final RouteService instance = RouteService._();
  RouteService._();

  TravelMode currentTravelMode = TravelMode.walk;

  String formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String formatDuration(int seconds) {
    if (seconds < 60) return '< 1 min';
    return '${(seconds ~/ 60)} min';
  }
}