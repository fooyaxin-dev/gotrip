import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/placeModel.dart';
import 'nearbyPlace_service.dart';
import 'route_service.dart';
import 'userPreference_service.dart';
import 'weather_service.dart';

/// Immutable authoritative snapshot representing a single, coherent For You
/// recommendation result for a specific spatial, preference, and temporal context.
class ForYouSnapshot {
  final RecommendationOriginType originType;
  final double lat;
  final double lng;
  final int radiusMeters;
  final int preferenceRevision;
  final int generation;
  final String contextKey;
  final List<PlaceModel> places;
  final Map<String, double> scores;
  final Map<String, RecommendationExplanation> explanations;
  final Map<String, RouteResult> routeResults;
  final DateTime timestamp;

  ForYouSnapshot({
    required this.originType,
    required this.lat,
    required this.lng,
    required this.radiusMeters,
    required this.preferenceRevision,
    required this.generation,
    required this.contextKey,
    required List<PlaceModel> places,
    required Map<String, double> scores,
    required Map<String, RecommendationExplanation> explanations,
    required Map<String, RouteResult> routeResults,
    DateTime? timestamp,
  })  : places = List.unmodifiable(places),
        scores = Map.unmodifiable(scores),
        explanations = Map.unmodifiable(explanations),
        routeResults = Map.unmodifiable(routeResults),
        timestamp = timestamp ?? DateTime.now();

  static String buildContextKey({
    required RecommendationOriginType originType,
    required double lat,
    required double lng,
    required int radiusMeters,
    required int preferenceRevision,
    required int generation,
  }) {
    final loc = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    return '${originType.name}:$loc:$radiusMeters:rev$preferenceRevision:gen$generation';
  }

  bool matchesContext({
    required RecommendationOriginType originType,
    required double lat,
    required double lng,
    required int radiusMeters,
    required int preferenceRevision,
    required int generation,
  }) {
    final locNow = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    final locSelf =
        '${this.lat.toStringAsFixed(3)},${this.lng.toStringAsFixed(3)}';
    return this.originType == originType &&
        locSelf == locNow &&
        this.radiusMeters == radiusMeters &&
        this.preferenceRevision == preferenceRevision &&
        this.generation == generation;
  }
}

/// Production coordinator service that ensures both MainPage and RealTimeDetectPage
/// consume the same authoritative, deterministic, personalised For You result for
/// the same normal user-GPS context.
class ForYouRecommendationService {
  static final ForYouRecommendationService instance =
      ForYouRecommendationService._();

  ForYouRecommendationService._();

  ForYouSnapshot? _userGpsSnapshot;
  ForYouSnapshot? get userGpsSnapshot => _userGpsSnapshot;

  int _currentGeneration = 0;
  int get currentGeneration => _currentGeneration;

  final Map<String, Future<ForYouSnapshot>> _inFlightRequests = {};

  /// Merges Google DISTANCE and POPULARITY candidates, deduplicating strictly by Place ID.
  static List<PlaceModel> combinePools({
    required List<PlaceModel> distancePlaces,
    required List<PlaceModel> popularityPlaces,
  }) {
    final seen = <String>{};
    final combined = <PlaceModel>[];
    for (final p in distancePlaces) {
      if (seen.add(p.id)) combined.add(p);
    }
    for (final p in popularityPlaces) {
      if (seen.add(p.id)) combined.add(p);
    }
    return combined;
  }

  /// Invalidates the normal user-GPS For You snapshot and advances the generation
  /// so that in-flight requests from the older generation cannot overwrite new data.
  void invalidateUserGpsSnapshot() {
    _currentGeneration++;
    _userGpsSnapshot = null;
    debugPrint(
        '♻️ ForYouRecommendationService: invalidated user GPS snapshot (gen=$_currentGeneration)');
  }

  /// Explicitly sets an authoritative snapshot (useful for tests or pre-warming).
  @visibleForTesting
  void setAuthoritativeSnapshot(ForYouSnapshot? snapshot) {
    _userGpsSnapshot = snapshot;
  }

