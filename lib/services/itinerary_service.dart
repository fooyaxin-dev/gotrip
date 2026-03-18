// services/itinerary_service.dart
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../modules/itinerary/itineraryModel.dart';
import '../services/placeModal.dart';
import '../services/nearbyPlace_service.dart';
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

  // ─────────────────────────────────────────────
  // Blocked name keywords — 明显是公司/服务，不是旅游地点
  // ─────────────────────────────────────────────

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
    // 1. blocked by type
    if (p.allTypes.any((t) => _blockedTypes.contains(t))) return true;

    // 2. blocked by name keyword
    final nameLower = p.name.toLowerCase();
    if (_blockedNameKeywords.any((k) => nameLower.contains(k))) return true;

    return false;
  }

  bool _isSuitableForTravel(PlaceModel p) {
    // Must have photo
    if (p.photoUrl == null || p.photoUrl!.isEmpty) return false;
    // Must not be blocked
    if (_isBlocked(p)) return false;
    // Rating must be between 3.5 and 4.9 — 5.0 usually means too few reviews
    // Accept null rating (we don't know) but reject obvious outliers
    final r = p.rating;
    if (r != null && r > 4.95) return false; // likely fake/few reviews
    if (r != null && r < 3.5)  return false; // too low
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
  // ✅ 每个 category 取适合旅游的，按 rating 排序
  // ─────────────────────────────────────────────

  List<PlaceModel> _buildBalancedPlaces(int totalDays) {
    final svc = NearbyPlacesService.instance;

    final perCategory     = (totalDays + 1).clamp(2, 5);
    final restaurantCount = (totalDays * 2 + 1).clamp(3, 8);

    List<PlaceModel> topByType(String type, int count) {
      final list = svc.getByPrimary(type)
          .where(_isSuitableForTravel)
          .toList()
        ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));

      // ✅ fallback: 如果过滤后太少，放宽 rating 5.0 限制
      if (list.length < count) {
        final fallback = svc.getByPrimary(type)
            .where((p) =>
                p.photoUrl != null &&
                p.photoUrl!.isNotEmpty &&
                !_isBlocked(p) &&
                (p.rating == null || p.rating! >= 3.5))
            .toList()
          ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
        return fallback.take(count).toList();
      }

      return list.take(count).toList();
    }

    final restaurants   = topByType('restaurant',         restaurantCount);
    final attractions   = topByType('tourist_attraction', perCategory);
    final malls         = topByType('shopping_mall',      perCategory);
    final entertainment = topByType('amusement_park',     perCategory);
    final parks         = topByType('park',               perCategory);

    print('📋 Per category (travel-suitable):');
    print('  🍽️  Restaurants: ${restaurants.length}');
    print('  🏛️  Attractions: ${attractions.length}');
    print('  🛍️  Malls: ${malls.length}');
    print('  🎭  Entertainment: ${entertainment.length}');
    print('  🌿  Parks: ${parks.length}');

    final seen   = <String>{};
    final result = <PlaceModel>[];

    void addAll(List<PlaceModel> list) {
      for (final p in list) {
        if (seen.add(p.id)) result.add(p);
      }
    }

    addAll(restaurants);
    addAll(attractions);
    addAll(malls);
    addAll(entertainment);
    addAll(parks);

    print('📍 Total places sent to Gemini: ${result.length}');
    for (final p in result) {
      print('  ${p.name} | ${p.primaryType} | ⭐${p.rating ?? "?"}');
    }

    return result;
  }

  // ─────────────────────────────────────────────
  // Generate via Gemini API
  // ─────────────────────────────────────────────

  Future<ItineraryModel?> generate({
    required List<PlaceModel> nearbyPlaces,
    required String startDate,
    required int totalDays,
    required int placesPerDay,
    required String tripTitle,
  }) async {
    try {
      final prefs       = UserPreferenceService.instance.current;
      final validPlaces = _buildBalancedPlaces(totalDays);

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

      final cuisineText = prefs.cuisines.isEmpty
          ? 'any cuisine'
          : prefs.cuisines
              .map((c) => '${c[0].toUpperCase()}${c.substring(1)}')
              .join(', ');

      final categoryText = prefs.categories.isEmpty
          ? 'general sightseeing'
          : prefs.categories.map((c) {
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

Traveler profile:
- Interests: $categoryText
- Favourite cuisines: $cuisineText
- Travel mode: ${prefs.travelMode}

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
Each day MUST have exactly $placesPerDay places:
1. Morning (08:00-10:30): Non-restaurant place (attraction / park / shopping / entertainment)
2. Lunch (11:30-13:30): MUST be a RESTAURANT — prefer $cuisineText
3. Afternoon (14:00-17:00): Non-restaurant place, DIFFERENT category from morning
4. Dinner (18:00-20:30): MUST be a RESTAURANT — prefer $cuisineText
${placesPerDay > 4 ? '5. Evening (21:00+): Any non-restaurant place' : ''}

RULES:
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
      const String apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc'; // String.fromEnvironment('GOOGLE_API_KEY');

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