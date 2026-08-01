import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_Keys.dart';
import 'dart:io' show HttpDate;
import 'dart:math' show Random;

class GeoapifyService {
  static const String _apiKey  = ApiKeys.geoapify;
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
  // ── Place Details — fetch full OSM tags for a single place ───────────────
  //
  // 🆕 指数退避重试（带 jitter + Retry-After 支持）
  //
  // Geoapify 在批量并发请求下容易撞 429（限流），之前策略是撞了就直接
  // 放弃，整个地点 fallback 到关键词猜测——能用但命中率随机波动。
  // 现在对"瞬时性"错误（429 限流 / 5xx 服务端错误 / 网络异常）做最多
  // 3 次重试：
  //   - 优先读取服务端返回的 Retry-After header（如果有，按它说的等）
  //   - 没有的话用指数退避：500ms → 1000ms → 2000ms
  //   - 每次延迟额外加 0-30% 随机抖动（jitter），避免同一批里所有
  //     请求在完全相同的时间点集体重试、造成第二波拥堵
  //   - 对"永久性"错误（400/404，比如无效 place_id）不重试，直接放弃
  //
  // 签名保持不变（新增参数带默认值），调用方（GeoapifyEnrichmentService
  // 等）完全不用改代码，行为对外表现依然是「拿到 Map 或者拿到 null」。
  static Future<Map<String, dynamic>?> fetchPlaceDetails(
    String placeId, {
    int maxRetries = 3,
    Duration baseDelay = const Duration(milliseconds: 500),
    Duration maxDelay = const Duration(seconds: 5),
  }) async {
    final uri = Uri.parse('$_detailsUrl?id=$placeId&apiKey=$_apiKey');
    final random = Random();

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await http.get(uri);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final features = data['features'] as List?;
          if (features == null || features.isEmpty) return null;
          return features[0]['properties'] as Map<String, dynamic>?;
        }

        // 只对瞬时性错误重试：429 限流、5xx 服务端错误
        final isRetryable = response.statusCode == 429 ||
            (response.statusCode >= 500 && response.statusCode < 600);

        if (!isRetryable || attempt == maxRetries) {
          print('🟣 Geoapify place-details failed for $placeId: '
              '${response.statusCode} (attempt ${attempt + 1}/${maxRetries + 1}'
              '${isRetryable ? ", retries exhausted" : ", non-retryable"})');
          return null;
        }

        // 优先遵循服务端的 Retry-After header（秒数或 HTTP-date 两种格式都可能出现）
        Duration delay = _computeBackoffDelay(
          attempt: attempt,
          baseDelay: baseDelay,
          maxDelay: maxDelay,
          random: random,
        );
        final retryAfterHeader = response.headers['retry-after'];
        if (retryAfterHeader != null) {
          final serverDelay = _parseRetryAfter(retryAfterHeader);
          if (serverDelay != null && serverDelay <= maxDelay) {
            delay = serverDelay;
          }
        }

        print('🟣 Geoapify place-details ${response.statusCode} for $placeId — '
            'retrying in ${delay.inMilliseconds}ms '
            '(attempt ${attempt + 1}/${maxRetries + 1})');
        await Future.delayed(delay);

      } catch (e) {
        // 网络层异常（超时、DNS 失败、连接中断等）同样当作瞬时性错误重试
        if (attempt == maxRetries) {
          print('🟣 Geoapify place-details exception for $placeId: $e '
              '(gave up after ${attempt + 1} attempts)');
          return null;
        }
        final delay = _computeBackoffDelay(
          attempt: attempt,
          baseDelay: baseDelay,
          maxDelay: maxDelay,
          random: random,
        );
        print('🟣 Geoapify place-details exception for $placeId: $e — '
            'retrying in ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
      }
    }
    return null;
  }

  // 指数退避 + jitter：base * 2^attempt，再叠加 0~30% 的随机抖动，
  // 最后夹在 maxDelay 以内，避免网络不稳定时无限拉长单个请求的等待时间
  static Duration _computeBackoffDelay({
    required int attempt,
    required Duration baseDelay,
    required Duration maxDelay,
    required Random random,
  }) {
    final exponentialMs = baseDelay.inMilliseconds * (1 << attempt);
    final jitterFactor = 1.0 + random.nextDouble() * 0.3; // 1.0~1.3x
    final withJitterMs = (exponentialMs * jitterFactor).round();
    final cappedMs = withJitterMs.clamp(0, maxDelay.inMilliseconds);
    return Duration(milliseconds: cappedMs);
  }

  // 解析 Retry-After header —— 可能是纯数字秒数（"120"），
  // 也可能是 HTTP-date 格式（"Wed, 21 Oct 2025 07:28:00 GMT"）
  static Duration? _parseRetryAfter(String headerValue) {
    final seconds = int.tryParse(headerValue.trim());
    if (seconds != null) return Duration(seconds: seconds);

    try {
      final targetDate = HttpDate.parse(headerValue);
      final diff = targetDate.difference(DateTime.now().toUtc());
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }

}