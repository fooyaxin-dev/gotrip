// services/route_service.dart
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

enum TravelMode { walk, drive, motor }

// ─────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────

class NavStep {
  final String instruction;
  final String maneuver;
  final double distanceMeters;
  final int durationSeconds;
  final LatLng startLocation;
  final LatLng endLocation;
  final List<LatLng> polylinePoints; // ← per-step polyline for accurate snap

  const NavStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.startLocation,
    required this.endLocation,
    required this.polylinePoints,
  });
}

class RouteResult {
  final List<LatLng> polylinePoints;   // full route polyline
  final List<NavStep> steps;
  final double distanceMeters;
  final int durationSeconds;
  final LatLngBounds bounds;
  final int? walkDurationSeconds; 

  const RouteResult({
    required this.polylinePoints,
    required this.steps,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.bounds,
    this.walkDurationSeconds,
  });
}

class RouteSummary {
  final double distanceMeters;
  final int durationSeconds;
  final List<LatLng> polylinePoints;
  final LatLngBounds bounds;

  const RouteSummary({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polylinePoints,
    required this.bounds,
  });
}

// ─────────────────────────────────────────────
// RouteService — single source of truth
// ─────────────────────────────────────────────

class RouteService {
  RouteService._(); 
  static final RouteService instance = RouteService._();

