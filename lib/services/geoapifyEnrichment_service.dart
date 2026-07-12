import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'geoapify_service.dart';
import 'api_Keys.dart';

class GeoapifyEnrichmentService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _cacheCollection = 'geoapify_enrichment';

  static const String _geminiApiKey = ApiKeys.gemini;
  static const String _geminiUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey';

  // ── Restaurant: cuisine → internal type ──────────────────────────────────
  static const Map<String, String> _cuisineToType = {
    'chinese':     'chinese_restaurant',
    'cantonese':   'chinese_restaurant',
    'dim_sum':     'chinese_restaurant',
    'noodle':      'chinese_restaurant',
    'malay':       'malaysian_restaurant',
    'malaysian':   'malaysian_restaurant',
    'indonesian':  'malaysian_restaurant',
    'indian':      'indian_restaurant',
    'japanese':    'japanese_restaurant',
    'sushi':       'japanese_restaurant',
    'ramen':       'japanese_restaurant',
    'korean':      'korean_restaurant',
    'western':     'western_restaurant',
    'american':    'american_restaurant',
    'italian':     'western_restaurant',
    'pizza':       'western_restaurant',
    'burger':      'western_restaurant',
    'steak_house': 'western_restaurant',
    'vietnamese':  'western_restaurant',
    'thai':        'western_restaurant',
    'coffee_shop': 'cafe',
    'coffee':      'cafe',
    'cafe':        'cafe',
    'dessert':     'dessert_shop',
    'ice_cream':   'ice_cream_shop',
    'bakery':      'bakery',
    'bubble_tea':  'dessert_shop',
  };

  // ── Gemini value → internal type (per category) ───────────────────────────
  static const Map<String, String> _geminiRestaurantToType = {
    'chinese':  'chinese_restaurant',
    'malay':    'malaysian_restaurant',
    'indian':   'indian_restaurant',
    'japanese': 'japanese_restaurant',
    'korean':   'korean_restaurant',
    'western':  'western_restaurant',
    'cafe':     'cafe',
    'dessert':  'dessert_shop',
  };

  static const Map<String, String> _geminiParkToType = {
    'park':     'park',
    'garden':   'botanical_garden',
    'beach':    'beach',
    'hiking':   'hiking_area',
    'landmark': 'tourist_attraction',
    'museum':   'museum',
    'temple':   'hindu_temple',
    'mosque':   'mosque',
    'church':   'church',
  };

  static const Map<String, String> _geminiEntertainmentToType = {
    'cinema':     'movie_theater',
    'karaoke':    'karaoke',
    'bowling':    'bowling_alley',
    'gaming':     'video_arcade',
    'theme_park': 'amusement_park',
    'sports':     'sports_complex',
    'spa':        'spa',
    'gym':        'fitness_center',
  };

  static const Map<String, String> _geminiShoppingToType = {
    'mall':        'shopping_mall',
    'supermarket': 'supermarket',
    'fashion':     'clothing_store',
    'electronics': 'electronics_store',
    'pharmacy':    'pharmacy',
    'market':      'market',
    'grocery':     'grocery_store',
  };

  static const Map<String, String> _geminiTransitToType = {
    'lrt_mrt': 'subway_station',
    'bus':     'bus_station',
    'taxi':    'taxi_stand',
    'train':   'train_station',
    'ferry':   'transit_station',
  };

  static const Map<String, String> _geminiServiceToType = {
    'hospital':    'hospital',
    'bank':        'bank',
    'post_office': 'post_office',
    'pharmacy':    'pharmacy',
    'clinic':      'medical_clinic',
    'atm':         'atm',
  };

  // ── Gemini allowed values per category ───────────────────────────────────
  static const Map<String, String> _geminiPromptOptions = {
    'restaurant':    '"chinese", "malay", "indian", "japanese", "korean", "western", "cafe", "dessert"',
    'park':          '"park", "garden", "beach", "hiking", "landmark", "museum", "temple", "mosque", "church"',
    'entertainment': '"cinema", "karaoke", "bowling", "gaming", "theme_park", "sports", "spa", "gym"',
    'shopping_mall': '"mall", "supermarket", "fashion", "electronics", "pharmacy", "market", "grocery"',
    'transit':       '"lrt_mrt", "bus", "taxi", "train", "ferry"',
    'service':       '"hospital", "bank", "post_office", "pharmacy", "clinic", "atm"',
  };

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Extract valid Geoapify place_id from our internal id
  // Returns null if the id doesn't contain a valid place_id
  // ─────────────────────────────────────────────────────────────────────────
  static String? _extractRawPlaceId(String internalId) {
    // 'geo_osm_123456' → no valid place_id, skip Layer 1
    if (internalId.startsWith('geo_osm_')) return null;

    // 'geo_3.13900_101.68690' → lat_lng fallback, no place_id
    if (internalId.startsWith('geo_')) {
      final candidate = internalId.replaceFirst('geo_', '');
      // Real Geoapify place_ids are long hex strings (>30 chars)
      // lat_lng ids look like '3.13900_101.68690' (short, contains underscore between two numbers)
      if (candidate.length < 30) return null;
      return candidate;
    }

    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PUBLIC: Enrich a batch of Geoapify places (all 6 categories)
  // [places] — list of {placeId, primaryType, placeName, address}
  // Returns map of internalId → List<String> (additional types to merge in)
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, List<String>>> enrichPlaces(
    List<Map<String, String>> places,
  ) async {
    if (places.isEmpty) return {};

    final result      = <String, List<String>>{};
    // primaryType → list of places needing Gemini
    final needsGemini = <String, List<Map<String, String>>>{};

    // ── Phase 1: Cache + Geoapify tag (Layer 1) ─────────────────────────────
    const batchSize = 5;
    for (int i = 0; i < places.length; i += batchSize) {
      final batch = places.skip(i).take(batchSize).toList();

      final futures = batch.map((p) => _resolveLayer1(
        internalId:  p['placeId']!,
        primaryType: p['primaryType'] ?? '',
        placeName:   p['placeName']   ?? '',
        address:     p['address']     ?? '',
      ));

      final batchResults = await Future.wait(futures);

      for (int j = 0; j < batch.length; j++) {
        final place   = batch[j];
        final placeId = place['placeId']!;
        final outcome = batchResults[j];

        if (outcome.types.isNotEmpty) {
          result[placeId] = outcome.types;
        } else if (outcome.needsGemini) {
          final primary = place['primaryType'] ?? '';
          if (primary.isEmpty) continue;
          needsGemini.putIfAbsent(primary, () => []);
          needsGemini[primary]!.add(place);
        }
      }

      if (i + batchSize < places.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    final layer1Count = result.length;
    print('🟣 Layer 1 done: $layer1Count/${places.length} resolved');

    // ── Phase 2: ONE Gemini call for ALL remaining places (Layer 2) ──────────
    if (needsGemini.isNotEmpty) {
      final totalCount = needsGemini.values.fold(0, (sum, list) => sum + list.length);
      print('🤖 Gemini: sending $totalCount places in ONE batch call...');

      final geminiResults = await _classifyWithGemini(needsGemini);

      // Collect all places that went through Gemini
      final allGeminiPlaces = needsGemini.values.expand((list) => list).toList();

      final cacheWrites = allGeminiPlaces.map((place) async {
        final placeId     = place['placeId']!;
        final placeName   = place['placeName'] ?? '';
        final primaryType = place['primaryType'] ?? '';

        List<String> resolvedTypes = [];

        // Layer 2: Gemini result (keyed by placeId)
        final geminiValue = geminiResults[placeId];
        if (geminiValue != null) {
          final mapped = _mapGeminiValue(geminiValue, primaryType);
          if (mapped != null) resolvedTypes = [mapped];
        }

        // Layer 3: name-based fallback if Gemini failed or returned unknown
        if (resolvedTypes.isEmpty) {
          final guessed = _guessByName(placeName, primaryType);
          if (guessed != null) {
            resolvedTypes = [guessed];
            print('🟡 Layer 3: $placeName ($primaryType) → $guessed');
          }
        }

        if (resolvedTypes.isNotEmpty) {
          result[placeId] = resolvedTypes;
        }

        // Save to Firestore cache (even if empty, to avoid re-querying)
        try {
          await _firestore.collection(_cacheCollection).doc(placeId).set({
            'types':    resolvedTypes,
            'cachedAt': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          print('⚠️ Cache save failed for $placeId: $e');
        }
      });

      await Future.wait(cacheWrites);
    }

    print('🟣 GeoapifyEnrichment final: ${result.length}/${places.length} places resolved');
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Layer 1 — cache check + Geoapify Place Details tag
  // ─────────────────────────────────────────────────────────────────────────
  static Future<_Layer1Outcome> _resolveLayer1({
    required String internalId,
    required String primaryType,
    required String placeName,
    required String address,
  }) async {
    if (primaryType.isEmpty) {
      return _Layer1Outcome(types: [], needsGemini: false);
    }

    // ── 1. Check Firestore cache ─────────────────────────────────────────
    try {
      final cacheDoc = await _firestore
          .collection(_cacheCollection)
          .doc(internalId)
          .get();

      if (cacheDoc.exists) {
        final cachedTypes = (cacheDoc.data()?['types'] as List?)
            ?.map((e) => e.toString())
            .toList();
        if (cachedTypes != null) {
          return _Layer1Outcome(types: cachedTypes, needsGemini: false);
        }
      }
    } catch (e) {
      print('⚠️ Cache check failed for $internalId: $e');
    }

    // ── 2. Extract valid place_id ────────────────────────────────────────
    // Fix: 'geo_osm_xxx' and 'geo_lat_lng' have no valid Geoapify place_id
    final rawPlaceId = _extractRawPlaceId(internalId);

    if (rawPlaceId != null) {
      // ── 3. Call Geoapify Place Details API ──────────────────────────────
      final props = await GeoapifyService.fetchPlaceDetails(rawPlaceId);

      if (props != null) {
        final raw = (props['datasource'] as Map<String, dynamic>?)
            ?['raw'] as Map<String, dynamic>?;

        if (raw != null) {
          final resolvedTypes = _resolveTypes(raw, primaryType);

          if (resolvedTypes.isNotEmpty) {
            // Save to cache immediately
            try {
              await _firestore.collection(_cacheCollection).doc(internalId).set({
                'types':    resolvedTypes,
                'cachedAt': FieldValue.serverTimestamp(),
              });
            } catch (_) {}

            return _Layer1Outcome(types: resolvedTypes, needsGemini: false);
          }
        }
      }
    }

    // Layer 1 failed → send to Gemini
    return _Layer1Outcome(types: [], needsGemini: true);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Layer 2 — ONE Gemini batch call for ALL categories
  // Fully fault-tolerant: any failure returns empty map, never throws
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, String>> _classifyWithGemini(
    Map<String, List<Map<String, String>>> placesByCategory,
  ) async {
    if (placesByCategory.isEmpty) return {};

    // ── Flatten all places into one indexed list ─────────────────────────
    final allPlaces = <Map<String, String>>[];
    for (final entry in placesByCategory.entries) {
      for (final place in entry.value) {
        allPlaces.add({...place, 'primaryType': entry.key});
      }
    }

    if (allPlaces.isEmpty) return {};

    try {
      // ── Build one prompt with all places, each labelled with category ──
      final placesListStr = allPlaces.asMap().entries.map((e) {
        final idx         = e.key;
        final place       = e.value;
        final primaryType = place['primaryType'] ?? '';
        final options     = _geminiPromptOptions[primaryType] ?? '';
        final label       = _categoryLabel(primaryType);

        if (options.isEmpty) return null;

        return '${idx + 1}. [$label] "${place['placeName']}" '
            '(address: ${place['address'] ?? ''}) '
            '→ must be one of: $options, "unknown"';
      }).where((s) => s != null).join('\n');

      if (placesListStr.trim().isEmpty) return {};

      final prompt = '''
You are a place classifier for Malaysia. Classify each place based on its name, address, and category hint.

Places:
$placesListStr

Respond ONLY with a JSON array, no markdown, no explanation.
Each object must have "index" (matching the number above) and "type" fields.
Use "unknown" only if you genuinely cannot determine the type.

Example: [{"index": 1, "type": "chinese"}, {"index": 2, "type": "park"}, {"index": 3, "type": "unknown"}]
''';

      print('🤖 Gemini: one call for ${allPlaces.length} places across ${placesByCategory.length} categories');

      final response = await http.post(
        Uri.parse(_geminiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {'parts': [{'text': prompt}]}
          ],
          'generationConfig': {
            'temperature':       0.1,
            'maxOutputTokens':   3000,
            'responseMimeType':  'application/json',
          },
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        print('⚠️ Gemini failed (${response.statusCode}) — falling back to Layer 3 for all');
        return {};
      }

      final data   = jsonDecode(response.body);
      final text   = data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '';
      final clean  = text.replaceAll(RegExp(r'```json|```'), '').trim();
      final parsed = jsonDecode(clean) as List;

      // ── Use index to match back to placeId (avoids duplicate name issue) ──
      final Map<String, String> result = {};
      for (final item in parsed) {
        final index = item['index'] as int?;
        final type  = item['type']  as String?;

        if (index == null || type == null || type == 'unknown') continue;
        if (index < 1 || index > allPlaces.length) continue;

        final placeId = allPlaces[index - 1]['placeId']!;
        result[placeId] = type;
      }

      print('🤖 Gemini: ${result.length}/${allPlaces.length} classified in one call');
      return result;

    } catch (e) {
      // Network error, timeout, quota exceeded, JSON parse failure
      // — all safely caught, Layer 3 will handle the rest
      print('⚠️ Gemini exception: $e — falling back to Layer 3 for all');
      return {};
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Map Gemini value → internal type (per category)
  // ─────────────────────────────────────────────────────────────────────────
  static String? _mapGeminiValue(String value, String primaryType) {
    switch (primaryType) {
      case 'restaurant':    return _geminiRestaurantToType[value];
      case 'park':          return _geminiParkToType[value];
      case 'entertainment': return _geminiEntertainmentToType[value];
      case 'shopping_mall': return _geminiShoppingToType[value];
      case 'transit':       return _geminiTransitToType[value];
      case 'service':       return _geminiServiceToType[value];
      default:              return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Layer 3 — conservative name-based fallback (all 6 categories)
  // Only uses STRONG, unambiguous signal words — never generic terms
  // ─────────────────────────────────────────────────────────────────────────
  static String? _guessByName(String name, String primaryType) {
    final n = name.toLowerCase();

    switch (primaryType) {

      case 'restaurant': {
        if (n.contains('dim sum')      || n.contains('hong kong')  ||
            n.contains('canton')       || n.contains('claypot')    ||
            n.contains('wonton')       || n.contains('bak kut teh')||
            n.contains('char siew')    || n.contains('hokkien')    ||
            n.contains('teochew')      || n.contains('cantonese')) {
          return 'chinese_restaurant';
        }
        if (n.contains('sushi')        || n.contains('ramen')      ||
            n.contains('yakitori')     || n.contains('tempura')    ||
            n.contains('izakaya')      || n.contains('tonkatsu')   ||
            n.contains('udon')) {
          return 'japanese_restaurant';
        }
        if (n.contains('korean bbq')   || n.contains('kimchi')     ||
            n.contains('bibimbap')     || n.contains('k-bbq')) {
          return 'korean_restaurant';
        }
        if (n.contains('briyani')      || n.contains('biryani')    ||
            n.contains('tandoor')      || n.contains('roti canai') ||
            n.contains('banana leaf')  || n.contains('thali')      ||
            n.contains('mamak')        || n.contains('nasi kandar')) {
          return 'indian_restaurant';
        }
        if (n.contains('nasi lemak')   || n.contains('rendang')    ||
            n.contains('satay')        || n.contains('laksa')      ||
            n.contains('nasi padang')  || n.contains('masakan padang')) {
          return 'malaysian_restaurant';
        }
        if (n.contains('pizza')        || n.contains('burger')     ||
            n.contains('steakhouse')   || n.contains('steak house')) {
          return 'western_restaurant';
        }
        return null;
      }

      case 'park': {
        if (n.contains('pantai')  || n.contains('beach'))           return 'beach';
        if (n.contains('bukit')   || n.contains('hill')   ||
            n.contains('trail')   || n.contains('hutan')  ||
            n.contains('forest'))                                    return 'hiking_area';
        if (n.contains('botanical') || n.contains('garden') ||
            n.contains('bunga'))                                     return 'botanical_garden';
        if (n.contains('museum')  || n.contains('muzium'))          return 'museum';
        if (n.contains('masjid')  || n.contains('mosque'))          return 'mosque';
        if (n.contains('tokong')  || n.contains('temple') ||
            n.contains('kuil'))                                      return 'hindu_temple';
        if (n.contains('gereja')  || n.contains('church') ||
            n.contains('cathedral'))                                 return 'church';
        if (n.contains('taman')   || n.contains('park'))            return 'park';
        return null;
      }

      case 'entertainment': {
        if (n.contains('cinema')  || n.contains('gsc') ||
            n.contains('tgv')     || n.contains('mbo'))             return 'movie_theater';
        if (n.contains('karaoke') || n.contains('neway') ||
            n.contains('red box'))                                   return 'karaoke';
        if (n.contains('bowling'))                                   return 'bowling_alley';
        if (n.contains('arcade')  || n.contains('esport') ||
            n.contains('gaming'))                                    return 'video_arcade';
        if (n.contains('gym')     || n.contains('fitness'))         return 'fitness_center';
        if (n.contains('spa')     || n.contains('massage'))         return 'spa';
        return null;
      }

      case 'shopping_mall': {
        if (n.contains('supermarket') || n.contains('mydin')  ||
            n.contains('aeon')        || n.contains('tesco')  ||
            n.contains('giant')       || n.contains('econsave')) {
          return 'supermarket';
        }
        if (n.contains('pharmacy')  || n.contains('farmasi') ||
            n.contains('guardian')  || n.contains('watsons') ||
            n.contains('caring')) {
          return 'pharmacy';
        }
        if (n.contains('mall')    || n.contains('plaza')  ||
            n.contains('square')  || n.contains('pavilion')) {
          return 'shopping_mall';
        }
        if (n.contains('pasar')   || n.contains('market') ||
            n.contains('bazaar')) {
          return 'market';
        }
        return null;
      }

      case 'transit': {
        if (n.contains('lrt')     || n.contains('mrt')    ||
            n.contains('ktm')     || n.contains('monorail')||
            n.contains('stesen')) {
          return 'subway_station';
        }
        if (n.contains('bus')     || n.contains('hentian')||
            n.contains('terminal')) {
          return 'bus_station';
        }
        if (n.contains('taxi')    || n.contains('grab'))   return 'taxi_stand';
        return null;
      }

      case 'service': {
        if (n.contains('hospital')    || n.contains('klinik') ||
            n.contains('clinic'))                                    return 'hospital';
        if (n.contains('maybank')     || n.contains('cimb')   ||
            n.contains('public bank') || n.contains('rhb')    ||
            n.contains('hong leong')  || n.contains('ambank')) {
          return 'bank';
        }
        if (n.contains('pos malaysia')|| n.contains('poslaju')||
            n.contains('post office'))                               return 'post_office';
        return null;
      }

      default:
        return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Resolve OSM raw tags → internal types (Layer 1)
  // Uses key + value pattern to avoid ambiguity
  // ─────────────────────────────────────────────────────────────────────────
  static List<String> _resolveTypes(Map<String, dynamic> raw, String primaryType) {
    switch (primaryType) {

      case 'restaurant': {
        final cuisine = raw['cuisine']?.toString().toLowerCase().trim() ?? '';
        if (cuisine.isEmpty) return [];
        final types = <String>{};
        for (final part in cuisine.split(';').map((c) => c.trim())) {
          final mapped = _cuisineToType[part];
          if (mapped != null) types.add(mapped);
        }
        return types.toList();
      }

      case 'park': {
        final leisure  = raw['leisure']?.toString().toLowerCase()  ?? '';
        final natural  = raw['natural']?.toString().toLowerCase()  ?? '';
        final tourism  = raw['tourism']?.toString().toLowerCase()  ?? '';
        final historic = raw['historic']?.toString().toLowerCase() ?? '';
        final amenity  = raw['amenity']?.toString().toLowerCase()  ?? '';

        if (leisure == 'park')              return ['park'];
        if (leisure == 'garden')            return ['botanical_garden'];
        if (leisure == 'nature_reserve')    return ['national_park'];
        if (leisure == 'recreation_ground') return ['park'];
        if (natural == 'beach')             return ['beach'];
        if (natural == 'wood')              return ['hiking_area'];
        if (natural == 'forest')            return ['hiking_area'];
        if (tourism == 'attraction')        return ['tourist_attraction'];
        if (tourism == 'museum')            return ['museum'];
        if (tourism == 'gallery')           return ['art_gallery'];
        if (tourism == 'viewpoint')         return ['tourist_attraction'];
        if (historic == 'monument')         return ['monument'];
        if (historic == 'memorial')         return ['historical_landmark'];
        if (historic == 'castle')           return ['historical_landmark'];
        if (historic == 'ruins')            return ['historical_landmark'];
        if (historic == 'fort')             return ['historical_landmark'];
        if (amenity == 'place_of_worship')  return ['tourist_attraction'];
        return [];
      }

      case 'entertainment': {
        final amenity = raw['amenity']?.toString().toLowerCase() ?? '';
        final leisure = raw['leisure']?.toString().toLowerCase() ?? '';
        final tourism = raw['tourism']?.toString().toLowerCase() ?? '';

        if (amenity == 'cinema')            return ['movie_theater'];
        if (amenity == 'theatre')           return ['movie_theater'];
        if (amenity == 'nightclub')         return ['night_club'];
        if (amenity == 'casino')            return ['amusement_center'];
        if (amenity == 'bowling_alley')     return ['bowling_alley'];
        if (amenity == 'karaoke_box')       return ['karaoke'];
        if (leisure == 'amusement_arcade')  return ['video_arcade'];
        if (leisure == 'water_park')        return ['amusement_park'];
        if (leisure == 'fitness_centre')    return ['fitness_center'];
        if (leisure == 'sports_centre')     return ['sports_complex'];
        if (leisure == 'stadium')           return ['stadium'];
        if (leisure == 'swimming_pool')     return ['sports_complex'];
        if (leisure == 'spa')               return ['spa'];
        if (tourism == 'theme_park')        return ['amusement_park'];
        if (tourism == 'zoo')               return ['amusement_park'];
        if (tourism == 'aquarium')          return ['amusement_park'];
        return [];
      }

      case 'shopping_mall': {
        final shop    = raw['shop']?.toString().toLowerCase()    ?? '';
        final amenity = raw['amenity']?.toString().toLowerCase() ?? '';

        if (shop == 'mall')                 return ['shopping_mall'];
        if (shop == 'supermarket')          return ['supermarket'];
        if (shop == 'convenience')          return ['convenience_store'];
        if (shop == 'department_store')     return ['department_store'];
        if (shop == 'clothes')              return ['clothing_store'];
        if (shop == 'shoes')                return ['shoe_store'];
        if (shop == 'electronics')          return ['electronics_store'];
        if (shop == 'mobile_phone')         return ['electronics_store'];
        if (shop == 'computer')             return ['electronics_store'];
        if (shop == 'books')                return ['book_store'];
        if (shop == 'pharmacy')             return ['pharmacy'];
        if (shop == 'chemist')              return ['pharmacy'];
        if (shop == 'marketplace')          return ['market'];
        if (shop == 'grocery')              return ['grocery_store'];
        if (shop == 'hardware')             return ['department_store'];
        if (shop == 'furniture')            return ['department_store'];
        if (shop == 'jewelry')              return ['clothing_store'];
        if (shop == 'sports')               return ['department_store'];
        if (amenity == 'marketplace')       return ['market'];
        if (amenity == 'pharmacy')          return ['pharmacy'];
        return [];
      }

      case 'transit': {
        final railway = raw['railway']?.toString().toLowerCase()          ?? '';
        final highway = raw['highway']?.toString().toLowerCase()          ?? '';
        final amenity = raw['amenity']?.toString().toLowerCase()          ?? '';
        final pt      = raw['public_transport']?.toString().toLowerCase() ?? '';

        if (railway == 'station')           return ['train_station'];
        if (railway == 'halt')              return ['train_station'];
        if (railway == 'tram_stop')         return ['light_rail_station'];
        if (railway == 'subway_entrance')   return ['subway_station'];
        if (highway == 'bus_stop')          return ['bus_stop'];
        if (amenity == 'bus_station')       return ['bus_station'];
        if (amenity == 'ferry_terminal')    return ['transit_station'];
        if (amenity == 'taxi')              return ['taxi_stand'];
        if (pt == 'station')                return ['transit_station'];
        if (pt == 'stop_position')          return ['transit_station'];
        if (pt == 'platform')               return ['transit_station'];
        return [];
      }

      case 'service': {
        final amenity    = raw['amenity']?.toString().toLowerCase()    ?? '';
        final healthcare = raw['healthcare']?.toString().toLowerCase() ?? '';

        if (amenity == 'hospital')          return ['hospital'];
        if (amenity == 'clinic')            return ['medical_clinic'];
        if (amenity == 'doctors')           return ['doctor'];
        if (amenity == 'dentist')           return ['medical_clinic'];
        if (amenity == 'pharmacy')          return ['pharmacy'];
        if (amenity == 'bank')              return ['bank'];
        if (amenity == 'atm')               return ['atm'];
        if (amenity == 'post_office')       return ['post_office'];
        if (healthcare == 'hospital')       return ['hospital'];
        if (healthcare == 'clinic')         return ['medical_clinic'];
        if (healthcare == 'pharmacy')       return ['pharmacy'];
        return [];
      }

      default:
        return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Helpers
  // ─────────────────────────────────────────────────────────────────────────
  static String _categoryLabel(String primaryType) {
    switch (primaryType) {
      case 'restaurant':    return 'Food & Restaurants';
      case 'park':          return 'Nature & Attractions';
      case 'entertainment': return 'Entertainment';
      case 'shopping_mall': return 'Shopping';
      case 'transit':       return 'Public Transport';
      case 'service':       return 'Services';
      default:              return primaryType;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Internal helper
// ─────────────────────────────────────────────────────────────────────────
class _Layer1Outcome {
  final List<String> types;
  final bool needsGemini;
  _Layer1Outcome({required this.types, required this.needsGemini});
}