// pages/itinerary/generate_itinerary_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../../services/location_service.dart';
import '../../services/placesAPI_service.dart';
import '../../services/userPreference_service.dart';
import 'itineraryDetail.dart';
import '../../services/apps_Loading.dart';

class GenerateItineraryPage extends StatefulWidget {
  const GenerateItineraryPage({super.key});

  @override
  State<GenerateItineraryPage> createState() => _GenerateItineraryPageState();
}

class _GenerateItineraryPageState extends State<GenerateItineraryPage> {
  DateTime _startDate    = DateTime.now();
  int _totalDays         = 1;
  int _placesPerDay      = 4;
  bool _isGenerating     = false;
  final _titleController = TextEditingController(text: 'My Trip');

  final _titleFocus    = FocusNode();
  final _locationFocus = FocusNode();

  late Set<String> _activeCategories;
  late Set<String> _activeCuisines;

  bool   _useCurrentLocation   = true;
  String _selectedLocationName = 'Current Location';
  double? _selectedLat;
  double? _selectedLng;

  final _locationController = TextEditingController();
  List<Map<String, dynamic>> _suggestions = [];
  bool _searchingLocation = false;

  // ── Debounce for location autocomplete ──
  Timer? _locationDebounce;
  static const _locationDebounceDuration = Duration(milliseconds: 400);

  // ── Step-based loading messages while generating ──
  static const _generatingSteps = [
    'Finding nearby places...',
    'Filtering by your preferences...',
    'Balancing categories...',
    'Grouping places by area...',
    'Building your daily schedule...',
    'Almost done...',
  ];
  int _generatingStepIndex = 0;
  Timer? _generatingStepTimer;

  static const _allCategories = [
    {'key': 'restaurant',         'label': 'Food',          'icon': '🍜'},
    {'key': 'park',               'label': 'Nature',        'icon': '🌿'},
    {'key': 'tourist_attraction', 'label': 'Historical',    'icon': '🏛️'},
    {'key': 'shopping_mall',      'label': 'Shopping',      'icon': '🛍️'},
    {'key': 'amusement_park',     'label': 'Entertainment', 'icon': '🎭'},
  ];

  static const _allCuisines = [
    {'key': 'chinese',  'label': 'Chinese',  'icon': '🥢'},
    {'key': 'malay',    'label': 'Malay',    'icon': '🍛'},
    {'key': 'indian',   'label': 'Indian',   'icon': '🫓'},
    {'key': 'western',  'label': 'Western',  'icon': '🍔'},
    {'key': 'japanese', 'label': 'Japanese', 'icon': '🍱'},
    {'key': 'korean',   'label': 'Korean',   'icon': '🥩'},
    {'key': 'dessert',  'label': 'Dessert',  'icon': '🧁'},
    {'key': 'cafe',     'label': 'Cafe',     'icon': '☕'},
  ];

  @override
  void initState() {
    super.initState();
    final prefs = UserPreferenceService.instance.current;
    _activeCategories = Set.from(prefs.categories);
    _activeCuisines   = Set.from(prefs.cuisines);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _titleFocus.dispose();
    _locationFocus.dispose();
    _locationDebounce?.cancel();
    _generatingStepTimer?.cancel();
    super.dispose();
  }

  void _dismissKeyboard() {
    _titleFocus.unfocus();
    _locationFocus.unfocus();
  }

  // ─────────────────────────────────────────────
  // Location search
  // ─────────────────────────────────────────────

  // FIX: debounce so we don't fire an Autocomplete request on every
  // keystroke. Cancels any pending request and waits for a short pause
  // in typing before actually calling the API.
  void _onLocationTyped(String query) {
    _locationDebounce?.cancel();

    if (query.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }

    _locationDebounce = Timer(_locationDebounceDuration, () {
      _fetchLocationSuggestions(query);
    });
  }

  Future<void> _fetchLocationSuggestions(String query) async {
    setState(() => _searchingLocation = true);
    try {
      final pos = LocationService.instance.currentPosition;
      final results = await PlacesApiService.autocomplete(
        input: query,
        lat:   pos?.latitude,
        lng:   pos?.longitude,
      );
      if (mounted) setState(() => _suggestions = results);
    } finally {
      if (mounted) setState(() => _searchingLocation = false);
    }
  }

