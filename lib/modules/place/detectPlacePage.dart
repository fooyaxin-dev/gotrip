import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import 'placeDetailPage.dart';
import '../../services/route_service.dart';
import '../../services/location_service.dart';
import '../../services/placeModal.dart';
import '../../services/nearbyPlace_service.dart';
import '../../modules/itinerary/itineraryModel.dart';
import '../../modules/itinerary/itineraryDetail.dart';
import 'routePreviewPage.dart';
import '../../services/placesAPI_service.dart';
import 'favouriteButton.dart';

enum SortMode { distance, rating }

class RealTimeDetectPage extends StatefulWidget {
  final double? landmarkLat;
  final double? landmarkLng;
  final VoidCallback onBack;

  const RealTimeDetectPage({
    super.key,
    this.landmarkLat,
    this.landmarkLng,
    required this.onBack,
  });

  @override
  State<RealTimeDetectPage> createState() => _RealTimeDetectPageState();
}

class _RealTimeDetectPageState extends State<RealTimeDetectPage> {
  GoogleMapController? _mapController;
  Position? _currentPosition;

  final Set<Marker> _markers = {};
  SortMode _sortMode = SortMode.distance;
  TravelMode _travelMode = TravelMode.walk;
  bool _isTravelModeExpanded = false;

  final List<PlaceModel> _displayedPlaces = [];
  Map<String, RouteResult> _routeResults = {};
  bool _isLoading = false;

  String? _selectedPrimary;
  String _selectedSecondary = 'all';

  CameraPosition? _initialCameraPosition;

  // Search
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<Map<String, dynamic>> _autocompleteSuggestions = [];
  bool _isSearchMode = false;       // true = 正在 search / 显示 suggestions
  bool _isSearchLoading = false;
  String? _searchLocationName;      // 当前 search 的地点名字（显示在顶部）
  Timer? _debounce;                 // 防抖，避免每个字都打 API

  // ✅ 用户自选的地点
  final Set<String> _selectedPlaceIds = {};
  List<PlaceModel> _searchPlaces = []; // search mode 的地点，独立存放
  

  final List<Map<String, dynamic>> categories = [
    {'name': 'All',           'icon': Icons.all_inclusive,           'type': 'all',               'color': Colors.black},
    {'name': 'Food',          'icon': Icons.restaurant,              'type': 'restaurant',         'color': Colors.orange},
    {'name': 'Nature',        'icon': Icons.park,                    'type': 'park',               'color': Colors.blue},
    {'name': 'Historical',    'icon': Icons.place,                   'type': 'tourist_attraction', 'color': Colors.green},
    {'name': 'Shopping',      'icon': Icons.shopping_bag,            'type': 'shopping_mall',      'color': Colors.purple},
    {'name': 'Entertainment', 'icon': Icons.local_activity_rounded,  'type': 'amusement_park',     'color': Colors.purple},
  ];