  // Move key to --dart-define=GOOGLE_MAPS_KEY=xxx at build time.
  // Falls back to the literal string only for development.
  static const String _apiKey =
      String.fromEnvironment('GOOGLE_MAPS_KEY', defaultValue: 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc');

  static const String _routesUrl =
      'https://routes.googleapis.com/directions/v2:computeRoutes';

  TravelMode currentTravelMode = TravelMode.drive;

  // ── Public API ─────────────────────────────

  /// Full navigation route — includes per-step polylines for accurate snap.
  Future<RouteResult> fetchNavigationRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    required TravelMode mode,
  }) async {
    final resp = await _post(
      fromLat: fromLat, fromLng: fromLng,
      toLat: toLat,     toLng: toLng,
      mode: mode,
      fieldMask: [
        'routes.duration',
        'routes.distanceMeters',
        'routes.viewport',
        'routes.legs.steps.navigationInstruction',
        'routes.legs.steps.distanceMeters',
        'routes.legs.steps.staticDuration',
        'routes.legs.steps.startLocation',
        'routes.legs.steps.endLocation',
        'routes.legs.steps.polyline',       // ← per-step polyline
        'routes.polyline.encodedPolyline',  // ← full route polyline
      ],
    );

    final route = _firstRoute(resp);
    final legs   = route['legs'] as List;

    final allPts  = <LatLng>[];
    final steps   = <NavStep>[];

    for (final leg in legs) {
      for (final s in (leg['steps'] as List)) {
        final stepPts = _decodePolyline(
            s['polyline']?['encodedPolyline'] as String? ?? '');

        // Stitch into full polyline (skip first point of each step to avoid dupe)
        if (allPts.isNotEmpty && stepPts.isNotEmpty) {
          allPts.addAll(stepPts.skip(1));
        } else {
          allPts.addAll(stepPts);
        }

        final nav = s['navigationInstruction'] as Map<String, dynamic>? ?? {};
        steps.add(NavStep(
          instruction:     nav['instructions']   as String? ?? 'Continue',
          maneuver:        (nav['maneuver']       as String? ?? '').toLowerCase(),
          distanceMeters:  (s['distanceMeters']  as num?    ?? 0).toDouble(),
          durationSeconds: _parseSecs(s['staticDuration'] as String? ?? '0s'),
          startLocation:   _latLng(s['startLocation']),
          endLocation:     _latLng(s['endLocation']),
          polylinePoints:  stepPts,
        ));
      }
    }

    return RouteResult(
      polylinePoints:  allPts,
      steps:           steps,
      distanceMeters:  (route['distanceMeters'] as num).toDouble(),
      durationSeconds: _parseSecs(route['duration'] as String? ?? '0s'),
      bounds:          _parseBounds(route['viewport']),
    );
  }

  /// Lightweight summary for the preview screen — no step polylines needed.
  Future<RouteSummary> fetchRouteSummary({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    required TravelMode mode,
  }) async {
    final resp = await _post(
      fromLat: fromLat, fromLng: fromLng,
      toLat: toLat,     toLng: toLng,
      mode: mode,
      fieldMask: [
        'routes.duration',
        'routes.distanceMeters',
        'routes.polyline.encodedPolyline',
        'routes.viewport',
      ],
    );

    final route = _firstRoute(resp);
    return RouteSummary(
      distanceMeters:  (route['distanceMeters'] as num).toDouble(),
      durationSeconds: _parseSecs(route['duration'] as String? ?? '0s'),
      polylinePoints:  _decodePolyline(
          route['polyline']['encodedPolyline'] as String),
      bounds:          _parseBounds(route['viewport']),
    );
  }

  // ── Formatting helpers (used by UI) ────────

  String formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String formatDuration(int seconds) {
    if (seconds < 60)  return '$seconds sec';
    final m = seconds ~/ 60;
    if (m < 60) return '$m min';
    final h = m ~/ 60; final r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}min';
  }

  String formatArrivalTime(int durationSeconds) {
    final arrival = DateTime.now().add(Duration(seconds: durationSeconds));
    final h12 = arrival.hour % 12 == 0 ? 12 : arrival.hour % 12;
    final m   = arrival.minute.toString().padLeft(2, '0');
    final p   = arrival.hour >= 12 ? 'PM' : 'AM';
    return '$h12:$m $p';
  }

  // ── Private helpers ────────────────────────

  String _modeString(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk:  return 'WALK';
      case TravelMode.drive: return 'DRIVE';
      case TravelMode.motor: return 'TWO_WHEELER';
    }
  }

  Future<Map<String, dynamic>> _post({
    required double fromLat, required double fromLng,
    required double toLat,   required double toLng,
    required TravelMode mode,
    required List<String> fieldMask,
  }) async {
    final body = jsonEncode({
      'origin':      {'location': {'latLng': {'latitude': fromLat, 'longitude': fromLng}}},
      'destination': {'location': {'latLng': {'latitude': toLat,   'longitude': toLng}}},
      'travelMode':  _modeString(mode),
      'routingPreference': mode == TravelMode.walk
          ? 'ROUTING_PREFERENCE_UNSPECIFIED' : 'TRAFFIC_AWARE',
      'computeAlternativeRoutes': false,
      if (mode != TravelMode.walk)
        'routeModifiers': {'avoidTolls': false, 'avoidHighways': false},
      'languageCode': 'en-US',
      'units': 'METRIC',
    });

    final resp = await http.post(
      Uri.parse(_routesUrl),
      headers: {
        'Content-Type':     'application/json',
        'X-Goog-Api-Key':   _apiKey,
        'X-Goog-FieldMask': fieldMask.join(','),
      },
      body: body,
    );

    if (resp.statusCode != 200) {
      throw Exception('Routes API HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data   = json.decode(resp.body) as Map<String, dynamic>;
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) {
      throw Exception('No routes returned');
    }
    return data;
  }

  Map<String, dynamic> _firstRoute(Map<String, dynamic> data) =>
      (data['routes'] as List)[0] as Map<String, dynamic>;

  LatLng _latLng(dynamic loc) => LatLng(
    (loc['latLng']['latitude']  as num).toDouble(),
    (loc['latLng']['longitude'] as num).toDouble(),
  );

  LatLngBounds _parseBounds(dynamic vp) => LatLngBounds(
    southwest: LatLng(
      (vp['low']['latitude']   as num).toDouble(),
      (vp['low']['longitude']  as num).toDouble(),
    ),
    northeast: LatLng(
      (vp['high']['latitude']  as num).toDouble(),
      (vp['high']['longitude'] as num).toDouble(),
    ),
  );

  int _parseSecs(String s) =>
      int.tryParse(s.replaceAll('s', '').trim()) ?? 0;

  List<LatLng> _decodePolyline(String encoded) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0; result = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      pts.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return pts;
  }
}