  Future<void> _onSuggestionSelected(Map<String, dynamic> suggestion) async {
    final placeId = suggestion['placeId'] as String;
    final name    = suggestion['mainText'] as String? ??
                    suggestion['description'] as String? ?? '';
    _dismissKeyboard();
    _locationDebounce?.cancel();
    setState(() {
      _suggestions = [];
      _locationController.text = name;
      _searchingLocation = true;
    });
    try {
      final detail = await PlacesApiService.getPlaceLatLng(placeId);
      if (detail != null && mounted) {
        setState(() {
          _selectedLat          = (detail['lat'] as num?)?.toDouble();
          _selectedLng          = (detail['lng'] as num?)?.toDouble();
          _selectedLocationName = name;
          _useCurrentLocation   = false;
        });
      }
    } finally {
      if (mounted) setState(() => _searchingLocation = false);
    }
  }

  void _resetToCurrentLocation() {
    _dismissKeyboard();
    _locationDebounce?.cancel();
    setState(() {
      _useCurrentLocation   = true;
      _selectedLat          = null;
      _selectedLng          = null;
      _selectedLocationName = 'Current Location';
      _locationController.clear();
      _suggestions          = [];
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.info_outline, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ]),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF7C4DFF),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Generate
  // ─────────────────────────────────────────────

  // FIX: cycles through _generatingSteps while the itinerary is being
  // built so the user sees progress instead of a single static label.
  // The underlying generate() call doesn't report real progress, so this
  // advances on a timer; it stops as soon as generation finishes.
  void _startGeneratingStepTimer() {
    _generatingStepIndex = 0;
    _generatingStepTimer?.cancel();
    _generatingStepTimer = Timer.periodic(const Duration(milliseconds: 1400), (timer) {
      if (!mounted || _generatingStepIndex >= _generatingSteps.length - 1) {
        timer.cancel();
        return;
      }
      setState(() => _generatingStepIndex++);
    });
  }

  void _stopGeneratingStepTimer() {
    _generatingStepTimer?.cancel();
    _generatingStepTimer = null;
  }

  Future<void> _generate() async {
    _dismissKeyboard();

    if (_useCurrentLocation) {
      final pos = LocationService.instance.currentPosition;
      if (pos == null) {
        _showSnack('Unable to get your location. Please enable GPS or search a place manually.');
        return;
      }
    }

    if (!_useCurrentLocation && (_selectedLat == null || _selectedLng == null)) {
      _showSnack('Please select a valid location from the suggestions.');
      return;
    }

    setState(() => _isGenerating = true);
    _startGeneratingStepTimer();

    try {
      final itinerary = await ItineraryService.instance.generate(
        startDate:          DateFormat('yyyy-MM-dd').format(_startDate),
        totalDays:          _totalDays,
        placesPerDay:       _placesPerDay,
        tripTitle:          _titleController.text.trim().isEmpty
            ? 'My Trip' : _titleController.text.trim(),
        overrideCategories: _activeCategories.toList(),
        overrideCuisines:   _activeCuisines.toList(),
        overrideLat:        _useCurrentLocation ? null : _selectedLat,
        overrideLng:        _useCurrentLocation ? null : _selectedLng,
      );

      if (!mounted) return;

      if (itinerary == null) {
        _showSnack('Failed to generate itinerary. Please try again.');
        return;
      }

      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => ItineraryDetailPage(itinerary: itinerary)),
      );