  final Map<String, List<Map<String, dynamic>>> subCategories = {
    'restaurant': [
      {'key': 'all',      'label': 'All',      'allowTypes': <String>[],                                                          'nameKeywords': <String>[]},
      {'key': 'korean',   'label': 'Korean',   'allowTypes': <String>['korean_restaurant'],                                       'nameKeywords': <String>['korea', 'korean', '한국', 'kimchi', 'bbq korean']},
      {'key': 'chinese',  'label': 'Chinese',  'allowTypes': <String>['chinese_restaurant'],                                      'nameKeywords': <String>['chinese', 'canton', 'dim sum', 'claypot', 'clay pot', '中', '华', '粤', '龙', '金', '福', '记', 'kopitiam', 'restoran yee', 'restaurant yee', 'seafood', 'wonton', 'bak kut']},
      {'key': 'japanese', 'label': 'Japanese', 'allowTypes': <String>['japanese_restaurant'],                                     'nameKeywords': <String>['japanese', 'japan', 'sushi', 'ramen', 'mentai', 'yakitori', 'tempura', 'udon', 'tonkatsu', 'izakaya']},
      {'key': 'malay',    'label': 'Malay',    'allowTypes': <String>['malaysian_restaurant'],                                    'nameKeywords': <String>['nasi', 'mee', 'laksa', 'satay', 'rendang', 'malay', 'restoran', 'warung', 'lemak', 'kampung', 'sup', 'ayam', 'ikan bakar']},
      {'key': 'indian',   'label': 'Indian',   'allowTypes': <String>['indian_restaurant'],                                       'nameKeywords': <String>['indian', 'india', 'naan', 'curry', 'briyani', 'biryani', 'tandoor', 'mamak', 'kandar', 'roti canai', 'chapati', 'banana leaf', 'thali']},
      {'key': 'western',  'label': 'Western',  'allowTypes': <String>['western_restaurant', 'american_restaurant', 'steak_house'],'nameKeywords': <String>['western', 'steak', 'burger', 'pizza', 'pasta', 'grill', 'bbq', 'cafe', 'bistro', 'secret recipe', 'mcdonalds', 'kfc', 'subway']},
      {'key': 'dessert',  'label': 'Dessert',  'allowTypes': <String>['dessert_shop', 'ice_cream_shop', 'bakery'],                'nameKeywords': <String>['dessert', 'ice cream', 'gelato', 'cake', 'bakery', 'pastry', 'sweet', 'bubble tea', 'boba', 'cendol', 'waffle', 'crepe']},
      {'key': 'cafe',     'label': 'Cafe',     'allowTypes': <String>['cafe', 'coffee_shop'],                                     'nameKeywords': <String>['cafe', 'coffee', 'kopitiam', 'kopi', 'espresso', 'latte', 'brew', 'roast']},
    ],
    'tourist_attraction': [
      {'key': 'all',      'label': 'All',      'allowTypes': <String>[],                                                    'nameKeywords': <String>[]},
      {'key': 'museum',   'label': 'Museum',   'allowTypes': <String>['museum', 'art_gallery'],                             'nameKeywords': <String>['museum', 'gallery', 'muzium']},
      {'key': 'park',     'label': 'Park',     'allowTypes': <String>['park', 'national_park', 'botanical_garden'],         'nameKeywords': <String>['park', 'taman', 'garden', 'hutan']},
      {'key': 'historic', 'label': 'Historic', 'allowTypes': <String>['historical_landmark', 'cultural_landmark', 'monument'], 'nameKeywords': <String>['heritage', 'historic', 'monument', 'memorial', 'fort', 'old']},
      {'key': 'temple',   'label': 'Temple',   'allowTypes': <String>['hindu_temple', 'buddhist_temple', 'shrine'],         'nameKeywords': <String>['temple', 'tokong', 'kuil', 'shrine', '庙', '寺']},
      {'key': 'mosque',   'label': 'Mosque',   'allowTypes': <String>['mosque'],                                            'nameKeywords': <String>['mosque', 'masjid', 'surau']},
      {'key': 'church',   'label': 'Church',   'allowTypes': <String>['church'],                                            'nameKeywords': <String>['church', 'gereja', 'cathedral', 'chapel']},
    ],
    'shopping_mall': [
      {'key': 'all',         'label': 'All',         'allowTypes': <String>[],                                           'nameKeywords': <String>[]},
      {'key': 'mall',        'label': 'Mall',        'allowTypes': <String>['shopping_mall'],                            'nameKeywords': <String>['mall', 'plaza', 'square', 'kompleks']},
      {'key': 'fashion',     'label': 'Clothing',    'allowTypes': <String>['clothing_store', 'shoe_store'],             'nameKeywords': <String>['fashion', 'clothing', 'apparel', 'boutique', 'shoe']},
      {'key': 'electronics', 'label': 'Electronics', 'allowTypes': <String>['electronics_store', 'cell_phone_store'],    'nameKeywords': <String>['electronics', 'electrical', 'phone', 'computer', 'digital']},
      {'key': 'supermarket', 'label': 'Supermarket', 'allowTypes': <String>['supermarket', 'grocery_store'],             'nameKeywords': <String>['supermarket', 'grocery', 'mydin', 'aeon', 'tesco', 'giant', 'econsave']},
    ],
    'amusement_park': [
      {'key': 'all',     'label': 'All',     'allowTypes': <String>[],                'nameKeywords': <String>[]},
      {'key': 'karaoke', 'label': 'Karaoke', 'allowTypes': <String>['karaoke'],       'nameKeywords': <String>['karaoke', 'neway', 'redsun', 'red box']},
      {'key': 'bowling', 'label': 'Bowling', 'allowTypes': <String>['bowling_alley'], 'nameKeywords': <String>['bowling']},
      {'key': 'cinema',  'label': 'Cinema',  'allowTypes': <String>['movie_theater'], 'nameKeywords': <String>['cinema', 'gsc', 'tgv', 'mbo', 'movie', 'theatre']},
    ],
    'park': [
      {'key': 'all',    'label': 'All',          'allowTypes': <String>[],                                 'nameKeywords': <String>[]},
      {'key': 'park',   'label': 'Park',          'allowTypes': <String>['park'],                          'nameKeywords': <String>['park', 'taman']},
      {'key': 'garden', 'label': 'Garden',        'allowTypes': <String>['botanical_garden'],              'nameKeywords': <String>['garden', 'botanical', 'taman bunga']},
      {'key': 'beach',  'label': 'Beach',         'allowTypes': <String>['beach'],                         'nameKeywords': <String>['beach', 'pantai']},
      {'key': 'trail',  'label': 'Trail/Hiking',  'allowTypes': <String>['hiking_area', 'national_park'],  'nameKeywords': <String>['trail', 'hiking', 'bukit', 'hill', 'forest', 'hutan']},
    ],
  };

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

    @override
    void dispose() {
      _searchController.dispose();
      _searchFocus.dispose();
      _debounce?.cancel();
      super.dispose();
    }

