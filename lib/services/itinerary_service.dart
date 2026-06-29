// services/itinerary_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/itineraryModel.dart';
import '../models/placeModal.dart';
import '../services/placesAPI_service.dart';
import '../services/location_service.dart';
import '../services/userPreference_service.dart';

class ItineraryService {
  static final ItineraryService instance = ItineraryService._();
  ItineraryService._();

  final _db = FirebaseFirestore.instance;
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference? get _col => _uid == null
      ? null
      : _db.collection('users').doc(_uid).collection('itineraries');

  // ─────────────────────────────────────────────
  // Blocked types
  // ─────────────────────────────────────────────

  static const _blockedTypes = {
    'lodging', 'hotel', 'motel', 'guest_house', 'hostel',
    'campground', 'rv_park', 'hospital', 'doctor', 'dentist',
    'pharmacy', 'bank', 'atm', 'finance', 'insurance_agency',
    'gas_station', 'car_repair', 'car_wash', 'car_dealer',
    'laundry', 'storage', 'funeral_home', 'cemetery',
    'police', 'courthouse', 'embassy', 'real_estate_agency',
    'electrician', 'plumber', 'roofing_contractor',
  };

  static const _blockedNameKeywords = [
    'sdn bhd', 'sdn. bhd', 'sdnbhd',
    'network', 'solution', 'solutions',
    'enterprise', 'enterprises',
    'management', 'services', 'trading',
    'holdings', 'group berhad', 'berhad',
    'consultant', 'consultancy',
    'insurance', 'agency', 'agencies',
    'clinic', 'hospital', 'pharmacy',
    'hardware', 'spare part',
  ];

  bool _isBlocked(PlaceModel p) {
    if (p.allTypes.any((t) => _blockedTypes.contains(t))) return true;
    final nameLower = p.name.toLowerCase();
    if (_blockedNameKeywords.any((k) => nameLower.contains(k))) return true;
    return false;
  }

  bool _isSuitableForTravel(PlaceModel p) {
    if (p.photoUrl == null || p.photoUrl!.isEmpty) return false;
    if (_isBlocked(p)) return false;
    final r = p.rating;
    if (r != null && r > 4.95) return false;
    if (r != null && r < 3.5)  return false;
    return true;
  }

  // ─────────────────────────────────────────────
  // Firestore CRUD
  // ─────────────────────────────────────────────