      if (saved == true && mounted) Navigator.pop(context);

    } finally {
      _stopGeneratingStepTimer();
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<void> _pickDate() async {
    _dismissKeyboard();
    await Future.delayed(const Duration(milliseconds: 100));
    final picked = await showDatePicker(
      context:     context,
      initialDate: _startDate,
      firstDate:   DateTime.now(),
      lastDate:    DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF7C4DFF)),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _startDate = picked);
  }

  void _openAddSheet() {
    _dismissKeyboard();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: EdgeInsets.fromLTRB(
              24, 16, 24, 24 + MediaQuery.of(context).padding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Add to this trip',
                  style: TextStyle(fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E))),
              const SizedBox(height: 4),
              Text('Select what you want for this itinerary',
                  style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              const SizedBox(height: 20),
              const Text('Category',
                  style: TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E))),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _allCategories.map((c) {
                  final isOn = _activeCategories.contains(c['key']);
                  return GestureDetector(
                    onTap: () => setSheet(() => setState(() {
                      isOn
                          ? _activeCategories.remove(c['key'])
                          : _activeCategories.add(c['key']!);
                    })),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: isOn
                            ? const Color(0xFF7C4DFF).withOpacity(0.12)
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isOn
                              ? const Color(0xFF7C4DFF)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Text('${c['icon']} ${c['label']}',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: isOn
                                  ? const Color(0xFF7C4DFF)
                                  : Colors.black87)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              const Text('Cuisine',
                  style: TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E))),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _allCuisines.map((c) {
                  final isOn = _activeCuisines.contains(c['key']);
                  return GestureDetector(
                    onTap: () => setSheet(() => setState(() {
                      isOn
                          ? _activeCuisines.remove(c['key'])
                          : _activeCuisines.add(c['key']!);
                    })),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: isOn
                            ? const Color(0xFF7C4DFF).withOpacity(0.12)
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isOn
                              ? const Color(0xFF7C4DFF)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Text('${c['icon']} ${c['label']}',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: isOn
                                  ? const Color(0xFF7C4DFF)
                                  : Colors.black87)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C4DFF),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Done',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final prefs = UserPreferenceService.instance.current;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8F6FF),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Colors.black87, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Plan Your Trip',
            style: TextStyle(
                color: Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: GestureDetector(
        onTap: _dismissKeyboard,
        behavior: HitTestBehavior.opaque,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── Hero Banner ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('✨ Trip Planner',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 8),
                    const Text('Create your\nperfect itinerary',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            height: 1.2)),
                    const SizedBox(height: 12),
                    Row(children: [
                      const Icon(Icons.auto_awesome_rounded,
                          color: Colors.white60, size: 13),
                      const SizedBox(width: 6),
                      Text(
                        'Personalised for you · ${prefs.budgetTier.label} budget',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12),
                      ),
                    ]),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              _buildSectionLabel('Trip Name'),
              const SizedBox(height: 10),
              _buildTextField(_titleController, 'e.g. Weekend Getaway'),

              const SizedBox(height: 24),

              _buildLocationSection(),

              const SizedBox(height: 24),

              _buildSectionLabel('Start Date'),
              const SizedBox(height: 10),
              _buildDatePicker(),

              const SizedBox(height: 24),

              _buildSectionLabel('Number of Days'),
              const SizedBox(height: 10),
              _buildNumberSelector(
                value:     _totalDays,
                min:       1, max: 7,
                onChanged: (v) {
                  _dismissKeyboard();
                  setState(() => _totalDays = v);
                },
                suffix: _totalDays == 1 ? 'day' : 'days',
              ),

              const SizedBox(height: 24),

              _buildSectionLabel('Places per Day'),
              const SizedBox(height: 10),
              _buildNumberSelector(
                value:     _placesPerDay,
                min:       2, max: 6,
                onChanged: (v) {
                  _dismissKeyboard();
                  setState(() => _placesPerDay = v);
                },
                suffix: 'places',
              ),

              const SizedBox(height: 24),

              _buildPreferencesSection(),

              const SizedBox(height: 32),

              // ── Trip Summary ──
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF).withOpacity(0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: const Color(0xFF7C4DFF).withOpacity(0.2)),
                ),
                child: Row(children: [
                  const Icon(Icons.info_outline_rounded,
                      color: Color(0xFF7C4DFF), size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$_totalDays ${_totalDays == 1 ? "day" : "days"} · '
                      '${_totalDays * _placesPerDay} places total · '
                      'Starting ${DateFormat('MMM dd').format(_startDate)}',
                      style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF5E35B1),
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ]),
              ),

              const SizedBox(height: 28),

              // ── Generate Button ──
              SizedBox(
                width: double.infinity, height: 58,
                child: ElevatedButton(
                  onPressed: _isGenerating ? null : _generate,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C4DFF),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                  ),
                  child: _isGenerating
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(
                              width: 20, height: 20,
                              child: TravelLoadingIndicator(),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                _generatingSteps[_generatingStepIndex],
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.auto_awesome_rounded, size: 20),
                            SizedBox(width: 8),
                            Text('Generate Itinerary',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                ),
              ),

              SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Location section
  // ─────────────────────────────────────────────

  Widget _buildLocationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('Trip Location'),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2))
            ],
          ),
          child: Column(
            children: [
              GestureDetector(
                onTap: _resetToCurrentLocation,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: _useCurrentLocation
                        ? const Color(0xFF7C4DFF).withOpacity(0.06)
                        : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(14)),
                    border: _useCurrentLocation
                        ? Border.all(
                            color: const Color(0xFF7C4DFF).withOpacity(0.3))
                        : null,
                  ),
                  child: Row(children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: _useCurrentLocation
                            ? const Color(0xFF7C4DFF).withOpacity(0.12)
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.my_location_rounded,
                          size: 18,
                          color: _useCurrentLocation
                              ? const Color(0xFF7C4DFF)
                              : Colors.grey[500]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Current Location',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: _useCurrentLocation
                                      ? const Color(0xFF7C4DFF)
                                      : Colors.black87)),
                          Text('Use where you are now',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[500])),
                        ],
                      ),
                    ),
                    if (_useCurrentLocation)
                      const Icon(Icons.check_circle_rounded,
                          color: Color(0xFF7C4DFF), size: 20),
                  ]),
                ),
              ),

              Divider(color: Colors.grey[100], height: 1),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: !_useCurrentLocation
                              ? const Color(0xFF7C4DFF).withOpacity(0.12)
                              : Colors.grey[100],
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.search_rounded,
                            size: 18,
                            color: !_useCurrentLocation
                                ? const Color(0xFF7C4DFF)
                                : Colors.grey[500]),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('Search a place',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: !_useCurrentLocation
                                    ? const Color(0xFF7C4DFF)
                                    : Colors.black87)),
                      ),
                      if (!_useCurrentLocation)
                        const Icon(Icons.check_circle_rounded,
                            color: Color(0xFF7C4DFF), size: 20),
                    ]),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _locationController,
                      focusNode: _locationFocus,
                      onChanged: _onLocationTyped,
                      decoration: InputDecoration(
                        hintText: 'e.g. Penang, Kuala Lumpur, Tokyo...',
                        hintStyle: TextStyle(
                            color: Colors.grey[400], fontSize: 13),
                        prefixIcon: _searchingLocation
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16, height: 16,
                                  child: TravelLoadingIndicator(),
                                ),
                              )
                            : Icon(Icons.place_rounded,
                                color: Colors.grey[400], size: 18),
                        suffixIcon: _locationController.text.isNotEmpty
                            ? IconButton(
                                icon: Icon(Icons.close_rounded,
                                    size: 16, color: Colors.grey[400]),
                                onPressed: _resetToCurrentLocation,
                              )
                            : null,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                BorderSide(color: Colors.grey[200]!)),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                BorderSide(color: Colors.grey[200]!)),
                        focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: Color(0xFF7C4DFF))),
                        filled: true,
                        fillColor: Colors.grey[50],
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        isDense: true,
                      ),
                    ),

                    if (_suggestions.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey[200]!),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withOpacity(0.06),
                                blurRadius: 8,
                                offset: const Offset(0, 3))
                          ],
                        ),
                        child: Column(
                          children: _suggestions.asMap().entries.map((e) {
                            final i      = e.key;
                            final sugg   = e.value;
                            final isLast = i == _suggestions.length - 1;
                            return GestureDetector(
                              onTap: () => _onSuggestionSelected(sugg),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  border: isLast
                                      ? null
                                      : Border(
                                          bottom: BorderSide(
                                              color: Colors.grey[100]!)),
                                ),
                                child: Row(children: [
                                  Icon(Icons.location_on_rounded,
                                      size: 14, color: Colors.grey[400]),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          sugg['mainText'] as String? ?? '',
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF1A1A2E)),
                                        ),
                                        if ((sugg['secondaryText']
                                                    as String?)
                                                ?.isNotEmpty ==
                                            true)
                                          Text(
                                            sugg['secondaryText'] as String,
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey[500]),
                                          ),
                                      ],
                                    ),
                                  ),
                                ]),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                    if (!_useCurrentLocation &&
                        _selectedLat != null &&
                        _suggestions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(children: [
                          const Icon(Icons.check_circle_rounded,
                              size: 14, color: Color(0xFF2ECC71)),
                          const SizedBox(width: 6),
                          Text('Set to: $_selectedLocationName',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF2ECC71),
                                  fontWeight: FontWeight.w500)),
                        ]),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  // Preferences section
  // ─────────────────────────────────────────────

  Widget _buildPreferencesSection() {
    const catLabels = {
      'restaurant':         '🍜 Food',
      'park':               '🌿 Nature',
      'tourist_attraction': '🏛️ Historical',
      'shopping_mall':      '🛍️ Shopping',
      'amusement_park':     '🎭 Entertainment',
    };
    const cuiLabels = {
      'chinese':  '🥢 Chinese',
      'malay':    '🍛 Malay',
      'indian':   '🫓 Indian',
      'western':  '🍔 Western',
      'japanese': '🍱 Japanese',
      'korean':   '🥩 Korean',
      'dessert':  '🧁 Dessert',
      'cafe':     '☕ Cafe',
    };

    final isEmpty = _activeCategories.isEmpty && _activeCuisines.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('For this trip',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E))),
            GestureDetector(
              onTap: _openAddSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(children: [
                  Icon(Icons.add_rounded,
                      size: 14, color: Color(0xFF7C4DFF)),
                  SizedBox(width: 4),
                  Text('Add / Edit',
                      style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF7C4DFF),
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('Tap ✕ to remove · Tap Add/Edit to customise',
            style: TextStyle(fontSize: 11, color: Colors.grey[400])),
        const SizedBox(height: 12),
        if (isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Row(children: [
              Icon(Icons.info_outline_rounded,
                  size: 16, color: Colors.grey[400]),
              const SizedBox(width: 8),
              Text('Nothing selected — tap Add/Edit to choose',
                  style:
                      TextStyle(color: Colors.grey[500], fontSize: 13)),
            ]),
          )
        else
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              ..._activeCategories.map((key) => _removableTag(
                    label: catLabels[key] ?? key,
                    onRemove: () =>
                        setState(() => _activeCategories.remove(key)),
                  )),
              ..._activeCuisines.map((key) => _removableTag(
                    label: cuiLabels[key] ??
                        '${key[0].toUpperCase()}${key.substring(1)}',
                    onRemove: () =>
                        setState(() => _activeCuisines.remove(key)),
                  )),
            ],
          ),
      ],
    );
  }

  Widget _removableTag({
    required String label,
    required VoidCallback onRemove,
  }) {
    return Container(
      padding:
          const EdgeInsets.only(left: 12, right: 6, top: 6, bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF7C4DFF).withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF5E35B1),
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 16, height: 16,
              decoration: BoxDecoration(
                color: const Color(0xFF7C4DFF).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close_rounded,
                  size: 10, color: Color(0xFF7C4DFF)),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Reusable widgets
  // ─────────────────────────────────────────────

  Widget _buildSectionLabel(String label) => Text(label,
      style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1A1A2E)));

  Widget _buildTextField(TextEditingController ctrl, String hint) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: TextField(
        controller: ctrl,
        focusNode: _titleFocus,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }

  Widget _buildDatePicker() {
    return GestureDetector(
      onTap: _pickDate,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ],
        ),
        child: Row(children: [
          const Icon(Icons.calendar_today_rounded,
              color: Color(0xFF7C4DFF), size: 20),
          const SizedBox(width: 12),
          Text(DateFormat('EEEE, MMM dd yyyy').format(_startDate),
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black87)),
          const Spacer(),
          Icon(Icons.chevron_right, color: Colors.grey[400]),
        ]),
      ),
    );
  }

  Widget _buildNumberSelector({
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    required String suffix,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Row(children: [
        _circleBtn(Icons.remove_rounded,
            value > min ? () => onChanged(value - 1) : null),
        Expanded(
          child: Center(
            child: Text('$value $suffix',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E))),
          ),
        ),
        _circleBtn(Icons.add_rounded,
            value < max ? () => onChanged(value + 1) : null),
      ]),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback? onTap) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFF7C4DFF).withOpacity(0.1)
              : Colors.grey[100],
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 18,
            color:
                enabled ? const Color(0xFF7C4DFF) : Colors.grey[400]),
      ),
    );
  }
}