  // ─────────────────────────────────────────────
  // Bootstrap
  // ─────────────────────────────────────────────

  Future<void> _bootstrap() async {
    setState(() => _isLoading = true);

    if (widget.landmarkLat != null && widget.landmarkLng != null) {
      _currentPosition = Position(
        latitude: widget.landmarkLat!, longitude: widget.landmarkLng!,
        timestamp: DateTime.now(), accuracy: 1, altitude: 0,
        heading: 0, speed: 0, speedAccuracy: 0,
        altitudeAccuracy: 0.0, headingAccuracy: 0.0,
      );
    } else {
      try {
        await LocationService.instance.initLocation();
        final pos = LocationService.instance.currentPosition;
        if (pos == null) { _showErrorDialog('Error', 'Cannot get location'); return; }
        _currentPosition = pos;
      } catch (e) {
        _showErrorDialog('Location Error', e.toString()); return;
      }
    }

    _initialCameraPosition = CameraPosition(
      target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      zoom: 14,
    );

    _markers.add(Marker(
      markerId: const MarkerId('me'),
      position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      infoWindow: const InfoWindow(title: 'My Location'),
    ));

    setState(() {});

    try {
      await NearbyPlacesService.instance.loadNearbyPlacesOnce(categories, context);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
      return;
    }

    _applyFilter();
  }

  // ═══════════════════════════════════════════════════════════════
// 3. 新增 search 相关方法
// ═══════════════════════════════════════════════════════════════
 
