import 'placeModal.dart';
import 'placesAPI_service.dart';
import 'location_service.dart';

class NearbyPlacesService {
  static final NearbyPlacesService instance = NearbyPlacesService._();
  NearbyPlacesService._();

  bool _isLoading = false;
  bool _hasLoadedOnce = false;

  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};

  List<PlaceModel> get allPlaces => List.unmodifiable(_allPlacesCache);
  Map<String, List<PlaceModel>> get placesByType => Map.unmodifiable(_placesByTypeCache);

  /// 🟢 只在第一次调用时打 API，之后全部走 cache
  Future<List<PlaceModel>> loadNearbyPlacesOnce(List<Map<String, dynamic>> categories) async {
    if (_hasLoadedOnce) {
      print('🧠 NearbyPlacesService: using cache, no API call');
      return _allPlacesCache;
    }

    if (_isLoading) {
      print('⏳ NearbyPlacesService: already loading, return current cache');
      return _allPlacesCache;
    }

    final pos = LocationService.instance.currentPosition;
    if (pos == null) throw Exception("No location");

    _isLoading = true;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();

    final types = categories
        .where((c) => c['type'] != 'all')
        .map((c) => c['type'] as String)
        .toList();

    print('🌍 NearbyPlacesService: first load, calling API for types: $types');

    for (final type in types) {
      final apiResults = await PlacesApiService.searchNearby(
        lat: pos.latitude,
        lng: pos.longitude,
        type: type,
        radius: 5000,
      );

      final results = apiResults.map((p) {
        try {
          final place = PlaceModel.fromGoogle(p, primary: type);
          if (place.lat == null || place.lng == null) return null;
          return place;
        } catch (e) {
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

    _hasLoadedOnce = true;
    _isLoading = false;

    print('✅ NearbyPlacesService: cache ready, total ${_allPlacesCache.length} places');

    return _allPlacesCache;
  }

  // /// 🟡 一级分类：从 cache 取
  // List<PlaceModel> getByPrimaryType(String type) {
  //   if (type == 'all') {
  //     return List.unmodifiable(_allPlacesCache);
  //   }
  //   return List.unmodifiable(_placesByTypeCache[type] ?? []);
  // }

//   /// 🔵 二级关键词过滤：在给定列表上做本地过滤
// List<PlaceModel> filterByKeyword(List<PlaceModel> base, String keyword, List<String> allowTypes) {
//   if (keyword.isEmpty && allowTypes.isEmpty) {
//     return base; // 如果没有关键词和类型，直接返回所有数据
//   }

//   final keywords = keyword
//       .toLowerCase()
//       .split(RegExp(r'\s+'))
//       .where((k) => k.trim().isNotEmpty)
//       .toList();

//   print("Filtering with keyword: $keywords and types: $allowTypes");

//   return base.where((place) {
//     final name = place.name?.toLowerCase() ?? '';
//     final address = place.address?.toLowerCase() ?? '';
//     final types = (place.types ?? []).map((t) => t.toLowerCase()).toList();

//     // 打印调试信息
//     print("Place: ${place.name}, Types: $types");

//     // 关键词匹配
//     bool keywordMatch = true;
//     if (keywords.isNotEmpty) {
//       // 关键词匹配必须同时出现在名称、地址或类型中
//       keywordMatch = keywords.every((k) =>
//           name.contains(k) ||
//           address.contains(k) ||
//           types.any((t) => t.contains(k)));
//     }

//     // 类型匹配
//     bool typeMatch = true;
//     if (allowTypes.isNotEmpty) {
//       typeMatch = types.any((t) => allowTypes.contains(t));
//     }

//     // 打印出匹配结果
//     print("Keyword Match: $keywordMatch, Type Match: $typeMatch");

//     // **只有在关键词和类型都匹配时才显示**，如果任意一个不匹配就不显示该地点
//     return keywordMatch && typeMatch;
//   }).toList();
// }

  /// 🔄 手动清 cache（换城市 / 下拉刷新用）
  void clearCache() {
    print('♻️ NearbyPlacesService: cache cleared');
    _hasLoadedOnce = false;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();
  }
}
