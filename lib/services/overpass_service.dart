import 'dart:convert';
import 'package:http/http.dart' as http;

class OverpassService {
  static const String _baseUrl = 'https://overpass-api.de/api/interpreter';

  // ── Restaurant: cuisine tag → our internal type ──────────────────────────
  static const Map<String, String> _cuisineToType = {
    'chinese':            'chinese_restaurant',
    'cantonese':          'chinese_restaurant',
    'dim_sum':            'chinese_restaurant',
    'chinese;dim_sum':    'chinese_restaurant',
    'malay':              'malaysian_restaurant',
    'malaysian':          'malaysian_restaurant',
    'indian':             'indian_restaurant',
    'indian;malay':       'indian_restaurant',
    'japanese':           'japanese_restaurant',
    'sushi':              'japanese_restaurant',
    'ramen':              'japanese_restaurant',
    'japanese;sushi':     'japanese_restaurant',
    'korean':             'korean_restaurant',
    'korean;bbq':         'korean_restaurant',
    'western':            'western_restaurant',
    'american':           'american_restaurant',
    'italian':            'western_restaurant',
    'pizza':              'western_restaurant',
    'burger':             'western_restaurant',
    'steak_house':        'western_restaurant',
    'coffee_shop':        'cafe',
    'coffee':             'cafe',
    'cafe':               'cafe',
    'dessert':            'dessert_shop',
    'ice_cream':          'ice_cream_shop',
    'bakery':             'bakery',
    'bubble_tea':         'dessert_shop',
    'thai':               'western_restaurant',
    'vietnamese':         'western_restaurant',
  };

  // ─────────────────────────────────────────────────────────────────────────
  // PUBLIC: Batch query ALL categories
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, String>> fetchAllTags({
    required Map<String, List<Map<String, String>>> placesByPrimary,
  }) async {
    if (placesByPrimary.isEmpty) return {};

    final allOsmEntries  = <Map<String, String>>[];
    final osmIdToPlaceId = <String, String>{};
    final osmIdToPrimary = <String, String>{};

    for (final entry in placesByPrimary.entries) {
      final primaryType = entry.key;
      final places      = entry.value;

      for (final place in places) {
        final osmId   = place['osmId']   ?? '';
        final osmType = place['osmType'] ?? 'node';
        final placeId = place['placeId'] ?? '';

        if (osmId.isNotEmpty && placeId.isNotEmpty) {
          allOsmEntries.add({'osmId': osmId, 'osmType': osmType});
          osmIdToPlaceId[osmId] = placeId;
          osmIdToPrimary[osmId] = primaryType;
        }
      }
    }

    if (allOsmEntries.isEmpty) return {};

    final nodeIds = allOsmEntries
        .where((e) => (e['osmType'] ?? 'node') == 'node')
        .map((e) => e['osmId']!)
        .where((id) => id.isNotEmpty)
        .toList();

    final wayIds = allOsmEntries
        .where((e) => e['osmType'] == 'way')
        .map((e) => e['osmId']!)
        .where((id) => id.isNotEmpty)
        .toList();

    final relationIds = allOsmEntries
        .where((e) => e['osmType'] == 'relation')
        .map((e) => e['osmId']!)
        .where((id) => id.isNotEmpty)
        .toList();

    final buffer = StringBuffer();
    buffer.writeln('[out:json][timeout:25];');
    buffer.writeln('(');
    if (nodeIds.isNotEmpty) {
      buffer.writeln('  node(id:${nodeIds.join(',')});');
    }
    if (wayIds.isNotEmpty) {
      buffer.writeln('  way(id:${wayIds.join(',')});');
    }
    if (relationIds.isNotEmpty) {
      buffer.writeln('  relation(id:${relationIds.join(',')});');
    }
    buffer.writeln(');');
    buffer.writeln('out tags;');

    try {
      print('🗺️ Overpass: querying ${allOsmEntries.length} OSM places (all categories)...');

      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'data=${Uri.encodeComponent(buffer.toString())}',
      ).timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        print('❌ Overpass API error: ${response.statusCode}');
        return {};
      }

      final data     = jsonDecode(response.body);
      final elements = data['elements'] as List? ?? [];

      final Map<String, String> result = {};

