// services/route_service.dart
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'placeModal.dart';
import 'location_service.dart';

enum TravelMode { walk, drive, motor }

class RouteResult {
  final List<LatLng> polylinePoints;
  final LatLngBounds? bounds;
  final double distanceMeters;
  final int durationSeconds;

  RouteResult({
    required this.polylinePoints,
    this.bounds,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

class RouteService {
  static final RouteService instance = RouteService._();
  RouteService._();

  TravelMode currentTravelMode = TravelMode.walk;

  /// 🚶 获取不同交通方式的速度 (m/s)
  double getSpeedMeterPerSecond(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk:
        return 1.4;   // 走路 ~5 km/h
      case TravelMode.motor:
        return 6.0;   // 摩托/自行车 ~20 km/h
      case TravelMode.drive:
        return 12.0;  // 开车 ~43 km/h
    }
  }

  /// 📍 计算两点之间的直线路线（快速估算）
  RouteResult calculateStraightRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    TravelMode? mode,
  }) {
    final travelMode = mode ?? currentTravelMode;
    
    final distanceMeters = Geolocator.distanceBetween(
      startLat,
      startLng,
      endLat,
      endLng,
    );

    final speed = getSpeedMeterPerSecond(travelMode);
    final durationSeconds = (distanceMeters / speed).round();

    return RouteResult(
      polylinePoints: [],
      bounds: LatLngBounds(
        southwest: LatLng(
          startLat < endLat ? startLat : endLat,
          startLng < endLng ? startLng : endLng,
        ),
        northeast: LatLng(
          startLat > endLat ? startLat : endLat,
          startLng > endLng ? startLng : endLng,
        ),
      ),
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
    );
  }

  /// 📍 为一批地点计算路线（用于列表展示）
  Map<String, RouteResult> calculateRoutesForPlaces(
    List<PlaceModel> places, {
    TravelMode? mode,
  }) {
    final pos = LocationService.instance.currentPosition;
    if (pos == null) return {};

    final Map<String, RouteResult> results = {};
    
    for (final place in places) {
      if (place.lat != null && place.lng != null) {
        results[place.id] = calculateStraightRoute(
          startLat: pos.latitude,
          startLng: pos.longitude,
          endLat: place.lat!,
          endLng: place.lng!,
          mode: mode,
        );
      }
    }

    return results;
  }

  /// 🔄 更新所有路线的交通方式
  Map<String, RouteResult> updateTravelMode(
    Map<String, RouteResult> existingRoutes,
    TravelMode newMode,
  ) {
    currentTravelMode = newMode;
    
    final Map<String, RouteResult> updated = {};
    final speed = getSpeedMeterPerSecond(newMode);

    for (final entry in existingRoutes.entries) {
      final oldRoute = entry.value;
      final newDuration = (oldRoute.distanceMeters / speed).round();
      
      updated[entry.key] = RouteResult(
        polylinePoints: oldRoute.polylinePoints,
        bounds: oldRoute.bounds,
        distanceMeters: oldRoute.distanceMeters,
        durationSeconds: newDuration,
      );
    }

    return updated;
  }

  /// 📊 格式化显示
  String formatDistance(double meters) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String formatDuration(int seconds) {
    return '${(seconds ~/ 60)} min';
  }
}