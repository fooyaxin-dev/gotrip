import 'placeModal.dart';
import 'placesAPI_service.dart';
import 'location_service.dart';

class NearbyPlacesService {
  static final NearbyPlacesService instance = NearbyPlacesService._();
  NearbyPlacesService._();

  bool _isLoading = false;

  final List<PlaceModel> _allPlacesCache = [];
  final Map<String, List<PlaceModel>> _placesByTypeCache = {};

  List<PlaceModel> get allPlaces => List.unmodifiable(_allPlacesCache);
  Map<String, List<PlaceModel>> get placesByType => Map.unmodifiable(_placesByTypeCache);

  Future<List<PlaceModel>> LoadNearbyPlacesFromApi(List<Map<String, dynamic>> categories) async {
    if (_isLoading) return _allPlacesCache;

    final pos = LocationService.instance.currentPosition;
    if (pos == null) throw Exception("No location");

    _isLoading = true;
    _allPlacesCache.clear();
    _placesByTypeCache.clear();

    final types = categories
        .where((c) => c['type'] != 'all')
        .map((c) => c['type'] as String)
        .toList();

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

    _isLoading = false;
    return _allPlacesCache;
  }
}
