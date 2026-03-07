// services/itinerary_service.dart
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../modules/itinerary/itineraryModel.dart';
import '../services/placeModal.dart';
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
      final prefs = UserPreferenceService.instance.current;

      final needed = (totalDays * placesPerDay * 1.5).ceil();
      final maxPlaces = needed.clamp(15, 40);

      // ✅ 所有有照片的地点
      final allValid = nearbyPlaces
          .where((p) => p.photoUrl != null && p.photoUrl!.isNotEmpty)
          .toList();

      // ✅ 分类：餐厅 vs 其他
      final restaurants = allValid.where((p) =>
          p.primaryType == 'restaurant' ||
          p.allTypes.any((t) =>
              t.contains('restaurant') ||
              t == 'cafe'              ||
              t == 'coffee_shop'       ||
              t == 'food'              ||
              t == 'bakery'            ||
              t == 'meal_takeaway'     ||
              t == 'meal_delivery')).toList();

      final others = allValid
          .where((p) => !restaurants.contains(p))
          .toList();

      // ✅ 强制至少 40% 是餐厅
      final minRestaurants = (maxPlaces * 0.4).ceil();
      final restCount  = restaurants.length.clamp(0, minRestaurants);
      final otherCount = maxPlaces - restCount;

      final validPlaces = [
        ...restaurants.take(restCount),
        ...others.take(otherCount),
      ];

      print('📍 $totalDays days × $placesPerDay places');
      print('🍽️  Restaurants: $restCount | Others: ${validPlaces.length - restCount}');
      print('📋 Places sent to Gemini:');
      for (final p in validPlaces) {
        print('  ${p.name} | ${p.primaryType} | ${p.allTypes.take(3).toList()}');
      }

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
You are an experienced local travel guide planning a real, enjoyable day trip itinerary.

About this traveler:
- Interests: $categoryText
- Favourite cuisines: $cuisineText
- Getting around by: ${prefs.travelMode}

Trip: $tripTitle
Days: $totalDays ($dayDatesList)
Places per day: $placesPerDay

Available places:
${jsonEncode(placesJson)}

How to identify place types from the "types" field:
- Restaurant/food: types contains "restaurant", "cafe", "coffee_shop", "food", "bakery"
- Park/nature: types contains "park", "garden"
- Attraction: types contains "tourist_attraction", "museum", "historical_landmark"
- Shopping: types contains "shopping_mall", "store"

MANDATORY meal rules (strictly follow):
- Every day MUST have at least 1 lunch stop (between 11:30-14:00)
- Every day MUST have at least 1 dinner stop (between 18:00-21:00)
- For lunch and dinner, ONLY pick places whose types contain "restaurant", "cafe", "coffee_shop", "food", or "bakery"
- Prefer restaurants matching traveler's cuisine preferences: $cuisineText

Time structure per day:
- 08:00-11:00: Morning activity or breakfast cafe
- 11:30-14:00: LUNCH — must be a restaurant or cafe
- 14:00-17:30: Afternoon activity
- 18:00-21:00: DINNER — must be a restaurant

Other rules:
- NEVER repeat the same placeId across different days
- Output MUST have exactly $totalDays day objects
- Each day MUST have exactly $placesPerDay places
- Order places by suggestedTime ascending within each day
- suggestedTime: HH:MM format (24h)
- durationMinutes: 30 to 180 depending on place type
- notes: one practical sentence about visiting this place
- Use exact dates: $dayDatesList

Return ONLY a raw JSON array. No markdown. No backticks. Start with [ and end with ].
Each place needs only: placeId, suggestedTime, durationMinutes, notes.

[
  {
    "dayNumber": 1,
    "date": "${dayDates[0]}",
    "places": [
      {
        "placeId": "...",
        "suggestedTime": "09:00",
        "durationMinutes": 60,
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
      const apiKey = "AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc";

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
            'temperature':      0.4,
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