import 'dart:convert';
import 'package:http/http.dart' as http;

class GeoapifyService {
  static const String _apiKey  = '-';
  static const String _baseUrl = 'https://api.geoapify.com/v2/places';
  static const String _detailsUrl = 'https://api.geoapify.com/v2/place-details'; // ← 新增
  static const int _limit    = 100;
  static const int _maxPages = 1;

  static const Map<String, String> _categoryMap = {
    'restaurant':    'catering.restaurant,catering.cafe,catering.fast_food,catering.bar,catering.food_court',
    'park':          'leisure.park,leisure.park.garden,leisure.park.nature_reserve',
    'entertainment': 'entertainment.cinema,entertainment.theme_park,entertainment.zoo,entertainment.museum,entertainment.amusement_arcade,entertainment.bowling_alley,entertainment.aquarium,entertainment.water_park',
    'shopping_mall': 'commercial.shopping_mall,commercial.supermarket,commercial.marketplace,commercial.department_store,commercial.clothing',
    'transit':       'public_transport.bus,public_transport.train,public_transport.subway,public_transport.light_rail,public_transport.tram,public_transport.ferry',
    'service':       'service.financial.bank,service.financial.atm,healthcare.hospital,healthcare.pharmacy,healthcare.clinic_or_praxis',
  };

  static const Map<String, List<String>> _typeMapping = {
    'restaurant':    ['restaurant', 'cafe', 'coffee_shop', 'fast_food_restaurant', 'bar', 'food_court'],
    'park':          ['park', 'national_park', 'botanical_garden', 'hiking_area'],
    'entertainment': ['movie_theater', 'amusement_park', 'museum', 'bowling_alley', 'video_arcade', 'amusement_center'],
    'shopping_mall': ['shopping_mall', 'supermarket', 'grocery_store', 'department_store', 'clothing_store'],
    'transit':       ['bus_station', 'bus_stop', 'subway_station', 'light_rail_station', 'transit_station', 'train_station'],
    'service':       ['bank', 'atm', 'hospital', 'pharmacy', 'medical_clinic'],
  };

  // ── Nearby search — all categories in parallel ────────────────────────────
  // radius is now a parameter instead of a hardcoded constant
  static Future<List<Map<String, dynamic>>> fetchNearby({
    required double lat,
    required double lng,
    int radius = 5000, // ← NEW: accepts radius, defaults to 5000
  }) async {
    print('🟣 GeoapifyService: firing ${_categoryMap.length} parallel requests (radius: ${radius}m)...');
    final stopwatch = Stopwatch()..start();

    final entries = _categoryMap.entries.toList();
    final results = await Future.wait(
      entries.map((e) => _fetchCategory(
        lat: lat,
        lng: lng,
        primaryType: e.key,
        categories:  e.value,
        radius:      radius, // ← pass through
      )),
    );

    final flat = <Map<String, dynamic>>[];
    for (int i = 0; i < entries.length; i++) {
      flat.addAll(results[i]);
    }

    stopwatch.stop();
    print('🟣 GeoapifyService: ${flat.length} raw results in ${stopwatch.elapsedMilliseconds}ms');
    return flat;
  }