  Future<List<ItineraryModel>> fetchAll() async {
    if (_col == null) return [];
    try {
      final snap = await _col!.orderBy('createdAt', descending: true).get();
      return snap.docs
          .map((d) => ItineraryModel.fromMap(d.id, d.data() as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('❌ fetchAll: $e');
      return [];
    }
  }

  Future<String?> save(ItineraryModel item) async {
    if (_uid == null) {
      print('❌ save: user not logged in');
      return null;
    }
    if (_col == null) return null;
    try {
      if (item.id.isEmpty) {
        final ref = await _col!.add(item.toMap());
        return ref.id;
      } else {
        await _col!.doc(item.id).set(item.toMap());
        return item.id;
      }
    } catch (e) {
      print('❌ save: $e');
      return null;
    }
  }

  Future<void> update(ItineraryModel item) async {
    if (_col == null || item.id.isEmpty) return;
    try {
      await _col!.doc(item.id).update(item.toMap());
    } catch (e) {
      print('❌ update: $e');
    }
  }

  Future<void> delete(String id) async {
    if (_col == null) return;
    try {
      await _col!.doc(id).delete();
    } catch (e) {
      print('❌ delete: $e');
    }
  }

  // ─────────────────────────────────────────────
  // Fetch places for itinerary generation
  // ─────────────────────────────────────────────

  Future<Map<String, List<PlaceModel>>> _fetchPlacesForItinerary({
    required double lat,
    required double lng,
  }) async {
    const types = [
      'restaurant',
      'tourist_attraction',
      'shopping_mall',
      'amusement_park',
      'park',
    ];

    print('🗺️ Fetching itinerary candidates (10km radius)...');
    final stopwatch = Stopwatch()..start();

    final entries = await Future.wait(
      types.map((type) async {
        try {
          final raw = await PlacesApiService.searchNearby(
            lat:            lat,
            lng:            lng,
            types:          [type],
            radius:         10000,
            maxResultCount: 20,
          );

          final places = raw
              .map((p) {
                try {
                  final place = PlaceModel.fromGoogle(p, primary: type);
                  if (place.lat == null || place.lng == null) return null;
                  return place;
                } catch (_) {
                  return null;
                }
              })
              .whereType<PlaceModel>()
              .toList();

          print('  ✅ $type: ${places.length} fetched');
          return MapEntry(type, places);
        } catch (e) {
          print('  ⚠️ $type failed: $e');
          return MapEntry(type, <PlaceModel>[]);
        }
      }),
    );

    stopwatch.stop();
    print('🗺️ Done in ${stopwatch.elapsedMilliseconds}ms');
    return Map.fromEntries(entries);
  }

  // ─────────────────────────────────────────────
  // Build balanced places with recommendation score
  // ─────────────────────────────────────────────

  Future<List<PlaceModel>> _buildBalancedPlaces(
    int totalDays, {
    required double lat,
    required double lng,
  }) async {
    final prefs = UserPreferenceService.instance;

    final perCategory     = (totalDays + 1).clamp(2, 6);
    final restaurantCount = (totalDays * 2 + 1).clamp(3, 10);

    final byType = await _fetchPlacesForItinerary(lat: lat, lng: lng);

    double score(PlaceModel p) => prefs.recommendationScore(
      primaryType:    p.primaryType,
      allTypes:       p.allTypes,
      rating:         p.rating,
      distanceMeters: null,
      priceLevel:     p.priceLevel,
    ).total;

    List<PlaceModel> topByType(String type, int count) {
      final list = (byType[type] ?? [])
          .where(_isSuitableForTravel)
          .toList()
        ..sort((a, b) => score(b).compareTo(score(a)));

      if (list.length < count) {
        final fallback = (byType[type] ?? [])
            .where((p) =>
                p.photoUrl != null &&
                p.photoUrl!.isNotEmpty &&
                !_isBlocked(p) &&
                (p.rating == null || p.rating! >= 3.5))
            .toList()
          ..sort((a, b) => score(b).compareTo(score(a)));
        return fallback.take(count).toList();
      }

      return list.take(count).toList();
    }

    final restaurants   = topByType('restaurant',         restaurantCount);
    final attractions   = topByType('tourist_attraction', perCategory);
    final malls         = topByType('shopping_mall',      perCategory);
    final entertainment = topByType('amusement_park',     perCategory);
    final parks         = topByType('park',               perCategory);

    print('📋 Per category:');
    print('  🍽️  Restaurants: ${restaurants.length}');
    print('  🏛️  Attractions: ${attractions.length}');
    print('  🛍️  Malls: ${malls.length}');
    print('  🎭  Entertainment: ${entertainment.length}');
    print('  🌿  Parks: ${parks.length}');

    final seen   = <String>{};
    final result = <PlaceModel>[];
    void addAll(List<PlaceModel> list) {
      for (final p in list) if (seen.add(p.id)) result.add(p);
    }
    addAll(restaurants);
    addAll(attractions);
    addAll(malls);
    addAll(entertainment);
    addAll(parks);

    print('📍 Total candidates: ${result.length}');
    return result;
  }

  // ─────────────────────────────────────────────
  // Generate — no Gemini, pure algorithm
  // ─────────────────────────────────────────────

  Future<ItineraryModel?> generate({
    required String startDate,
    required int    totalDays,
    required int    placesPerDay,
    required String tripTitle,
    List<String>?   overrideCategories,
    List<String>?   overrideCuisines,
    double?         overrideLat,
    double?         overrideLng,
  }) async {
    try {
      final cuisines = overrideCuisines
          ?? UserPreferenceService.instance.current.cuisines;

      double? lat = overrideLat;
      double? lng = overrideLng;

      if (lat == null || lng == null) {
        final pos = LocationService.instance.currentPosition;
        if (pos == null) {
          print('❌ generate: no location available');
          return null;
        }
        lat = pos.latitude;
        lng = pos.longitude;
      }

      final validPlaces = await _buildBalancedPlaces(
        totalDays,
        lat: lat,
        lng: lng,
      );

      if (validPlaces.isEmpty) {
        print('❌ No valid places found');
        return null;
      }

      final startDt  = DateTime.parse(startDate);
      final dayDates = List.generate(totalDays, (i) {
        final d = startDt.add(Duration(days: i));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      });

      final days = _scheduleItinerary(
        places:       validPlaces,
        totalDays:    totalDays,
        placesPerDay: placesPerDay,
        startDates:   dayDates,
        cuisines:     cuisines,
      );

      if (days == null || days.isEmpty) {
        print('❌ Scheduling failed');
        return null;
      }

      print('✅ Scheduled ${days.length} days');
      for (int i = 0; i < days.length; i++) {
        print('  Day ${i + 1}: ${days[i].places.length} places'
            ' — ${days[i].places.map((p) => p.name).join(', ')}');
      }

      return ItineraryModel(
        id:        '',
        title:     tripTitle,
        startDate: startDate,
        totalDays: totalDays,
        days:      days,
        createdAt: DateTime.now(),
      );
    } catch (e) {
      print('❌ generate: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────
  // Scheduler
  // ─────────────────────────────────────────────

  List<ItineraryDay>? _scheduleItinerary({
    required List<PlaceModel> places,
    required int              totalDays,
    required int              placesPerDay,
    required List<String>     startDates,
    required List<String>     cuisines,
  }) {
    final restaurants = places.where((p) => p.primaryType == 'restaurant').toList();
    final others      = places.where((p) => p.primaryType != 'restaurant').toList();

    final restaurantsPerDay = placesPerDay <= 2 ? 1 : 2;
    final attractionsPerDay = placesPerDay - restaurantsPerDay;

    final clusters = _geoClusters(others, totalDays);

    final usedIds = <String>{};
    final days    = <ItineraryDay>[];

    for (int i = 0; i < totalDays; i++) {
      final clusterPlaces = clusters[i]
          .where((p) => !usedIds.contains(p.id))
          .take(attractionsPerDay)
          .toList();

      final dayCenter = _centroid(
        clusterPlaces.isNotEmpty ? clusterPlaces : others,
      );
      final dayRestaurants = _closestUnused(
        restaurants, dayCenter, restaurantsPerDay, usedIds, cuisines,
      );

      usedIds.addAll(clusterPlaces.map((p) => p.id));
      usedIds.addAll(dayRestaurants.map((p) => p.id));

      final scheduled = _assignTimeSlots(
        clusterPlaces, dayRestaurants, placesPerDay,
      );

      days.add(ItineraryDay(
        dayNumber: i + 1,
        date:      startDates[i],
        places:    scheduled,
      ));
    }

    return days;
  }

  // ─────────────────────────────────────────────
  // Geo clustering — greedy one-pass k-means
  // Groups nearby non-restaurant places into days
  // so each day's stops are geographically close
  // ─────────────────────────────────────────────

  List<List<PlaceModel>> _geoClusters(List<PlaceModel> places, int k) {
    if (places.isEmpty) return List.generate(k, (_) => []);

    // Spread seeds across rating-sorted list so every day gets quality options
    final sorted = [...places]
      ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));

    final seeds = <PlaceModel>[];
    final step  = (sorted.length / k).ceil().clamp(1, sorted.length);
    for (int i = 0; i < k; i++) {
      seeds.add(sorted[(i * step).clamp(0, sorted.length - 1)]);
    }

    final clusters = List.generate(k, (_) => <PlaceModel>[]);

    for (final p in places) {
      if (p.lat == null || p.lng == null) continue;
      int    bestIdx  = 0;
      double bestDist = double.infinity;
      for (int i = 0; i < seeds.length; i++) {
        final d = _distSq(p.lat!, p.lng!, seeds[i].lat!, seeds[i].lng!);
        if (d < bestDist) { bestDist = d; bestIdx = i; }
      }
      clusters[bestIdx].add(p);
    }

    // Best-rated places come first within each cluster
    for (final c in clusters) {
      c.sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
    }

    return clusters;
  }

  // ─────────────────────────────────────────────
  // Pick restaurants closest to the day's centroid
  // Cuisine match takes priority over distance
  // ─────────────────────────────────────────────

  List<PlaceModel> _closestUnused(
    List<PlaceModel>           pool,
    ({double lat, double lng}) center,
    int                        count,
    Set<String>                used,
    List<String>               cuisines,
  ) {
    final available = pool
        .where((p) => !used.contains(p.id) && p.lat != null && p.lng != null)
        .toList();

    available.sort((a, b) {
      final aMatch = cuisines.any((c) =>
          a.name.toLowerCase().contains(c) ||
          a.allTypes.any((t) => t.contains(c)));
      final bMatch = cuisines.any((c) =>
          b.name.toLowerCase().contains(c) ||
          b.allTypes.any((t) => t.contains(c)));

      if (aMatch != bMatch) return aMatch ? -1 : 1;

      return _distSq(a.lat!, a.lng!, center.lat, center.lng)
          .compareTo(_distSq(b.lat!, b.lng!, center.lat, center.lng));
    });

    return available.take(count).toList();
  }

  // ─────────────────────────────────────────────
  // Assign time slots
  // Structure mirrors the old Gemini prompt rules
  // ─────────────────────────────────────────────

  List<ItineraryPlace> _assignTimeSlots(
    List<PlaceModel> attractions,
    List<PlaceModel> restaurants,
    int              placesPerDay,
  ) {
    final slots = <({String time, int duration, bool isRestaurant})>[];

    if (placesPerDay == 2) {
      slots.add((time: '09:00', duration: 120, isRestaurant: false));
      slots.add((time: '12:30', duration: 75,  isRestaurant: true));
    } else if (placesPerDay == 3) {
      slots.add((time: '09:00', duration: 120, isRestaurant: false));
      slots.add((time: '12:00', duration: 75,  isRestaurant: true));
      slots.add((time: '14:30', duration: 120, isRestaurant: false));
    } else if (placesPerDay == 4) {
      slots.add((time: '08:00', duration: 150, isRestaurant: false));
      slots.add((time: '11:30', duration: 75,  isRestaurant: true));
      slots.add((time: '14:00', duration: 150, isRestaurant: false));
      slots.add((time: '18:00', duration: 90,  isRestaurant: true));
    } else if (placesPerDay == 5) {
      slots.add((time: '08:00', duration: 120, isRestaurant: false));
      slots.add((time: '11:00', duration: 75,  isRestaurant: true));
      slots.add((time: '13:30', duration: 120, isRestaurant: false));
      slots.add((time: '17:00', duration: 90,  isRestaurant: true));
      slots.add((time: '19:30', duration: 90,  isRestaurant: false));
    } else {
      // 6 places
      slots.add((time: '08:00', duration: 90,  isRestaurant: false));
      slots.add((time: '10:30', duration: 90,  isRestaurant: false));
      slots.add((time: '12:30', duration: 75,  isRestaurant: true));
      slots.add((time: '14:30', duration: 90,  isRestaurant: false));
      slots.add((time: '17:30', duration: 90,  isRestaurant: true));
      slots.add((time: '20:00', duration: 90,  isRestaurant: false));
    }

    final result = <ItineraryPlace>[];
    int attIdx = 0;
    int resIdx = 0;

    for (final slot in slots) {
      PlaceModel? place;

      if (slot.isRestaurant && resIdx < restaurants.length) {
        place = restaurants[resIdx++];
      } else if (!slot.isRestaurant && attIdx < attractions.length) {
        place = attractions[attIdx++];
      } else if (!slot.isRestaurant && resIdx < restaurants.length) {
        place = restaurants[resIdx++]; // fallback
      } else if (slot.isRestaurant && attIdx < attractions.length) {
        place = attractions[attIdx++]; // fallback
      }

      if (place == null) continue;

      result.add(ItineraryPlace(
        placeId:         place.id,
        name:            place.name,
        address:         place.address ?? '',
        photoUrl:        place.photoUrl,
        lat:             place.lat,
        lng:             place.lng,
        suggestedTime:   slot.time,
        durationMinutes: slot.duration,
        notes:           _generateNote(place),
      ));
    }

    return result;
  }

  // ─────────────────────────────────────────────
  // Rule-based notes
  // ─────────────────────────────────────────────

  String _generateNote(PlaceModel p) {
    final stars = p.rating != null
        ? '⭐ ${p.rating!.toStringAsFixed(1)} · '
        : '';

    return switch (p.primaryType ?? '') {
      'restaurant'         => '${stars}Popular dining spot. Check wait times during peak hours.',
      'tourist_attraction' => '${stars}A must-visit landmark. Arrive early to avoid crowds.',
      'shopping_mall'      => '${stars}Great for shopping and indoor activities.',
      'amusement_park'     => '${stars}Fun for all ages. Book tickets in advance if possible.',
      'park'               => '${stars}Perfect for a relaxing outdoor break.',
      _                    => '${stars}Worth a visit during your trip.',
    };
  }

  // ─────────────────────────────────────────────
  // Geometry helpers
  // ─────────────────────────────────────────────

  /// Squared Euclidean distance (no sqrt needed — used for comparison only)
  double _distSq(double lat1, double lng1, double lat2, double lng2) {
    final dlat = lat1 - lat2;
    final dlng = lng1 - lng2;
    return dlat * dlat + dlng * dlng;
  }

  /// Geographic centroid of a list of places
  ({double lat, double lng}) _centroid(List<PlaceModel> places) {
    final valid = places
        .where((p) => p.lat != null && p.lng != null)
        .toList();
    if (valid.isEmpty) return (lat: 0.0, lng: 0.0);
    final lat = valid.map((p) => p.lat!).reduce((a, b) => a + b) / valid.length;
    final lng = valid.map((p) => p.lng!).reduce((a, b) => a + b) / valid.length;
    return (lat: lat, lng: lng);
  }
}