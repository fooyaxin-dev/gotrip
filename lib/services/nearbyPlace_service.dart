import 'package:flutter/material.dart';
import 'placeModal.dart';
import 'placesAPI_service.dart';
import 'location_service.dart';

class NearbyPlacesService {
  static final NearbyPlacesService instance = NearbyPlacesService._();
  NearbyPlacesService._();
  List<PlaceModel> get cachedPlaces => _allPlacesCache; // 你现有的缓存列表
  final Map<String, List<PlaceModel>> _searchCache = {};

  bool _isLoading = false;
  bool _hasLoadedOnce = false;

  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};

  List<PlaceModel> get allPlaces => List.unmodifiable(_allPlacesCache);
  Map<String, List<PlaceModel>> get placesByType => Map.unmodifiable(_placesByTypeCache);
  bool get hasLoaded => _hasLoadedOnce;

  // ─────────────────────────────────────────────
  // 进页面时调用一次
  // 所有 type 同时 call（parallel），速度快 5x
  // load 完之后预先下载所有图片
  // ─────────────────────────────────────────────

  Future<List<PlaceModel>> loadNearbyPlacesOnce(
    List<Map<String, dynamic>> categories,
    BuildContext context, {
    double? lat,
    double? lng,
  }) async {
    if (_hasLoadedOnce) {
      print('🧠 NearbyPlacesService: using cache, no API call');
      return _allPlacesCache;
    }

    if (_isLoading) {
      print('⏳ NearbyPlacesService: already loading');
      return _allPlacesCache;
    }

    final pos = LocationService.instance.currentPosition;
    if (pos == null && lat == null) throw Exception('No location');

    // 优先用传进来的坐标，fallback 才用 GPS
    final searchLat = lat ?? pos?.latitude ?? 0;
    final searchLng = lng ?? pos?.longitude ?? 0;
    print('🔍 SEARCHING AT: $searchLat, $searchLng');
    
    _isLoading = true;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();

    final types = categories
        .where((c) => c['type'] != 'all')
        .map((c) => c['type'] as String)
        .toList();

    print('🌍 NearbyPlacesService: loading ${types.length} types in parallel...');
    final stopwatch = Stopwatch()..start();

    // 所有 type 同时 call
    final allResults = await Future.wait(
      types.map((type) async {
        final apiResults = await PlacesApiService.searchNearby(
          lat: searchLat,
          lng: searchLng,
          type: type,
          radius: 5000,
          maxResultCount: 20,
        );
        return MapEntry(type, apiResults);
      }),
    );

    // 处理结果，存进 cache
    for (final entry in allResults) {
      final type = entry.key;
      final apiResults = entry.value;

      final results = apiResults.map((p) {
        try {
          final place = PlaceModel.fromGoogle(p, primary: type);
          if (place.lat == null || place.lng == null) return null;
          return place;
        } catch (_) {
          return null;
        }
      }).whereType<PlaceModel>().toList();

      _placesByTypeCache[type] = results;

      for (final p in results) {
        if (!_allPlacesCache.any((e) => e.id == p.id)) {
          _allPlacesCache.add(p);
        }
      }
    }

    stopwatch.stop();
    _hasLoadedOnce = true;
    _isLoading = false;

    print('✅ NearbyPlacesService: loaded ${_allPlacesCache.length} places in ${stopwatch.elapsedMilliseconds}ms');

    // ✅ data load 完之后，背景预先下载所有图片
    _precacheImages(context);

    return _allPlacesCache;
  }


  /// 📍 以指定坐标搜索附近（不用 cache，用于 search 功能）
  Future<List<PlaceModel>> loadNearbyPlacesAt({
    required double lat,
    required double lng,
    required List<Map<String, dynamic>> categories,
    required BuildContext context,
  }) async {
    // 检查缓存（坐标精确到小数点后3位，约100m精度）
    final cacheKey = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    if (_searchCache.containsKey(cacheKey)) {
      print('🧠 loadNearbyPlacesAt: cache hit for $cacheKey');
      return _searchCache[cacheKey]!;
    }

    final types = categories
        .where((c) => c['type'] != 'all')
        .map((c) => c['type'] as String)
        .toList();

    print('🔍 loadNearbyPlacesAt: ($lat, $lng), ${types.length} types...');

    // 每个 type 单独 try catch，一个失败不影响其他
    final allResults = await Future.wait(
      types.map((type) async {
        try {
          final apiResults = await PlacesApiService.searchNearby(
            lat: lat,
            lng: lng,
            type: type,
            radius: 5000,
            maxResultCount: 20,
          );
          return MapEntry(type, apiResults);
        } catch (e) {
          print('⚠️ loadNearbyPlacesAt: $type failed - $e');
          return MapEntry(type, <Map<String, dynamic>>[]);
        }
      }),
    );

    final List<PlaceModel> results = [];
    for (final entry in allResults) {
      for (final p in entry.value) {
        try {
          final place = PlaceModel.fromGoogle(p, primary: entry.key);
          if (place.lat == null || place.lng == null) continue;
          if (!results.any((e) => e.id == place.id)) {
            results.add(place);
          }
        } catch (_) {}
      }
    }

    print('✅ loadNearbyPlacesAt: ${results.length} places found');

    // 存进缓存
    _searchCache[cacheKey] = results;

    // 预载图片
    if (context.mounted) _precacheImages(context);

    return results;
  }
 

  
  // ─────────────────────────────────────────────
  // 预先下载图片进 Flutter 缓存
  // 用户滚动到卡片时图片已经ready，几乎秒出
  // ─────────────────────────────────────────────

  void _precacheImages(BuildContext context) {
    final placesWithPhoto = _allPlacesCache
        .where((p) => p.photoUrl != null)
        .toList();

    print('🖼️ Precaching ${placesWithPhoto.length} images in background...');

    for (final place in placesWithPhoto) {
      precacheImage(
        NetworkImage(place.photoUrl!),
        context,
      );
    }
  }

  // ─────────────────────────────────────────────
  // 一级 filter → 从 cache 拿，0 API call
  // ─────────────────────────────────────────────

  List<PlaceModel> getByPrimary(String? primary) {
    if (primary == null || primary == 'all') {
      return List.unmodifiable(_allPlacesCache);
    }
    return List.unmodifiable(_placesByTypeCache[primary] ?? []);
  }

  // ─────────────────────────────────────────────
  // 二级 filter → type + 名字关键词双重匹配，0 API call
  // ─────────────────────────────────────────────

  List<PlaceModel> getBySecondary({
    required String primary,
    required String secondary,
    required List<String> allowTypes,
    required List<String> nameKeywords,
  }) {
    if (secondary == 'all') {
      return getByPrimary(primary);
    }

    final base = getByPrimary(primary);

    final results = base.where((place) {
      final name = place.name.toLowerCase();

      final typeMatch = allowTypes.isNotEmpty &&
          place.allTypes.any((t) => allowTypes.contains(t));

      final nameMatch = nameKeywords.isNotEmpty &&
          nameKeywords.any((k) => name.contains(k.toLowerCase()));

      return typeMatch || nameMatch;
    }).toList();

    print('🔍 getBySecondary[$secondary]: ${base.length} → ${results.length} places');
    return results;
  }

  // ─────────────────────────────────────────────
  // 手动刷新才清 cache，重新 call API
  // ─────────────────────────────────────────────

  void clearCache() {
    print('♻️ NearbyPlacesService: cache cleared');
    _hasLoadedOnce = false;
    _isLoading = false;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();
  }
}