  // ── Internal: fetch one category with pagination ──────────────────────────
  static Future<List<Map<String, dynamic>>> _fetchCategory({
    required double lat,
    required double lng,
    required String primaryType,
    required String categories,
    required int    radius, // ← NEW
  }) async {
    final List<Map<String, dynamic>> accumulated = [];

    for (int page = 0; page < _maxPages; page++) {
      final offset = page * _limit;
      final uri = Uri.parse(
        '$_baseUrl'
        '?categories=$categories'
        '&filter=circle:$lng,$lat,$radius' // ← uses dynamic radius
        // 📏 NEW: sort results by distance to (lat,lng). Without this,
        // Geoapify doesn't guarantee distance ordering within the filter
        // circle — which matters now that we sometimes fetch at a large
        // radius and cache it, filtering locally for smaller radii later.
        // With bias=proximity, the closest places are guaranteed to be
        // among the first `_limit` (100) returned, same idea as
        // rankPreference:DISTANCE on the Google side.
        '&bias=proximity:$lng,$lat'
        '&limit=$_limit'
        '&offset=$offset'
        '&apiKey=$_apiKey',
      );

      try {
        final response = await http.get(uri);
        if (response.statusCode != 200) {
          print('🟣 Geoapify [$primaryType] page $page HTTP ${response.statusCode}');
          break;
        }

        final data     = jsonDecode(response.body);
        final List features = data['features'] ?? [];

        for (final f in features) {
          final normalized = _normalizeFeature(f, primaryType);
          if (normalized != null) accumulated.add(normalized);
        }

        if (features.length < _limit) break;
        if (page < _maxPages - 1) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      } catch (e) {
        print('🟣 Geoapify [$primaryType] page $page exception: $e');
        break;
      }
    }

    return accumulated;
  }

  // ── Normalize one GeoJSON feature into our standard map shape ────────────
  static Map<String, dynamic>? _normalizeFeature(dynamic feature, String primaryType) {
    final props = feature['properties'] as Map<String, dynamic>? ?? {};
    final geo   = feature['geometry']   as Map<String, dynamic>? ?? {};

    final name = props['name']?.toString().trim() ?? '';
    if (name.isEmpty) return null;

    final coords = geo['coordinates'] as List?;
    if (coords == null || coords.length < 2) return null;
    final lng = (coords[0] as num).toDouble();
    final lat = (coords[1] as num).toDouble();

    final geoapifyPlaceId = props['place_id']?.toString() ?? '';
    final osmId           = props['osm_id']?.toString()   ?? '';
    final osmType         = props['osm_type']?.toString() ?? 'node';
    
    final internalId = geoapifyPlaceId.isNotEmpty
        ? 'geo_$geoapifyPlaceId'
        : osmId.isNotEmpty
            ? 'geo_osm_$osmId'
            : 'geo_${lat.toStringAsFixed(5)}_${lng.toStringAsFixed(5)}';

    final address = _buildAddress(props);
    final types   = List<String>.from(_typeMapping[primaryType] ?? [primaryType]);

    return {
      'id':               internalId,
      'displayName':      {'text': name, 'languageCode': 'en'},
      'formattedAddress': address,
      'location': {
        'latitude':  lat,
        'longitude': lng,
      },
      'types':      types,
      'rating':     null,
      'photos':     <Map<String, String>>[],
      'priceLevel': null,
      'source':     'geoapify',
      'osmId':      osmId,
      'osmType':    osmType,
    };
  }

  static String _buildAddress(Map<String, dynamic> props) {
    final parts   = <String>[];
    final street  = props['street']?.toString()      ?? '';
    final housenr = props['housenumber']?.toString() ?? '';
    final city    = props['city']?.toString()        ?? '';
    final state   = props['state']?.toString()       ?? '';
    final country = props['country']?.toString()     ?? '';

    if (street.isNotEmpty) {
      parts.add(housenr.isNotEmpty ? '$housenr $street' : street);
    }
    if (city.isNotEmpty)    parts.add(city);
    if (state.isNotEmpty)   parts.add(state);
    if (country.isNotEmpty) parts.add(country);

    return parts.join(', ');
  }

  // ── Place Details — fetch full OSM tags for a single place ───────────────
  static Future<Map<String, dynamic>?> fetchPlaceDetails(String placeId) async {
    final uri = Uri.parse('$_detailsUrl?id=$placeId&apiKey=$_apiKey');

    try {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        print('🟣 Geoapify place-details failed for $placeId: ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body);
      final features = data['features'] as List?;
      if (features == null || features.isEmpty) return null;

      return features[0]['properties'] as Map<String, dynamic>?;
    } catch (e) {
      print('🟣 Geoapify place-details exception for $placeId: $e');
      return null;
    }
  }

}