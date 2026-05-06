// services/itinerary_service.dart
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
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
  // Dedicated fetch for itinerary generation
  // 10km radius, 50 per type, NOT cached
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

    print('🗺️ Fetching itinerary candidates (10km radius, 50 per type)...');
    final stopwatch = Stopwatch()..start();

    final entries = await Future.wait(
      types.map((type) async {
        try {
          final raw = await PlacesApiService.searchNearby(
            lat:            lat,
            lng:            lng,
            types:           [type],
            radius:         10000, // 10km — wider than nearby places (5km)
            maxResultCount: 20,    // Google API hard limit is 20
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

    print('📋 Per category (recommendation score):');
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

    print('📍 Total sent to Gemini: ${result.length}');
    for (final p in result) {
      final s = prefs.recommendationScore(
        primaryType:    p.primaryType,
        allTypes:       p.allTypes,
        rating:         p.rating,
        distanceMeters: null,
        priceLevel:     p.priceLevel,
      );
      print('  ${p.name} | ${p.primaryType} | priceLevel=${p.priceLevel ?? "null"} | $s');
    }

    return result;
  }

  // ─────────────────────────────────────────────
  // Generate via Gemini API
  // ─────────────────────────────────────────────

  String _buildDayStructure(int placesPerDay, String cuisineText) {
    final slots = <String>[];

    if (placesPerDay == 2) {
      slots.add('1. Morning (09:00-11:30): Non-restaurant place');
      slots.add('2. Lunch/Dinner (12:30-14:30): MUST be a RESTAURANT — prefer $cuisineText');
    } else if (placesPerDay == 3) {
      slots.add('1. Morning (09:00-11:30): Non-restaurant place');
      slots.add('2. Lunch (12:00-13:30): MUST be a RESTAURANT — prefer $cuisineText');
      slots.add('3. Afternoon (14:30-17:00): Non-restaurant place');
    } else {
      // 4 places (default)
      slots.add('1. Morning (08:00-10:30): Non-restaurant place');
      slots.add('2. Lunch (11:30-13:30): MUST be a RESTAURANT — prefer $cuisineText');
      slots.add('3. Afternoon (14:00-17:00): Non-restaurant place, DIFFERENT category from morning');
      slots.add('4. Dinner (18:00-20:30): MUST be a RESTAURANT — prefer $cuisineText');
      if (placesPerDay > 4) {
        slots.add('5. Evening (21:00+): Any non-restaurant place');
      }
    }

    return slots.join('\n');
  }

  Future<ItineraryModel?> generate({
    required String startDate,
    required int    totalDays,
    required int    placesPerDay,
    required String tripTitle,
    List<String>?   overrideCategories,
    List<String>?   overrideCuisines,
    double?         overrideLat,  // ← custom location from user
    double?         overrideLng,
  }) async {
    try {
      final prefs = UserPreferenceService.instance.current;

      final categories = overrideCategories ?? prefs.categories;
      final cuisines   = overrideCuisines   ?? prefs.cuisines;

      // Use override coords if provided, else fall back to GPS
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
        print('❌ No valid places');
        return null;
      }

      final placesJson = validPlaces.map((p) => {
        'placeId':     p.id,
        'name':        p.name,
        'primaryType': p.primaryType ?? '',
        'types':       p.allTypes.take(3).toList(),
        'rating':      p.rating ?? 0,
      }).toList();

      final placeMap = { for (final p in validPlaces) p.id: p };

      final startDt  = DateTime.parse(startDate);
      final dayDates = List.generate(totalDays, (i) {
        final d = startDt.add(Duration(days: i));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      });

      final dayDatesList = dayDates
          .asMap()
          .entries
          .map((e) => 'Day ${e.key + 1} = ${e.value}')
          .join(', ');

      final cuisineText = cuisines.isEmpty
          ? 'any cuisine'
          : cuisines
              .map((c) => '${c[0].toUpperCase()}${c.substring(1)}')
              .join(', ');

      final categoryText = categories.isEmpty
          ? 'general sightseeing'
          : categories.map((c) {
              const labels = {
                'restaurant':         'Food & Dining',
                'park':               'Nature & Outdoors',
                'tourist_attraction': 'Sightseeing & Culture',
                'shopping_mall':      'Shopping',
                'amusement_park':     'Entertainment',
              };
              return labels[c] ?? c;
            }).join(', ');

      final prompt = '''
You are a local travel guide creating a day trip itinerary.

User's location: Lat $lat, Lng $lng
All places listed below are within 10km of this exact location.
Group each day's places geographically — keep stops close to each other to minimise travel time between them.

Traveler profile:
- Interests: $categoryText
- Favourite cuisines: $cuisineText
- Travel mode: ${prefs.travelMode}
- Budget: ${prefs.budgetTier.label}

Trip: $tripTitle
Days: $totalDays | Dates: $dayDatesList
Places per day: $placesPerDay

Available places by category:
🍽️ RESTAURANTS (use for lunch & dinner only):
${validPlaces.where((p) => p.primaryType == 'restaurant').map((p) => '  - ${p.id}: ${p.name} (⭐${p.rating ?? 0})').join('\n')}

🏛️ ATTRACTIONS:
${validPlaces.where((p) => p.primaryType == 'tourist_attraction').map((p) => '  - ${p.id}: ${p.name} (⭐${p.rating ?? 0})').join('\n')}

🛍️ SHOPPING:
${validPlaces.where((p) => p.primaryType == 'shopping_mall').map((p) => '  - ${p.id}: ${p.name} (⭐${p.rating ?? 0})').join('\n')}

🎭 ENTERTAINMENT:
${validPlaces.where((p) => p.primaryType == 'amusement_park').map((p) => '  - ${p.id}: ${p.name} (⭐${p.rating ?? 0})').join('\n')}

🌿 PARKS & NATURE:
${validPlaces.where((p) => p.primaryType == 'park').map((p) => '  - ${p.id}: ${p.name} (⭐${p.rating ?? 0})').join('\n')}

Full place details:
${jsonEncode(placesJson)}

STRICT DAILY STRUCTURE (follow exactly):
${_buildDayStructure(placesPerDay, cuisineText)}

RULES:
- Prefer places that match the traveler\'s budget: ${prefs.budgetTier.label}
- NEVER use the same placeId twice across all days
- Each day must cover at least 2 different non-restaurant categories
- Prefer higher rated places
- Prefer restaurants matching cuisine: $cuisineText
- Use exact dates: $dayDatesList

Return ONLY a raw JSON array. No markdown. No backticks. Start with [ end with ].
Each place: placeId, suggestedTime, durationMinutes, notes (1 practical sentence).

[
  {
    "dayNumber": 1,
    "date": "${dayDates[0]}",
    "places": [
      {
        "placeId": "...",
        "suggestedTime": "09:00",
        "durationMinutes": 90,
        "notes": "..."
      }
    ]
  }
]''';

      final responseText = await _callGemini(prompt);
      if (responseText == null) return null;

      final days = _parseResponse(responseText, placeMap);
      if (days == null) return null;

      print('✅ Parsed ${days.length} days (expected $totalDays)');
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
  // Robust JSON parser
  // ─────────────────────────────────────────────

  List<ItineraryDay>? _parseResponse(
    String responseText,
    Map<String, PlaceModel> placeMap,
  ) {
    try {
      String cleaned = responseText
          .replaceAll(RegExp(r'```json\s*', multiLine: true), '')
          .replaceAll(RegExp(r'```\s*',     multiLine: true), '')
          .trim();

      final jsonStart = cleaned.indexOf('[');
      final jsonEnd   = cleaned.lastIndexOf(']');

      final jsonStr = (jsonStart != -1 && jsonEnd != -1 && jsonEnd > jsonStart)
          ? cleaned.substring(jsonStart, jsonEnd + 1)
          : cleaned;

      List<dynamic> daysJson;
      try {
        daysJson = jsonDecode(jsonStr) as List<dynamic>;
      } catch (e) {
        print('❌ JSON parse failed: $e');
        print('❌ First 500 chars:\n${jsonStr.substring(0, jsonStr.length.clamp(0, 500))}');
        return null;
      }

      return daysJson.map((d) {
        final dayMap    = Map<String, dynamic>.from(d);
        final rawPlaces = (dayMap['places'] as List? ?? []);

        final fullPlaces = rawPlaces.map((p) {
          final pm       = Map<String, dynamic>.from(p);
          final placeId  = pm['placeId'] as String? ?? '';
          final original = placeMap[placeId];

          return {
            'placeId':         placeId,
            'name':            original?.name        ?? '',
            'address':         original?.address     ?? '',
            'photoUrl':        original?.photoUrl    ?? '',
            'lat':             original?.lat         ?? 0.0,
            'lng':             original?.lng         ?? 0.0,
            'primaryType':     original?.primaryType ?? '',
            'suggestedTime':   pm['suggestedTime']   ?? '09:00',
            'durationMinutes': pm['durationMinutes'] ?? 60,
            'notes':           pm['notes']           ?? '',
          };
        }).toList();

        dayMap['places'] = fullPlaces;
        return ItineraryDay.fromMap(dayMap);
      }).toList();
    } catch (e) {
      print('❌ _parseResponse: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────
  // Gemini API
  // ─────────────────────────────────────────────

  Future<String?> _callGemini(String prompt) async {
    try {
      const String apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';

      final response = await http.post(
        Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [{'text': prompt}]
            }
          ],
          'generationConfig': {
            'temperature':      0.3,
            'maxOutputTokens':  8000,
            'responseMimeType': 'application/json',
          }
        }),
      );

      if (response.statusCode != 200) {
        print('❌ Gemini ${response.statusCode}: ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body);
      return data['candidates'][0]['content']['parts'][0]['text'] as String?;
    } catch (e) {
      print('❌ _callGemini: $e');
      return null;
    }
  }
}