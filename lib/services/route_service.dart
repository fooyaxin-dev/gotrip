// services/route_service.dart
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'api_Keys.dart';

enum TravelMode { walk, drive, motor }

String travelModeToString(TravelMode mode) {
  switch (mode) {
    case TravelMode.walk:  return 'walk';
    case TravelMode.motor: return 'motor';
    case TravelMode.drive: return 'drive';
  }
}

// ── 全 app 统一的 "travel mode → 搜索半径" ─────────────────────
// Home（For You 过滤）、Nearby 实际 fetch、Itinerary 生成，
// 全部从这里拿数字，不要各自维护一份。
int radiusForTravelModeString(String mode) {
  switch (mode) {
    case 'walk':  return 2000;
    case 'motor': return 8000;
    case 'drive': return 12000;   // 🔧 20000 → 12000（原本写的是 15000，文案是 20000，现在统一成 12000）
    case 'both':  return 12000;   // 🔧 both = drive，同一个值
    default:      return 8000;
  }
}

int radiusForTravelMode(TravelMode mode) =>
    radiusForTravelModeString(travelModeToString(mode));
    

TravelMode travelModeFromString(String s) {
  switch (s) {
    case 'motor': return TravelMode.motor;
    case 'drive': return TravelMode.drive;
    case 'both':  return TravelMode.drive;   // 🆕
    case 'walk':
    default:      return TravelMode.walk;
  }
}


// Data models

class NavStep {
  final String instruction;
  final String maneuver; 
  final double distanceMeters;
  final int durationSeconds;
  final LatLng startLocation;
  final LatLng endLocation;
  final List<LatLng> polylinePoints; 

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

/// One cell of a real-world distance/duration matrix returned by
/// computeRouteMatrix — the real-road equivalent of a straight-line
/// Haversine lookup between `origins[originIndex]` and
/// `destinations[destinationIndex]`.
class RouteMatrixElement {
  final int originIndex;
  final int destinationIndex;
  final double distanceMeters;
  final int durationSeconds;
  final bool isValid; // false if Google couldn't find a route for this pair

  const RouteMatrixElement({
    required this.originIndex,
    required this.destinationIndex,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.isValid,
  });
}

// RouteService — single source of truth

class RouteService {
  RouteService._(); 
  static final RouteService instance = RouteService._();

  // Move key to --dart-define=GOOGLE_MAPS_KEY=xxx at build time.
  // Falls back to the literal string only for development.
  static const String _apiKey =
      String.fromEnvironment('GOOGLE_MAPS_KEY', defaultValue: ApiKeys.googleMaps);

  static const String _routesUrl =
      'https://routes.googleapis.com/directions/v2:computeRoutes';

  static const String _routeMatrixUrl =
      'https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix';

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
        'routes.legs.steps.polyline.encodedPolyline',
        'routes.polyline.encodedPolyline',
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
          instruction:     _sanitizeInstruction(
                       nav['instructions'] as String? ?? 'Continue'),
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

  /// Real-world distance/duration matrix between every `origins[i]` and
  /// every `destinations[j]` in a single API call — this is what
  /// computeRouteMatrix is for, and it's the right tool for "what order
  /// should I visit these stops in", since it gives you actual road
  /// distances instead of straight-line Haversine estimates for every
  /// pair at once (vs. calling fetchRouteSummary N² times).
  ///
  /// Google bills this per element (origins × destinations), and caps a
  /// single request at 100 elements — comfortably more than a single
  /// day's stop list will ever need.
  Future<List<RouteMatrixElement>> fetchRouteMatrix({
    required List<LatLng> origins,
    required List<LatLng> destinations,
    required TravelMode mode,
  }) async {
    if (origins.isEmpty || destinations.isEmpty) return [];

    final body = jsonEncode({
      'origins': origins
          .map((o) => {
                'waypoint': {
                  'location': {
                    'latLng': {
                      'latitude':  o.latitude,
                      'longitude': o.longitude,
                    }
                  }
                }
              })
          .toList(),
      'destinations': destinations
          .map((d) => {
                'waypoint': {
                  'location': {
                    'latLng': {
                      'latitude':  d.latitude,
                      'longitude': d.longitude,
                    }
                  }
                }
              })
          .toList(),
      'travelMode': _modeString(mode),
      if (mode != TravelMode.walk) 'routingPreference': 'TRAFFIC_AWARE',
    });

    final resp = await http.post(
      Uri.parse(_routeMatrixUrl),
      headers: {
        'Content-Type':     'application/json',
        'X-Goog-Api-Key':   _apiKey,
        'X-Goog-FieldMask':
            'originIndex,destinationIndex,distanceMeters,duration,condition',
      },
      body: body,
    );

    if (resp.statusCode != 200) {
      throw Exception('Route Matrix API HTTP ${resp.statusCode}: ${resp.body}');
    }

    // computeRouteMatrix is a server-streaming method; over plain REST it
    // comes back as a JSON array of matrix elements rather than nested
    // under a "routes" key like computeRoutes does.
    final data = json.decode(resp.body) as List;

    return data.map((raw) {
      final el = raw as Map<String, dynamic>;
      final condition = el['condition'] as String? ?? 'ROUTE_EXISTS';
      return RouteMatrixElement(
        originIndex:      (el['originIndex']      as num?)?.toInt() ?? 0,
        destinationIndex: (el['destinationIndex'] as num?)?.toInt() ?? 0,
        distanceMeters:   (el['distanceMeters']   as num?)?.toDouble() ?? 0,
        durationSeconds:  _parseSecs(el['duration'] as String? ?? '0s'),
        isValid:          condition == 'ROUTE_EXISTS',
      );
    }).toList();
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

  String _sanitizeInstruction(String instruction) {
      var text = instruction.replaceAll(RegExp(r'<[^>]*>'), '');
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      text = text.replaceFirst(RegExp(r'^Head\s+\w+\s+'), 'Go ');
      text = text.replaceFirst(
          'Your destination is on the left', 'Destination on the left');
      text = text.replaceFirst(
          'Your destination is on the right', 'Destination on the right');
      return text;
    }
    
    

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