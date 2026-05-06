import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'placeDetailPage.dart';
import '../../services/route_service.dart';
import '../../services/location_service.dart';
import '../../models/placeModal.dart';
import '../../services/nearbyPlace_service.dart'; 
import '../../models/itineraryModel.dart';
import '../../modules/itinerary/itineraryDetail.dart';
import 'routePreviewPage.dart';
import '../../services/placesAPI_service.dart';
import 'favouriteButton.dart';
import '../../services/itinerary_service.dart';

enum SortMode { distance, rating } 

class RealTimeDetectPage extends StatefulWidget {
  final double? landmarkLat;
  final double? landmarkLng;
  final VoidCallback onBack;
  final bool autoFocusSearch; 

  const RealTimeDetectPage({
    super.key,
    this.landmarkLat,
    this.landmarkLng,
    required this.onBack,
    this.autoFocusSearch = false,
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

  final List<PlaceModel> _displayedPlaces = []; // for real time place
  List<PlaceModel> _landmarkPlaces = []; // for landmark mode, not affecting singleton 
  Map<String, RouteResult> _routeResults = {};
  bool _isLoading = false;

  String? _selectedPrimary;
  String _selectedSecondary = 'all';

  CameraPosition? _initialCameraPosition;

  // Search
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<Map<String, dynamic>> _autocompleteSuggestions = []; //for autocomplete dropdown results
  bool _isSearchMode = false;     
  bool _isSearchLoading = false;
  String? _searchLocationName;      
  Timer? _debounce; // prevent api spam

  final Set<String> _selectedPlaceIds = {};
  final Map<String, PlaceModel> _selectedPlacesMap = {}; 
  List<PlaceModel> _searchPlaces = [];
  

  final List<Map<String, dynamic>> categories = [
    {'name': 'All',        'icon': Icons.all_inclusive,          'type': 'all',           'color': Colors.black},
    {'name': 'Food',       'icon': Icons.restaurant,             'type': 'restaurant',    'color': Colors.orange},
    {'name': 'Nature',     'icon': Icons.park,                   'type': 'park',          'color': Colors.green},
    {'name': 'Entertain',  'icon': Icons.local_activity_rounded, 'type': 'entertainment', 'color': Colors.deepPurple},
    {'name': 'Shopping',   'icon': Icons.shopping_bag,           'type': 'shopping_mall', 'color': Colors.pink},
    {'name': 'Transport',  'icon': Icons.directions_transit,     'type': 'transit',       'color': Colors.blue},
    {'name': 'Service',    'icon': Icons.miscellaneous_services, 'type': 'service',       'color': Colors.teal},
  ];

  final Map<String, List<Map<String, dynamic>>> subCategories = {

    // ── Food ──────────────────────────────────────────────────────────────────
    'restaurant': [
      {'key': 'all',      'label': 'All',      'allowTypes': <String>[],                                                            'nameKeywords': <String>[]},
      {'key': 'korean',   'label': 'Korean',   'allowTypes': <String>['korean_restaurant'],                                         'nameKeywords': <String>['korea', 'korean', '한국', 'kimchi', 'bbq korean']},
      {'key': 'chinese',  'label': 'Chinese',  'allowTypes': <String>['chinese_restaurant'],                                        'nameKeywords': <String>['chinese', 'canton', 'dim sum', 'claypot', 'clay pot', '中', '华', '粤', '龙', '金', '福', '记', 'seafood', 'wonton', 'bak kut']},
      {'key': 'japanese', 'label': 'Japanese', 'allowTypes': <String>['japanese_restaurant'],                                       'nameKeywords': <String>['japanese', 'japan', 'sushi', 'ramen', 'mentai', 'yakitori', 'tempura', 'udon', 'tonkatsu', 'izakaya']},
      {'key': 'malay',    'label': 'Malay',    'allowTypes': <String>['malaysian_restaurant'],                                      'nameKeywords': <String>['nasi', 'mee', 'laksa', 'satay', 'rendang', 'malay', 'restoran', 'warung', 'lemak', 'kampung', 'sup', 'ayam', 'ikan bakar']},
      {'key': 'indian',   'label': 'Indian',   'allowTypes': <String>['indian_restaurant'],                                         'nameKeywords': <String>['indian', 'india', 'naan', 'curry', 'briyani', 'biryani', 'tandoor', 'mamak', 'kandar', 'roti canai', 'banana leaf', 'thali']},
      {'key': 'western',  'label': 'Western',  'allowTypes': <String>['western_restaurant', 'american_restaurant', 'steak_house'],  'nameKeywords': <String>['western', 'steak', 'burger', 'pizza', 'pasta', 'grill', 'bistro', 'secret recipe', 'mcdonalds', 'kfc', 'subway']},
      {'key': 'dessert',  'label': 'Dessert',  'allowTypes': <String>['dessert_shop', 'ice_cream_shop', 'bakery'],                  'nameKeywords': <String>['dessert', 'ice cream', 'gelato', 'cake', 'bakery', 'pastry', 'sweet', 'bubble tea', 'boba', 'cendol', 'waffle', 'crepe']},
      {'key': 'cafe',     'label': 'Cafe',     'allowTypes': <String>['cafe', 'coffee_shop'],                                       'nameKeywords': <String>['cafe', 'coffee', 'kopitiam', 'kopi', 'espresso', 'latte', 'brew', 'roast']},
    ],

    // ── Nature ────────────────────────────────────────────────────────────────
    'park': [
      {'key': 'all',      'label': 'All',       'allowTypes': <String>[],                                                                               'nameKeywords': <String>[]},
      {'key': 'park',     'label': 'Park',       'allowTypes': <String>['park', 'national_park'],                                                        'nameKeywords': <String>['park', 'taman', 'recreational']},
      {'key': 'garden',   'label': 'Garden',     'allowTypes': <String>['botanical_garden'],                                                             'nameKeywords': <String>['garden', 'botanical', 'bunga']},
      {'key': 'beach',    'label': 'Beach',      'allowTypes': <String>['beach'],                                                                        'nameKeywords': <String>['beach', 'pantai']},
      {'key': 'trail',    'label': 'Hiking',     'allowTypes': <String>['hiking_area'],                                                                  'nameKeywords': <String>['trail', 'hiking', 'bukit', 'hill', 'forest', 'hutan']},
      {'key': 'landmark', 'label': 'Landmark',   'allowTypes': <String>['tourist_attraction', 'historical_landmark', 'cultural_landmark', 'monument'],   'nameKeywords': <String>['heritage', 'historic', 'monument', 'memorial', 'fort', 'landmark']},
      {'key': 'museum',   'label': 'Museum',     'allowTypes': <String>['museum', 'art_gallery'],                                                        'nameKeywords': <String>['museum', 'gallery', 'muzium']},
      {'key': 'temple',   'label': 'Temple',     'allowTypes': <String>['hindu_temple', 'buddhist_temple', 'shrine'],                                    'nameKeywords': <String>['temple', 'tokong', 'kuil', 'shrine', '庙', '寺']},
      {'key': 'mosque',   'label': 'Mosque',     'allowTypes': <String>['mosque'],                                                                       'nameKeywords': <String>['mosque', 'masjid', 'surau']},
      {'key': 'church',   'label': 'Church',     'allowTypes': <String>['church'],                                                                       'nameKeywords': <String>['church', 'gereja', 'cathedral', 'chapel']},
    ],

    // ── Entertainment ─────────────────────────────────────────────────────────
    'entertainment': [
      {'key': 'all',     'label': 'All',        'allowTypes': <String>[],                                                              'nameKeywords': <String>[]},
      {'key': 'cinema',  'label': 'Cinema',     'allowTypes': <String>['movie_theater'],                                               'nameKeywords': <String>['cinema', 'gsc', 'tgv', 'mbo', 'movie', 'theatre']},
      {'key': 'karaoke', 'label': 'Karaoke',    'allowTypes': <String>['karaoke'],                                                     'nameKeywords': <String>['karaoke', 'neway', 'redsun', 'red box']},
      {'key': 'bowling', 'label': 'Bowling',    'allowTypes': <String>['bowling_alley'],                                               'nameKeywords': <String>['bowling']},
      {'key': 'gaming',  'label': 'Gaming',     'allowTypes': <String>['amusement_center', 'video_arcade'],                            'nameKeywords': <String>['arcade', 'esport', 'gaming', 'lan', 'timezone']},
      {'key': 'theme',   'label': 'Theme Park', 'allowTypes': <String>['amusement_park', 'theme_park'],                               'nameKeywords': <String>['theme park', 'sunway', 'genting', 'waterpark', 'legoland']},
      {'key': 'sport',   'label': 'Sports',     'allowTypes': <String>['sports_complex', 'stadium', 'gym', 'fitness_center'],          'nameKeywords': <String>['stadium', 'sport', 'badminton', 'futsal', 'swimming', 'gym', 'fitness']},
      {'key': 'spa',     'label': 'Spa',        'allowTypes': <String>['spa', 'beauty_salon'],                                         'nameKeywords': <String>['spa', 'massage', 'wellness', 'relax', 'beauty']},
    ],

    // ── Shopping ──────────────────────────────────────────────────────────────
    'shopping_mall': [
      {'key': 'all',         'label': 'All',         'allowTypes': <String>[],                                                  'nameKeywords': <String>[]},
      {'key': 'mall',        'label': 'Mall',         'allowTypes': <String>['shopping_mall'],                                   'nameKeywords': <String>['mall', 'plaza', 'square', 'kompleks', 'pavilion', 'mid valley']},
      {'key': 'supermarket', 'label': 'Supermarket',  'allowTypes': <String>['supermarket', 'grocery_store'],                   'nameKeywords': <String>['supermarket', 'grocery', 'mydin', 'aeon', 'tesco', 'giant', 'econsave', 'jaya grocer']},
      {'key': 'fashion',     'label': 'Fashion',      'allowTypes': <String>['clothing_store', 'shoe_store'],                   'nameKeywords': <String>['fashion', 'clothing', 'apparel', 'boutique', 'shoe', 'zara', 'h&m', 'uniqlo']},
      {'key': 'electronics', 'label': 'Electronics',  'allowTypes': <String>['electronics_store', 'cell_phone_store'],          'nameKeywords': <String>['electronics', 'phone', 'computer', 'digital', 'harvey', 'senheng', 'courts']},
      {'key': 'pharmacy',    'label': 'Pharmacy',     'allowTypes': <String>['pharmacy', 'drugstore'],                          'nameKeywords': <String>['pharmacy', 'farmasi', 'guardian', 'watsons', 'caring', 'alpro']},
      {'key': 'market',      'label': 'Market',       'allowTypes': <String>['market', 'flea_market'],                          'nameKeywords': <String>['market', 'bazaar', 'pasar', 'night market', 'ramadan', 'flea']},
    ],

    // ── Transport (公共交通 only) ──────────────────────────────────────────────
    'transit': [
      {'key': 'all',     'label': 'All',       'allowTypes': <String>[],                                                                          'nameKeywords': <String>[]},
      {'key': 'lrt_mrt', 'label': 'LRT / MRT', 'allowTypes': <String>['subway_station', 'light_rail_station', 'transit_station'],                 'nameKeywords': <String>['lrt', 'mrt', 'ktm', 'monorail', 'rapidkl', 'station', 'stesen']},
      {'key': 'bus',     'label': 'Bus',        'allowTypes': <String>['bus_station', 'bus_stop'],                                                 'nameKeywords': <String>['bus', 'rapid', 'terminal', 'hentian', 'express']},
      {'key': 'taxi',    'label': 'Taxi / Grab','allowTypes': <String>['taxi_stand'],                                                              'nameKeywords': <String>['taxi', 'grab', 'cab', 'teksi']},
    ],

    // ── Service (医院 / 银行 / 邮局) ───────────────────────────────────────────
    'service': [
      {'key': 'all',      'label': 'All',        'allowTypes': <String>[],                                                         'nameKeywords': <String>[]},
      {'key': 'hospital', 'label': 'Hospital',   'allowTypes': <String>['hospital', 'medical_clinic', 'doctor'],                  'nameKeywords': <String>['hospital', 'clinic', 'klinik', 'medical', 'health', 'healthcare']},
      {'key': 'bank',     'label': 'Bank / ATM', 'allowTypes': <String>['bank', 'atm'],                                           'nameKeywords': <String>['bank', 'maybank', 'cimb', 'public bank', 'rhb', 'hong leong', 'ambank', 'atm']},
      {'key': 'post',     'label': 'Post Office','allowTypes': <String>['post_office'],                                            'nameKeywords': <String>['post office', 'pos malaysia', 'poslaju', 'pos laju']},
    ],
  };

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _bootstrap();

      _searchFocus.addListener(() {
        setState(() {}); // focus 变化时重新 build
      });
    
    if (widget.autoFocusSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _searchFocus.requestFocus();
        });
      });
    }

    LocationService.instance.addListener(_onLocationChanged);
  }

  void _onLocationChanged() {
    if (!mounted) return;
    if (_searchLocationName != null) return; // 搜尋模式下不自動 reload
    if (widget.landmarkLat != null) return; 
    _onRefresh();
  }

    @override
    void dispose() {
      LocationService.instance.removeListener(_onLocationChanged);
      _searchController.dispose();
      _searchFocus.dispose();
      _debounce?.cancel();
      super.dispose();
    }

  // Bootstrap
  // ─────────────────────────────────────────────
  Future<void> _bootstrap() async {
    if (!await _checkConnectivity()) return;
    setState(() => _isLoading = true);

    if (widget.landmarkLat != null && widget.landmarkLng != null) {
      // Landmark mode：no touch singleton
      _currentPosition = Position(
        latitude: widget.landmarkLat!,
        longitude: widget.landmarkLng!,
        timestamp: DateTime.now(), accuracy: 1, altitude: 0,
        heading: 0, speed: 0, speedAccuracy: 0,
        altitudeAccuracy: 0.0, headingAccuracy: 0.0,
      );

      _initialCameraPosition = CameraPosition(
        target: LatLng(widget.landmarkLat!, widget.landmarkLng!),
        zoom: 14,
      );

      _markers.add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(widget.landmarkLat!, widget.landmarkLng!),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'Landmark Location'),
      ));

      setState(() {});

      try {
        // store the results in _landmarkPlaces (local)
        _landmarkPlaces = await NearbyPlacesService.instance.loadNearbyPlacesAt(
          lat: widget.landmarkLat!,
          lng: widget.landmarkLng!,
          categories: categories,
          context: context,
        );
      } catch (e) {
        setState(() => _isLoading = false);
        return;
      }

    } else {
      // GPS mode, use singleton cache
      final pos = LocationService.instance.currentPosition;
      if (pos == null) { _showErrorDialog('Error', 'Cannot get location'); return; }
      _currentPosition = pos;

      _initialCameraPosition = CameraPosition(
        target: LatLng(pos.latitude, pos.longitude),
        zoom: 14,
      );

      _markers.add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(pos.latitude, pos.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'My Location'),
      ));

      setState(() {});

      try {
        await NearbyPlacesService.instance.loadNearbyPlacesOnce(
          categories, context,
        );
      } catch (e) {
        setState(() => _isLoading = false);
        return;
      }
    }

    _applyFilter();
  }
  

  // for search & refresh
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
 
  Future<void> _onSuggestionSelected(Map<String, dynamic> suggestion) async {
    if (!await _checkConnectivity()) return;
    _searchFocus.unfocus();
    setState(() {
      _isSearchMode        = false;
      _isSearchLoading     = true;
      _autocompleteSuggestions = [];
      _searchController.text = suggestion['mainText'] ?? '';
    });

    // 拿lat and lng
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
        _searchLocationName = name;
        _searchPlaces       = places;
        _selectedPlaceIds.clear();

        // marker for the searched location
        _markers.removeWhere((m) => m.markerId.value == 'search_location');
        _markers.add(Marker(
          markerId: const MarkerId('search_location'),
          position: LatLng(lat, lng),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          infoWindow: InfoWindow(title: name),
        ));
      });

      //  apply filter（add places markers into it）
      _applyFilter();

      // filter only move camera, at that time all marker already exist
      // use of _animateToFitMarkers will ignore 'me' marker（search mode）
      _animateToFitMarkers(keepZoom: false);

    } catch (e) {
      setState(() => _isSearchLoading = false);
    }
  }
 
  // clear search，back to real time mode
  void _clearSearch() {
    _searchController.clear();
    _selectedPlacesMap.clear();
    _searchFocus.unfocus();

    final realPos = LocationService.instance.currentPosition;

    setState(() {
      if (realPos != null) _currentPosition = realPos;
      _isSearchMode        = false;
      _isSearchLoading     = false;
      _searchLocationName  = null;
      _searchPlaces        = [];
      _autocompleteSuggestions = [];
      _selectedPlaceIds.clear(); // ← clear selected places
      // me marker back to real time position
      if (realPos != null) {
        _markers.removeWhere((m) => m.markerId.value == 'me');
        _markers.removeWhere((m) => m.markerId.value == 'search_location');
        _markers.add(Marker(
          markerId: const MarkerId('me'),
          position: LatLng(realPos.latitude, realPos.longitude),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'My Location'),
        ));
      }
    });

    _applyFilter();

    if (_currentPosition != null) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude), 14,
      ));
    }
  }
 
  // Filter
   void _applyFilter() {
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
 
  // realtime mode take place from NearbyPlacesService
  List<PlaceModel> _getRealtimePlaces() {
    final isLandmarkMode = widget.landmarkLat != null && widget.landmarkLng != null;
    final source = isLandmarkMode
        ? _landmarkPlaces
        : NearbyPlacesService.instance.getByPrimary(null);

    if (_selectedPrimary == null) return source;
    return source.where((p) => p.primaryType == _selectedPrimary).toList();
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
    if (!await _checkConnectivity()) return;
    if (_searchLocationName != null) { _clearSearch(); return; }

    final isLandmarkMode = widget.landmarkLat != null && widget.landmarkLng != null;

    setState(() {
      _selectedPrimary   = null;
      _selectedSecondary = 'all';
      _isLoading         = true;
    });

    try {
      if (isLandmarkMode) {
        // landmark mode refresh only update the local _landmarkPlaces, not touch singleton
        _landmarkPlaces = await NearbyPlacesService.instance.loadNearbyPlacesAt(
          lat: widget.landmarkLat!,
          lng: widget.landmarkLng!,
          categories: categories,
          context: context,
        );
      } else {
        NearbyPlacesService.instance.clearCache(); // realt time mode then clear singleton
        await NearbyPlacesService.instance.loadNearbyPlacesOnce(categories, context); //recall
      }
    } catch (e) {
      setState(() => _isLoading = false);
      return;
    }

    _applyFilter();
  }

  //  Toggle place selection
  void _togglePlaceSelection(PlaceModel place) {
    setState(() {
      if (_selectedPlaceIds.contains(place.id)) {
        _selectedPlaceIds.remove(place.id);
        _selectedPlacesMap.remove(place.id); 
      } else {
        _selectedPlaceIds.add(place.id);
        _selectedPlacesMap[place.id] = place; 
      }
    });
  }

  // View selected then push to ItineraryDetailPage
  void _viewSelectedItinerary() async {
    if (_selectedPlaceIds.isEmpty) return;

    final selectedPlaces = _buildOptimizedRoute();
    final now     = DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd').format(now);
    var curHour = 9, curMin = 0;

    final itineraryPlaces = selectedPlaces.map((p) {
      final timeStr  = '${curHour.toString().padLeft(2, '0')}:${curMin.toString().padLeft(2, '0')}';
      final duration = p.primaryType == 'restaurant' ? 60 : 90;
      curMin  += duration;
      curHour += curMin ~/ 60;
      curMin   = curMin % 60;
      if (curHour >= 21) { curHour = 21; curMin = 0; }
      return ItineraryPlace(
        placeId: p.id, name: p.name, address: p.address ?? '',
        photoUrl: p.photoUrl, lat: p.lat, lng: p.lng,
        primaryType: p.primaryType, suggestedTime: timeStr,
        durationMinutes: duration, notes: 'Added by you',
      );
    }).toList();

    final itinerary = ItineraryModel(
      id: '',
      title: 'My Custom Trip',
      startDate: dateStr,
      totalDays: 1,
      days: [ItineraryDay(dayNumber: 1, date: dateStr, places: itineraryPlaces)],
      createdAt: now,
    );

    final savedId = await ItineraryService.instance.save(itinerary);

    if (savedId == null) {
      if (!mounted) return;
      final isLoggedIn = FirebaseAuth.instance.currentUser != null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isLoggedIn
              ? 'Failed to save itinerary'
              : 'Please log in to save itinerary'),
          backgroundColor: Colors.red,
        ),
      );
      return;  
    }

    // ✅ Only reaches here if save succeeded
    final savedItinerary = ItineraryModel.fromMap(savedId, itinerary.toMap());

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItineraryDetailPage(itinerary: savedItinerary)),
    );
  }

  List<PlaceModel> _buildOptimizedRoute() {
    final remaining = _selectedPlacesMap.values.toList();
    final result = <PlaceModel>[];

    if (remaining.isEmpty || _currentPosition == null) return result;

    double currentLat = _currentPosition!.latitude;
    double currentLng = _currentPosition!.longitude;

    int step = 1;

    print("🚀 START ROUTE OPTIMIZATION");
    print("📍 Start position: $currentLat, $currentLng");
    print("📦 Total places: ${remaining.length}");

    while (remaining.isNotEmpty) {
      PlaceModel? nearest;
      double minDist = double.infinity;

      print("\n🔁 STEP $step");
      print("📌 Current position: $currentLat, $currentLng");

      for (final place in remaining) {
        if (place.lat == null || place.lng == null) continue;

        final dist = Geolocator.distanceBetween(
          currentLat,
          currentLng,
          place.lat!,
          place.lng!,
        );

        print("   👉 ${place.name} = ${dist.toStringAsFixed(1)} m");

        if (dist < minDist) {
          minDist = dist;
          nearest = place;
        }
      }

      if (nearest == null) break;

      print("⭐ SELECTED: ${nearest.name} (${minDist.toStringAsFixed(1)} m)");

      result.add(nearest);
      remaining.remove(nearest);

      currentLat = nearest.lat!;
      currentLng = nearest.lng!;

      step++;
    }

    print("\n🏁 FINAL ROUTE:");
    for (int i = 0; i < result.length; i++) {
      print("  ${i + 1}. ${result[i].name}");
    }

    return result;
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
        steps: const [],
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
        steps: route.steps, 
        bounds: route.bounds,
        distanceMeters: route.distanceMeters,
        durationSeconds: (route.distanceMeters / _getSpeedMeterPerSecond()).round(),
      );
    }
  }

  void _animateToFitMarkers({bool keepZoom = false}) {
    if (_mapController == null || _markers.isEmpty) return;

    // search mode 时只 fit search_location 附近的 markers，忽略 'me'
    final relevantMarkers = _searchLocationName != null
        ? _markers.where((m) => m.markerId.value != 'me').toSet()
        : _markers;

    if (relevantMarkers.isEmpty) return;
    if (relevantMarkers.length == 1) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(relevantMarkers.first.position, 15));
      return;
    }

    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final m in relevantMarkers) {
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
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ), 80,
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
        startLat:          _currentPosition!.latitude,
        startLng:          _currentPosition!.longitude,
        endLat:            place.lat!,
        endLng:            place.lng!,
        destinationName:   place.name,
        startLocationName: _searchLocationName,
      ),
    ));
  }

  // ─────────────────────────────────────────────
  // offline
  // ─────────────────────────────────────────────

  Future<bool> _checkConnectivity() async {
  final result = await Connectivity().checkConnectivity();
  if (result == ConnectivityResult.none) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(children: [
            Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('No internet connection'),
          ]),
          backgroundColor: Colors.red[700],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
    return false;
  }
  return true;
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
      body: GestureDetector(
        onTap: () {
          _searchFocus.unfocus();
          setState(() {
            _isSearchMode = false;
            _autocompleteSuggestions = [];
          });
        },
        behavior: HitTestBehavior.translucent,
        child: Stack(
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

            // ── Bottom sheet ──
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) { _bottomPaddingNotifier.value = n.extent; return false; },
              child: DraggableScrollableSheet(
                key: ValueKey(_searchLocationName),
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

            // ── Floating "View Itinerary (N)" button ──
            if (_selectedPlaceIds.isNotEmpty && !_searchFocus.hasFocus)
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

        if (_searchLocationName != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              const Icon(Icons.location_on_rounded, size: 14, color: Color(0xFF1A73E8)),
              const SizedBox(width: 4),
              Text(
                'Showing results near: $_searchLocationName',
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF1A73E8),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _clearSearch,
                child: const Icon(Icons.close_rounded, size: 16, color: Color(0xFF1A73E8)),
              ),
            ]),
          ),
          
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
    const SizedBox(width: 5),
    _buildStyledFilterChip(
      label: "High Rated", isSelected: _sortMode == SortMode.rating,
      onTap: () => setState(() => _sortMode = SortMode.rating),
      icon: Icons.star_outline_rounded,
    ),
    if (_selectedPlaceIds.isNotEmpty) ...[
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), // 👈 减小 horizontal
        decoration: BoxDecoration(
          color: const Color(0xFF7C4DFF).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF7C4DFF)),
          const SizedBox(width: 4),
          Text('${_selectedPlaceIds.length}',  // 👈 只显示数字，省空间
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

  List<Map<String, dynamic>> _getAvailableSubCategories() {
    if (_selectedPrimary == null) return [];

    final subs = subCategories[_selectedPrimary] ?? [];
    if (subs.isEmpty) return [];

    // 当前主分类的所有地点
    final sourcePlaces = (_searchLocationName != null ? _searchPlaces : _getRealtimePlaces())
        .where((p) => p.primaryType == _selectedPrimary)
        .toList();

    return subs.where((sub) {
      // 'all' 永远显示
      if (sub['key'] == 'all') return true;

      final allowTypes   = (sub['allowTypes']   as List?)?.cast<String>() ?? [];
      final nameKeywords = (sub['nameKeywords'] as List?)?.cast<String>() ?? [];

      return sourcePlaces.any((place) {
        final name      = place.name.toLowerCase();
        final typeMatch = allowTypes.isNotEmpty &&
            place.allTypes.any((t) => allowTypes.contains(t));
        final nameMatch = nameKeywords.isNotEmpty &&
            nameKeywords.any((k) => name.contains(k.toLowerCase()));
        return typeMatch || nameMatch;
      });
    }).toList();
  }


  Widget _buildSecondaryBar() {
    final subs = _getAvailableSubCategories();
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), // 原来是 horizontal: 14
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