      for (final element in elements) {
        final osmId   = element['id']?.toString() ?? '';
        final tags    = element['tags'] as Map<String, dynamic>? ?? {};
        final placeId = osmIdToPlaceId[osmId];
        final primary = osmIdToPrimary[osmId];

        if (placeId == null || primary == null) continue;

        final resolvedType = _resolveType(tags, primary);
        if (resolvedType != null) {
          result[placeId] = resolvedType;
          print('✅ Overpass: $placeId ($primary) → $resolvedType');
        }
      }

      print('🗺️ Overpass: resolved ${result.length}/${allOsmEntries.length} places');
      return result;

    } catch (e) {
      print('❌ Overpass exception: $e');
      return {};
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: key + value 判断，完全不用 Map
  // ─────────────────────────────────────────────────────────────────────────
  static String? _resolveType(Map<String, dynamic> tags, String primaryType) {
    switch (primaryType) {

      // ── Restaurant ────────────────────────────────────────────────────────
      case 'restaurant': {
        final cuisine = tags['cuisine']?.toString().toLowerCase().trim() ?? '';
        if (cuisine.isEmpty) return null;

        final exact = _cuisineToType[cuisine];
        if (exact != null) return exact;

        for (final part in cuisine.split(';').map((c) => c.trim())) {
          final mapped = _cuisineToType[part];
          if (mapped != null) return mapped;
        }
        return null;
      }

      // ── Park ──────────────────────────────────────────────────────────────
      case 'park': {
        final leisure  = tags['leisure']?.toString().toLowerCase()  ?? '';
        final natural  = tags['natural']?.toString().toLowerCase()  ?? '';
        final tourism  = tags['tourism']?.toString().toLowerCase()  ?? '';
        final historic = tags['historic']?.toString().toLowerCase() ?? '';
        final amenity  = tags['amenity']?.toString().toLowerCase()  ?? '';

        // key=leisure
        if (leisure == 'park')              return 'park';
        if (leisure == 'garden')            return 'botanical_garden';
        if (leisure == 'nature_reserve')    return 'national_park';
        if (leisure == 'recreation_ground') return 'park';

        // key=natural
        if (natural == 'beach')             return 'beach';
        if (natural == 'wood')              return 'hiking_area';
        if (natural == 'forest')            return 'hiking_area';

        // key=tourism
        if (tourism == 'attraction')        return 'tourist_attraction';
        if (tourism == 'museum')            return 'museum';
        if (tourism == 'gallery')           return 'art_gallery';
        if (tourism == 'viewpoint')         return 'tourist_attraction';

        // key=historic
        if (historic == 'monument')         return 'monument';
        if (historic == 'memorial')         return 'historical_landmark';
        if (historic == 'castle')           return 'historical_landmark';
        if (historic == 'ruins')            return 'historical_landmark';
        if (historic == 'fort')             return 'historical_landmark';

        // key=amenity
        if (amenity == 'place_of_worship')  return 'tourist_attraction';

        return null;
      }

      // ── Entertainment ─────────────────────────────────────────────────────
      case 'entertainment': {
        final amenity = tags['amenity']?.toString().toLowerCase() ?? '';
        final leisure = tags['leisure']?.toString().toLowerCase() ?? '';
        final tourism = tags['tourism']?.toString().toLowerCase() ?? '';

        // key=amenity
        if (amenity == 'cinema')            return 'movie_theater';
        if (amenity == 'theatre')           return 'movie_theater';
        if (amenity == 'nightclub')         return 'night_club';
        if (amenity == 'casino')            return 'amusement_center';
        if (amenity == 'bowling_alley')     return 'bowling_alley';
        if (amenity == 'karaoke_box')       return 'karaoke';

        // key=leisure
        if (leisure == 'amusement_arcade')  return 'video_arcade';
        if (leisure == 'water_park')        return 'amusement_park';
        if (leisure == 'fitness_centre')    return 'fitness_center';
        if (leisure == 'sports_centre')     return 'sports_complex';
        if (leisure == 'stadium')           return 'stadium';
        if (leisure == 'swimming_pool')     return 'sports_complex';
        if (leisure == 'spa')               return 'spa';

        // key=tourism
        if (tourism == 'theme_park')        return 'amusement_park';
        if (tourism == 'zoo')               return 'amusement_park';
        if (tourism == 'aquarium')          return 'amusement_park';

        return null;
      }

      // ── Shopping ──────────────────────────────────────────────────────────
      case 'shopping_mall': {
        final shop    = tags['shop']?.toString().toLowerCase()    ?? '';
        final amenity = tags['amenity']?.toString().toLowerCase() ?? '';

        // key=shop
        if (shop == 'mall')                 return 'shopping_mall';
        if (shop == 'supermarket')          return 'supermarket';
        if (shop == 'convenience')          return 'convenience_store';
        if (shop == 'department_store')     return 'department_store';
        if (shop == 'clothes')              return 'clothing_store';
        if (shop == 'shoes')                return 'shoe_store';
        if (shop == 'electronics')          return 'electronics_store';
        if (shop == 'mobile_phone')         return 'electronics_store';
        if (shop == 'computer')             return 'electronics_store';
        if (shop == 'books')                return 'book_store';
        if (shop == 'pharmacy')             return 'pharmacy';
        if (shop == 'chemist')              return 'pharmacy';
        if (shop == 'marketplace')          return 'market';
        if (shop == 'grocery')              return 'grocery_store';
        if (shop == 'hardware')             return 'department_store';
        if (shop == 'furniture')            return 'department_store';
        if (shop == 'jewelry')              return 'clothing_store';
        if (shop == 'sports')               return 'department_store';

        // key=amenity
        if (amenity == 'marketplace')       return 'market';
        if (amenity == 'pharmacy')          return 'pharmacy';

        return null;
      }

      // ── Transit ───────────────────────────────────────────────────────────
      // 这里完全用 key + value，不用 Map，因为同一个 value 在不同 key 下意思不同
      case 'transit': {
        final railway = tags['railway']?.toString().toLowerCase()          ?? '';
        final highway = tags['highway']?.toString().toLowerCase()          ?? '';
        final amenity = tags['amenity']?.toString().toLowerCase()          ?? '';
        final pt      = tags['public_transport']?.toString().toLowerCase() ?? '';

        // key=railway
        if (railway == 'station')           return 'train_station';
        if (railway == 'halt')              return 'train_station';
        if (railway == 'tram_stop')         return 'light_rail_station';
        if (railway == 'subway_entrance')   return 'subway_station';

        // key=highway
        if (highway == 'bus_stop')          return 'bus_stop';

        // key=amenity
        if (amenity == 'bus_station')       return 'bus_station';
        if (amenity == 'ferry_terminal')    return 'transit_station';
        if (amenity == 'taxi')              return 'taxi_stand';

        // key=public_transport
        // 注意: pt=station 不等于 railway=station
        // pt=station 是更泛指的 transit station
        if (pt == 'station')                return 'transit_station';
        if (pt == 'stop_position')          return 'transit_station';
        if (pt == 'platform')               return 'transit_station';

        return null;
      }

      // ── Service ───────────────────────────────────────────────────────────
      case 'service': {
        final amenity    = tags['amenity']?.toString().toLowerCase()    ?? '';
        final healthcare = tags['healthcare']?.toString().toLowerCase() ?? '';

        // key=amenity
        if (amenity == 'hospital')          return 'hospital';
        if (amenity == 'clinic')            return 'medical_clinic';
        if (amenity == 'doctors')           return 'doctor';
        if (amenity == 'dentist')           return 'medical_clinic';
        if (amenity == 'pharmacy')          return 'pharmacy';
        if (amenity == 'bank')              return 'bank';
        if (amenity == 'atm')               return 'atm';
        if (amenity == 'post_office')       return 'post_office';

        // key=healthcare
        if (healthcare == 'hospital')       return 'hospital';
        if (healthcare == 'clinic')         return 'medical_clinic';
        if (healthcare == 'pharmacy')       return 'pharmacy';

        return null;
      }

      default:
        return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Keep old method for backward compatibility
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, String>> fetchCuisineTags(
    List<Map<String, String>> osmEntries,
  ) async {
    final placesByPrimary = <String, List<Map<String, String>>>{
      'restaurant': osmEntries.map((e) => {
        'osmId':   e['osmId']   ?? '',
        'osmType': e['osmType'] ?? 'node',
        'placeId': e['osmId']   ?? '',
      }).toList(),
    };
    return fetchAllTags(placesByPrimary: placesByPrimary);
  }
}