  /// Retrieves or constructs the authoritative For You snapshot.
  ///
  /// The authoritative pipeline:
  /// 1. Awaits both Google DISTANCE and POPULARITY candidate rounds concurrently.
  /// 2. Merges and deduplicates candidate pools by Place ID.
  /// 3. Excludes Geoapify candidates.
  /// 4. Excludes explicitly closed places (isOpenNow == false).
  /// 5. Rejects places without coordinates.
  /// 6. Computes route results with distances.
  /// 7. Filters by travel-mode radius (dist <= radiusMeters) and requirePhoto: true.
  /// 8. Ranks using UserPreferenceService.buildForYouList with deterministic 4-tier tie-breaking.
  /// 9. Publishes an immutable ForYouSnapshot.
  Future<ForYouSnapshot> ensureForYouSnapshot({
    required double lat,
    required double lng,
    required int radiusMeters,
    RecommendationOriginType originType = RecommendationOriginType.gps,
    String? originName,
    WeatherCondition? weather,
    NearbyPlacesService? nearbyService,
    bool forceRefresh = false,
  }) async {
    final prefRevision =
        UserPreferenceService.instance.preferencesChanged.value;
    final generation = _currentGeneration;

    // 1. Cache hit check for normal user-GPS context
    if (!forceRefresh && originType == RecommendationOriginType.gps) {
      final existing = _userGpsSnapshot;
      if (existing != null &&
          existing.matchesContext(
            originType: originType,
            lat: lat,
            lng: lng,
            radiusMeters: radiusMeters,
            preferenceRevision: prefRevision,
            generation: generation,
          )) {
        return existing;
      }
    }

    // 2. In-flight request deduplication
    final contextKey = ForYouSnapshot.buildContextKey(
      originType: originType,
      lat: lat,
      lng: lng,
      radiusMeters: radiusMeters,
      preferenceRevision: prefRevision,
      generation: generation,
    );

    if (_inFlightRequests.containsKey(contextKey)) {
      return _inFlightRequests[contextKey]!;
    }

    final completer = Completer<ForYouSnapshot>();
    _inFlightRequests[contextKey] = completer.future;

    final effectiveNearby = nearbyService ?? NearbyPlacesService.instance;

    () async {
      try {
        // Step 1: Await both candidate rounds before publishing
        final rounds = await Future.wait([
          effectiveNearby.ensureDistanceRound(
            lat: lat,
            lng: lng,
            radius: radiusMeters,
          ),
          effectiveNearby.ensurePopularityRound(
            lat: lat,
            lng: lng,
            radius: radiusMeters,
          ),
        ]);

        final distancePlaces = rounds[0];
        final popularityPlaces = rounds[1];

        // Step 2: Merge & deduplicate by Place ID
        final combined = combinePools(
          distancePlaces: distancePlaces,
          popularityPlaces: popularityPlaces,
        );

        // Step 3 & 4 & 5: Filter candidates
        // - Exclude Geoapify candidates
        // - Exclude explicitly closed places (isOpenNow == false)
        // - Require valid coordinates
        final eligible = combined.where((p) {
          if (p.isGeoapify) return false;
          if (p.isOpenNow == false) return false;
          if (p.lat == null || p.lng == null) return false;
          return true;
        }).toList();

        // Step 6: Compute route results for distance calculation
        final calculatedRoutes = <String, RouteResult>{};
        for (final p in eligible) {
          final dist = Geolocator.distanceBetween(lat, lng, p.lat!, p.lng!);
          calculatedRoutes[p.id] = RouteResult(
            polylinePoints: const [],
            steps: const [],
            bounds: LatLngBounds(
              southwest: LatLng(min(lat, p.lat!), min(lng, p.lng!)),
              northeast: LatLng(max(lat, p.lat!), max(lng, p.lng!)),
            ),
            distanceMeters: dist,
            durationSeconds: (dist / 1.4).round(),
          );
        }

        // Step 7 & 8: Personalised ranking with 4-tier tie-breaking,
        // photo requirement, and travel-mode radius enforcement
        final forYouResult = UserPreferenceService.instance.buildForYouList(
          candidates: eligible,
          routeResults: calculatedRoutes,
          distanceLimitMeters: radiusMeters.toDouble(),
          weather: weather ?? WeatherService.instance.current,
          requirePhoto: true,
          originType: originType,
          originName: originName,
        );

        final snapshot = ForYouSnapshot(
          originType: originType,
          lat: lat,
          lng: lng,
          radiusMeters: radiusMeters,
          preferenceRevision: prefRevision,
          generation: generation,
          contextKey: contextKey,
          places: forYouResult.places,
          scores: forYouResult.scores,
          explanations: forYouResult.explanations,
          routeResults: calculatedRoutes,
        );

        // Step 9: Stale generation, preference revision & isolation check
        // Only normal GPS context updates _userGpsSnapshot, and only if still on the same generation
        // and identical preference revision as current.
        if (originType == RecommendationOriginType.gps &&
            generation == _currentGeneration &&
            prefRevision == UserPreferenceService.instance.preferenceRevision) {
          _userGpsSnapshot = snapshot;
        }

        completer.complete(snapshot);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _inFlightRequests.remove(contextKey);
      }
    }();

    return completer.future;
  }
}