  // 用户输入时触发，防抖 400ms
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _autocompleteSuggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final suggestions = await PlacesApiService.autocomplete(
        input: value,
        lat: _currentPosition?.latitude,
        lng: _currentPosition?.longitude,
      );
      if (mounted) setState(() => _autocompleteSuggestions = suggestions);
    });
  }
 
  // 用户选了一个 suggestion
  Future<void> _onSuggestionSelected(Map<String, dynamic> suggestion) async {
    _searchFocus.unfocus();
    setState(() {
      _isSearchMode    = false;
      _isSearchLoading = true;
      _autocompleteSuggestions = [];
      _searchController.text = suggestion['mainText'] ?? '';
    });
 
    // 拿坐标
    final detail = await PlacesApiService.getPlaceLatLng(suggestion['placeId']);
    if (detail == null || detail['lat'] == null) {
      setState(() => _isSearchLoading = false);
      return;
    }
 
    final lat  = detail['lat'] as double;
    final lng  = detail['lng'] as double;
    final name = detail['name'] as String;

    _currentPosition = Position(
      latitude: lat, longitude: lng,
      timestamp: DateTime.now(), accuracy: 1, altitude: 0,
      heading: 0, speed: 0, speedAccuracy: 0,
      altitudeAccuracy: 0.0, headingAccuracy: 0.0,
    );
 
    // 地图移到搜索的地点
    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lng), 14));
 
    try {
      final places = await NearbyPlacesService.instance.loadNearbyPlacesAt(
        lat: lat,
        lng: lng,
        categories: categories,
        context: context,
      );
 
      if (!mounted) return;
 
      setState(() {
        _isSearchLoading    = false;
        _searchLocationName = name;  // ← 切换到 search mode
        _searchPlaces       = places; // ← 存进 search places
 
        // 加一个 pin 在搜索的地点
        _markers.removeWhere((m) => m.markerId.value == 'search_location');
        _markers.add(Marker(
          markerId: const MarkerId('search_location'),
          position: LatLng(lat, lng),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          infoWindow: InfoWindow(title: name),
        ));
      });
 
      // _applyFilter 会自动用 _searchPlaces（因为 _searchLocationName != null）
      _applyFilter();
 
    } catch (e) {
      setState(() => _isSearchLoading = false);
    }
  }
 
  // 清除 search，回到用户当前位置
  void _clearSearch() {
    final realPos = LocationService.instance.currentPosition;
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() {
      if (realPos != null) _currentPosition = realPos;
      _isSearchMode        = false;
      _isSearchLoading     = false;
      _searchLocationName  = null;  // ← 回到 realtime mode
      _searchPlaces        = [];    // ← 清空 search places
      _autocompleteSuggestions = [];
    });
 
    // _applyFilter 会自动用 NearbyPlacesService cache（因为 _searchLocationName == null）
    _applyFilter();
 
    // 地图回到用户位置
    if (_currentPosition != null) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude), 14,
      ));
    }
  
  }
 

  // ─────────────────────────────────────────────
  // Filter
  // ─────────────────────────────────────────────

   void _applyFilter() {
    // ── 决定数据来源 ──
    // search mode 用 _searchPlaces，realtime 用 NearbyPlacesService cache
    final List<PlaceModel> sourcePlaces = _searchLocationName != null
        ? _searchPlaces
        : _getRealtimePlaces();
 
    // ── secondary filter（category）──
    List<PlaceModel> places;
    if (_selectedPrimary == null || _selectedSecondary == 'all' && _selectedPrimary == null) {
      places = sourcePlaces;
    } else if (_selectedSecondary == 'all') {
      places = sourcePlaces
          .where((p) => p.primaryType == _selectedPrimary)
          .toList();
    } else {
      final subs = subCategories[_selectedPrimary] ?? [];
      final cfg = subs.firstWhere(
        (e) => e['key'] == _selectedSecondary,
        orElse: () => {'allowTypes': <String>[], 'nameKeywords': <String>[]},
      );
      final allowTypes   = (cfg['allowTypes']   as List?)?.cast<String>() ?? [];
      final nameKeywords = (cfg['nameKeywords'] as List?)?.cast<String>() ?? [];
 
      places = sourcePlaces.where((place) {
        if (_selectedPrimary != null && place.primaryType != _selectedPrimary) return false;
        if (allowTypes.isEmpty && nameKeywords.isEmpty) return true;
        final name      = place.name.toLowerCase();
        final typeMatch = allowTypes.isNotEmpty && place.allTypes.any((t) => allowTypes.contains(t));
        final nameMatch = nameKeywords.isNotEmpty && nameKeywords.any((k) => name.contains(k.toLowerCase()));
        return typeMatch || nameMatch;
      }).toList();
    }
 
    setState(() {
      _isLoading = false;
      _displayedPlaces.clear();
      _markers.removeWhere((m) =>
          m.markerId.value != 'me' && m.markerId.value != 'search_location');
      _routeResults.clear();
      for (final place in places) {
        _addMarkerAndPlace(place);
      }
    });
 
    _animateToFitMarkers(keepZoom: true);
  }
 
  // realtime 模式从 NearbyPlacesService 拿
  List<PlaceModel> _getRealtimePlaces() {
  if (_selectedPrimary == null) {
      return NearbyPlacesService.instance.getByPrimary(null);
    } else if (_selectedSecondary == 'all') {
      return NearbyPlacesService.instance.getByPrimary(_selectedPrimary);
    } else {
      final subs = subCategories[_selectedPrimary] ?? [];
      final cfg = subs.firstWhere(
        (e) => e['key'] == _selectedSecondary,
        orElse: () => {'allowTypes': <String>[], 'nameKeywords': <String>[]},
      );
      return NearbyPlacesService.instance.getBySecondary(
        primary: _selectedPrimary!,
        secondary: _selectedSecondary,
        allowTypes: (cfg['allowTypes'] as List?)?.cast<String>() ?? [],
        nameKeywords: (cfg['nameKeywords'] as List?)?.cast<String>() ?? [],
      );
    }
  }

  void _onPrimaryTap(String type) {
    setState(() {
      _selectedPrimary   = type == 'all' ? null : type;
      _selectedSecondary = 'all';
    });
    _applyFilter();
  }

  void _onSecondaryTap(String key) {
    setState(() => _selectedSecondary = key);
    _applyFilter();
  }

  Future<void> _onRefresh() async {
    NearbyPlacesService.instance.clearCache();
    setState(() { _selectedPrimary = null; _selectedSecondary = 'all'; _isLoading = true; });
    try {
      await NearbyPlacesService.instance.loadNearbyPlacesOnce(categories, context);
    } catch (e) {
      setState(() => _isLoading = false);
      return;
    }
    _applyFilter();
  }

  // ─────────────────────────────────────────────
  // ✅ Toggle place selection
  // ─────────────────────────────────────────────

  void _togglePlaceSelection(PlaceModel place) {
    setState(() {
      if (_selectedPlaceIds.contains(place.id)) {
        _selectedPlaceIds.remove(place.id);
      } else {
        _selectedPlaceIds.add(place.id);
      }
    });
  }

  // ─────────────────────────────────────────────
  // ✅ View selected → push to ItineraryDetailPage
  // ─────────────────────────────────────────────

  void _viewSelectedItinerary() {
    if (_selectedPlaceIds.isEmpty) return;

    // 按距离排序
    final selectedPlaces = _displayedPlaces
        .where((p) => _selectedPlaceIds.contains(p.id))
        .toList()
      ..sort((a, b) {
        final aD = _routeResults[a.id]?.distanceMeters ?? double.infinity;
        final bD = _routeResults[b.id]?.distanceMeters ?? double.infinity;
        return aD.compareTo(bD);
      });

    // 从 09:00 开始自动排时间
    final now       = DateTime.now();
    final dateStr   = DateFormat('yyyy-MM-dd').format(now);
    var curHour     = 9;
    var curMin      = 0;

    final itineraryPlaces = selectedPlaces.map((p) {
      final timeStr  = '${curHour.toString().padLeft(2, '0')}:${curMin.toString().padLeft(2, '0')}';
      final duration = p.primaryType == 'restaurant' ? 60 : 90;

      curMin  += duration;
      curHour += curMin ~/ 60;
      curMin   = curMin % 60;
      if (curHour >= 21) { curHour = 21; curMin = 0; }

      return ItineraryPlace(
        placeId:         p.id,
        name:            p.name,
        address:         p.address ?? '',
        photoUrl:        p.photoUrl,
        lat:             p.lat,
        lng:             p.lng,
        primaryType:     p.primaryType,
        suggestedTime:   timeStr,
        durationMinutes: duration,
        notes:           'Added by you',
      );
    }).toList();

    final itinerary = ItineraryModel(
      id:        '',
      title:     'My Custom Trip',
      startDate: dateStr,
      totalDays: 1,
      days: [ItineraryDay(dayNumber: 1, date: dateStr, places: itineraryPlaces)],
      createdAt: now,
    );

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItineraryDetailPage(itinerary: itinerary)),
    );
  }

  // ─────────────────────────────────────────────
  // Markers & Routes
  // ─────────────────────────────────────────────

  void _addMarkerAndPlace(PlaceModel place) {
    if (place.lat == null || place.lng == null) return;

    final markerId = MarkerId(place.id);
    if (!_markers.any((m) => m.markerId == markerId)) {
      _markers.add(Marker(
        markerId: markerId,
        position: LatLng(place.lat!, place.lng!),
        infoWindow: InfoWindow(title: place.name, snippet: place.address, onTap: () => _showPlaceDetails(place)),
        onTap: () => _showPlaceDetails(place),
      ));
    }

    if (!_displayedPlaces.any((p) => p.id == place.id)) _displayedPlaces.add(place);

    if (_currentPosition != null) {
      final dist = Geolocator.distanceBetween(
        _currentPosition!.latitude, _currentPosition!.longitude,
        place.lat!, place.lng!,
      );
      _routeResults[place.id] = RouteResult(
        polylinePoints: [],
        bounds: LatLngBounds(
          southwest: LatLng(min(_currentPosition!.latitude, place.lat!), min(_currentPosition!.longitude, place.lng!)),
          northeast: LatLng(max(_currentPosition!.latitude, place.lat!), max(_currentPosition!.longitude, place.lng!)),
        ),
        distanceMeters: dist,
        durationSeconds: (dist / _getSpeedMeterPerSecond()).round(),
      );
    }
  }

  double _getSpeedMeterPerSecond() {
    switch (_travelMode) {
      case TravelMode.walk:  return 1.4;
      case TravelMode.motor: return 6.0;
      case TravelMode.drive: return 12.0;
    }
  }

  void _updateRouteTimesForTravelMode() {
    if (_currentPosition == null) return;
    for (final place in _displayedPlaces) {
      final route = _routeResults[place.id];
      if (route == null) continue;
      _routeResults[place.id] = RouteResult(
        polylinePoints: route.polylinePoints,
        bounds: route.bounds,
        distanceMeters: route.distanceMeters,
        durationSeconds: (route.distanceMeters / _getSpeedMeterPerSecond()).round(),
      );
    }
  }

  void _animateToFitMarkers({bool keepZoom = false}) {
    if (_mapController == null || _markers.isEmpty) return;
    if (_markers.length == 1) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_markers.first.position, 15));
      return;
    }
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final m in _markers) {
      if (m.position.latitude  < minLat) minLat = m.position.latitude;
      if (m.position.latitude  > maxLat) maxLat = m.position.latitude;
      if (m.position.longitude < minLng) minLng = m.position.longitude;
      if (m.position.longitude > maxLng) maxLng = m.position.longitude;
    }
    final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    if (keepZoom) {
      _mapController!.animateCamera(CameraUpdate.newLatLng(center));
    } else {
      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 80,
      ));
    }
  }

  // ─────────────────────────────────────────────
  // Navigation
  // ─────────────────────────────────────────────

  Future<void> _navigateTo(PlaceModel place) async {
    if (_currentPosition == null) return;
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => RoutePreviewPage(
        startLat: _currentPosition!.latitude, startLng: _currentPosition!.longitude,
        endLat: place.lat!, endLng: place.lng!, destinationName: place.name,
      ),
    ));
  }

  // ─────────────────────────────────────────────
  // UI Helpers
  // ─────────────────────────────────────────────

  void _showErrorDialog(String title, String message) {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: Text(title), content: Text(message),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ));
  }

  void _showPlaceDetails(PlaceModel place) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.42,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
          ),
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 48, height: 5,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)))),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(place.name,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis)),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    if (place.rating != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                        child: Row(children: [
                          const Icon(Icons.star_rounded, color: Colors.orange, size: 20),
                          const SizedBox(width: 2),
                          Text(place.rating.toString(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
                        ]),
                      ),
                    const SizedBox(width: 4),
                    FavouriteButton(
                      placeId: place.id, name: place.name, address: place.address ?? '',
                      rating: place.rating?.toDouble(), photoUrl: place.photoUrl,
                      lat: place.lat, lng: place.lng,
                      showBackground: false, iconSize: 24,
                      activeColor: Colors.red, inactiveColor: Colors.grey,
                    ),
                  ]),
                ],
              ),
              const SizedBox(height: 12),
              Row(children: [
                Icon(Icons.location_on_rounded, size: 18, color: Theme.of(context).primaryColor),
                const SizedBox(width: 6),
                Expanded(child: Text(place.address ?? 'Unknown address',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14))),
              ]),
              const SizedBox(height: 16),
              if (_routeResults[place.id] != null)
                Wrap(spacing: 12, children: [
                  _buildInfoChip(Icons.directions_car_filled_rounded,
                      '${(_routeResults[place.id]!.distanceMeters / 1000).toStringAsFixed(1)} km', Colors.blue),
                  _buildInfoChip(Icons.access_time_filled_rounded,
                      '${(_routeResults[place.id]!.durationSeconds ~/ 60)} min', Colors.teal),
                ]),
              const Spacer(),
              Row(children: [
                Expanded(flex: 2, child: OutlinedButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await Navigator.push(context, MaterialPageRoute(
                      builder: (_) => PlaceDetailPage(
                        placeId: place.id, lat: place.lat, lng: place.lng,
                        userLat: _currentPosition?.latitude, userLng: _currentPosition?.longitude,
                      ),
                    ));
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: BorderSide(color: Colors.grey[300]!),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('Details', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w600)),
                )),
                const SizedBox(width: 12),
                Expanded(flex: 3, child: ElevatedButton.icon(
                  onPressed: () { Navigator.of(context).pop(); _navigateTo(place); },
                  icon: const Icon(Icons.near_me_rounded, color: Colors.white),
                  label: const Text('Navigate', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                )),
              ]),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  final ValueNotifier<double> _bottomPaddingNotifier = ValueNotifier(0.4);

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    final List<PlaceModel> sortedPlaces = List.from(_displayedPlaces);
    sortedPlaces.sort((a, b) {
      if (_sortMode == SortMode.distance) {
        final aD = _routeResults[a.id]?.distanceMeters ?? double.infinity;
        final bD = _routeResults[b.id]?.distanceMeters ?? double.infinity;
        return aD.compareTo(bD);
      } else {
        return (b.rating ?? 0.0).compareTo(a.rating ?? 0.0);
      }
    });

    if (_initialCameraPosition == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── Map ──
          ValueListenableBuilder<double>(
            valueListenable: _bottomPaddingNotifier,
            builder: (context, extent, _) {
              return GoogleMap(
                initialCameraPosition: _initialCameraPosition!,
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                markers: _markers,
                onMapCreated: (c) => _mapController = c,
                padding: EdgeInsets.only(bottom: screenHeight * extent, top: 60),
              );
            },
          ),

                // ── Search bar + Back button ──
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  children: [
                    // Search row
                    Row(children: [
                      // Back button
                      Material(
                        elevation: 4, shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias, color: Colors.white,
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Colors.black87),
                          onPressed: _isSearchMode ? () {
                            setState(() { _isSearchMode = false; _autocompleteSuggestions = []; });
                            _searchFocus.unfocus();
                          } : widget.onBack,
                        ),
                      ),
                      const SizedBox(width: 8),
 
                      // Search field
                      Expanded(
                        child: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(28),
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocus,
                            onChanged: _onSearchChanged,
                            onTap: () => setState(() => _isSearchMode = true),
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                              hintText: _searchLocationName != null
                                  ? 'Near: $_searchLocationName'
                                  : 'Search a place...',
                              hintStyle: TextStyle(
                                color: _searchLocationName != null
                                    ? const Color(0xFF1A73E8)
                                    : Colors.grey[400],
                                fontSize: 14,
                              ),
                              prefixIcon: const Icon(Icons.search_rounded, color: Colors.grey, size: 20),
                              suffixIcon: _searchController.text.isNotEmpty || _searchLocationName != null
                                  ? IconButton(
                                      icon: const Icon(Icons.close_rounded, size: 18, color: Colors.grey),
                                      onPressed: _clearSearch,
                                    )
                                  : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(28),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                          ),
                        ),
                      ),
 
                      // Refresh button
                      const SizedBox(width: 8),
                      Material(
                        elevation: 4, shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias, color: Colors.white,
                        child: IconButton(
                          icon: const Icon(Icons.refresh_rounded, size: 18, color: Colors.black87),
                          onPressed: _isLoading ? null : _onRefresh,
                        ),
                      ),
                    ]),
 
                    // Autocomplete dropdown
                    if (_isSearchMode && _autocompleteSuggestions.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 4, left: 44, right: 44),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 12, offset: const Offset(0, 4),
                          )],
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _autocompleteSuggestions.length.clamp(0, 5),
                          separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
                          itemBuilder: (context, index) {
                            final s = _autocompleteSuggestions[index];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.location_on_outlined, color: Color(0xFF1A73E8), size: 20),
                              title: Text(s['mainText'] ?? '',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                              subtitle: Text(s['secondaryText'] ?? '',
                                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => _onSuggestionSelected(s),
                            );
                          },
                        ),
                      ),
 
                    // Loading indicator
                    if (_isSearchLoading)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)],
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1A73E8))),
                          SizedBox(width: 10),
                          Text('Searching nearby...', style: TextStyle(fontSize: 13, color: Colors.black54)),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // // ── Refresh button ──
          // Positioned(
          //   top: 50, right: 20,
          //   child: SafeArea(child: Material(
          //     elevation: 4, shape: const CircleBorder(), clipBehavior: Clip.antiAlias, color: Colors.white,
          //     child: IconButton(
          //       icon: const Icon(Icons.refresh_rounded, size: 20, color: Colors.black87),
          //       onPressed: _isLoading ? null : _onRefresh,
          //     ),
          //   )),
          // ),

          // ── Bottom sheet ──
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (n) { _bottomPaddingNotifier.value = n.extent; return false; },
            child: DraggableScrollableSheet(
              key: const PageStorageKey('gotrip_sheet_unique'),
              initialChildSize: 0.4, minChildSize: 0.2, maxChildSize: 0.85,
              snap: true,
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 15)],
                  ),
                  child: _buildPlaceListSheet(scrollController, sortedPlaces),
                );
              },
            ),
          ),

          // ✅ Floating "View Itinerary (N)" button
          if (_selectedPlaceIds.isNotEmpty)
            Positioned(
              bottom: 24 + MediaQuery.of(context).padding.bottom,
              left: 24, right: 24,
              child: GestureDetector(
                onTap: _viewSelectedItinerary,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(
                      color: const Color(0xFF7C4DFF).withOpacity(0.4),
                      blurRadius: 16, offset: const Offset(0, 8),
                    )],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.map_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        'View Itinerary (${_selectedPlaceIds.length})',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 10),
                      const Icon(Icons.arrow_forward_rounded, color: Colors.white70, size: 18),
                    ],
                  ),
                ),
              ),
            ),

          if (_isLoading)
            const Center(child: CircularProgressIndicator(color: Colors.blueAccent)),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Place List Sheet
  // ─────────────────────────────────────────────

  Widget _buildPlaceListSheet(ScrollController scrollController, List<PlaceModel> sortedPlaces) {
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.zero,
      children: [
        Center(child: Column(children: [
          const SizedBox(height: 8),
          Container(width: 45, height: 5,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10))),
          const SizedBox(height: 4),
        ])),

        // Primary categories
        SizedBox(
          height: 95,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final cat = categories[index];
              final isSelected = cat['type'] == 'all' ? _selectedPrimary == null : _selectedPrimary == cat['type'];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => _onPrimaryTap(cat['type']),
                  child: Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected ? cat['color'] : Colors.grey[100],
                        shape: BoxShape.circle,
                      ),
                      child: Icon(cat['icon'], color: isSelected ? Colors.white : Colors.grey[600], size: 26),
                    ),
                    const SizedBox(height: 6),
                    Text(cat['name'], style: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? cat['color'] : Colors.grey[700],
                    )),
                  ]),
                ),
              );
            },
          ),
        ),

        const Divider(height: 1, thickness: 0.5),

        // Travel mode
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Text("Travel By:", style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                GestureDetector(
                  onTap: () => setState(() => _isTravelModeExpanded = !_isTravelModeExpanded),
                  child: Row(children: [
                    Icon(_getTravelIcon(_travelMode), color: Colors.blue[800], size: 20),
                    Icon(_isTravelModeExpanded ? Icons.arrow_left : Icons.arrow_drop_down, color: Colors.blue[800]),
                  ]),
                ),
                if (_isTravelModeExpanded) Row(children: [
                  const VerticalDivider(width: 16),
                  _buildMiniIcon(TravelMode.walk, Icons.directions_walk),
                  _buildMiniIcon(TravelMode.motor, Icons.motorcycle),
                  _buildMiniIcon(TravelMode.drive, Icons.directions_car),
                ]),
              ]),
            ),
          ]),
        ),

        // Sort + selected count
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            _buildStyledFilterChip(
              label: "Nearest", isSelected: _sortMode == SortMode.distance,
              onTap: () => setState(() => _sortMode = SortMode.distance),
              icon: Icons.near_me_outlined,
            ),
            const SizedBox(width: 8),
            _buildStyledFilterChip(
              label: "High Rated", isSelected: _sortMode == SortMode.rating,
              onTap: () => setState(() => _sortMode = SortMode.rating),
              icon: Icons.star_outline_rounded,
            ),
            // ✅ Selected count badge
            if (_selectedPlaceIds.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF7C4DFF)),
                  const SizedBox(width: 4),
                  Text('${_selectedPlaceIds.length} selected',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF7C4DFF), fontWeight: FontWeight.w600)),
                ]),
              ),
            ],
          ]),
        ),

        if (_selectedPrimary != null && subCategories.containsKey(_selectedPrimary))
          _buildSecondaryBar(),

        const Divider(height: 1, thickness: 0.5),

        if (_displayedPlaces.isEmpty && !_isLoading)
          SizedBox(height: 300, child: _buildEmptyState())
        else
          ...List.generate(sortedPlaces.length, (index) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildPlaceCard(sortedPlaces[index]),
          )),

        // Extra padding when floating button is visible
        SizedBox(height: _selectedPlaceIds.isNotEmpty
            ? 100 + MediaQuery.of(context).padding.bottom
            : 24 + MediaQuery.of(context).padding.bottom + kBottomNavigationBarHeight),
      ],
    );
  }

  // ─────────────────────────────────────────────
  // ✅ Place Card with + / ✅ button
  // ─────────────────────────────────────────────

  Widget _buildPlaceCard(PlaceModel place) {
    final routeInfo  = _routeResults[place.id];
    final isSelected = _selectedPlaceIds.contains(place.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _showPlaceDetails(place),
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF7C4DFF).withOpacity(0.05) : Colors.white,
            borderRadius: BorderRadius.circular(15),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
            border: Border.all(
              color: isSelected ? const Color(0xFF7C4DFF).withOpacity(0.4) : Colors.grey[100]!,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Photo
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.blue[50]),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: place.photoUrl != null
                      ? Image.network(place.photoUrl!, fit: BoxFit.cover,
                          errorBuilder: (c, e, s) => const Icon(Icons.image_not_supported, size: 20))
                      : Icon(Icons.location_on, color: Colors.blue[400], size: 24),
                ),
              ),
              const SizedBox(width: 12),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(place.name,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Row(children: [
                      if (place.rating != null) ...[
                        const Icon(Icons.star_rounded, color: Colors.orange, size: 16),
                        const SizedBox(width: 2),
                        Text(place.rating.toString(),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.orange)),
                        _buildDotSeparator(),
                      ],
                      if (routeInfo != null) ...[
                        Icon(Icons.near_me_rounded, size: 13, color: Colors.blue[400]),
                        const SizedBox(width: 3),
                        Text('${(routeInfo.distanceMeters / 1000).toStringAsFixed(1)} km',
                            style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                        _buildDotSeparator(),
                        Icon(Icons.access_time_filled_rounded, size: 13, color: Colors.grey[400]),
                        const SizedBox(width: 3),
                        Text('${routeInfo.durationSeconds ~/ 60} min',
                            style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                      ],
                    ]),
                  ],
                ),
              ),

              // ✅ + / ✅ toggle button
              GestureDetector(
                onTap: () => _togglePlaceSelection(place),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF7C4DFF) : Colors.grey[100],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isSelected ? Icons.check_rounded : Icons.add_rounded,
                    color: isSelected ? Colors.white : Colors.grey[600],
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDotSeparator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text('•', style: TextStyle(color: Colors.grey[300], fontWeight: FontWeight.bold, fontSize: 14)),
    );
  }

  Widget _buildMiniIcon(TravelMode mode, IconData icon) {
    final isSelected = _travelMode == mode;
    return GestureDetector(
      onTap: () => setState(() { _travelMode = mode; _isTravelModeExpanded = false; _updateRouteTimesForTravelMode(); }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        margin: const EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[200] : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 18, color: isSelected ? Colors.blue[900] : Colors.blue[400]),
      ),
    );
  }

  IconData _getTravelIcon(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk:  return Icons.directions_walk;
      case TravelMode.motor: return Icons.motorcycle;
      case TravelMode.drive: return Icons.directions_car;
    }
  }

  Widget _buildSecondaryBar() {
    final subs = subCategories[_selectedPrimary] ?? [];
    return Container(
      height: 40,
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: subs.length,
        itemBuilder: (context, index) {
          final item = subs[index];
          final key  = item['key'] as String;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildStyledFilterChip(
              label: item['label'] as String,
              isSelected: _selectedSecondary == key,
              onTap: () => _onSecondaryTap(key),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStyledFilterChip({required String label, required bool isSelected, required VoidCallback onTap, IconData? icon}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[600] : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? Colors.blue[600]! : Colors.grey[200]!, width: 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 16, color: isSelected ? Colors.white : Colors.grey[600]), const SizedBox(width: 4)],
          Text(label, style: TextStyle(
            fontSize: 13, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected ? Colors.white : Colors.grey[700],
          )),
        ]),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.search_off, size: 48, color: Colors.grey),
      const SizedBox(height: 12),
      const Text('No places found nearby', style: TextStyle(fontSize: 16, color: Colors.grey)),
      const SizedBox(height: 12),
      ElevatedButton(
        onPressed: () { setState(() { _selectedPrimary = null; _selectedSecondary = 'all'; }); _applyFilter(); },
        child: const Text('Show All'),
      ),
    ]));
  }
}