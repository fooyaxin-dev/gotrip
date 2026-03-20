import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:url_launcher/url_launcher.dart';
import 'package:gotrip/modules/place/detectPlacePage.dart';
import '../../services/location_service.dart';
import '../../services/wikipedia_service.dart';
import '../../services/placesAPI_service.dart';

class ResultPage extends StatefulWidget {
  final Uint8List imageBytes;
  final String landmark;
  final String rawJson;

  const ResultPage({
    super.key,
    required this.imageBytes,
    required this.landmark,
    required this.rawJson,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> with TickerProviderStateMixin {
  late TabController _tabController;

  // Wikipedia info
  String wikiTitle = '';
  String wikiExtract = '';
  List<String> wikiImages = [];
  String wikiUrl = '';
  bool wikiLoading = true;
  bool _isTranslated = false; // true = came from Google Translate, not Wikipedia

  // Google Places info
  Map<String, dynamic>? placeDetails;
  bool placeLoading = true;

  // Images — Places Photos first, Wikipedia as fallback
  List<String> displayImages = [];

  // Wikipedia admission info
  String? admissionInfo;
  bool admissionLoading = true;

  // PageController
  final PageController _pageController = PageController(initialPage: 0);
  int _currentImageIndex = 0;

  // Track failed image URLs instead of mutating wikiImages during scroll
  final Set<String> _failedImageUrls = {};

  // Shimmer animation
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  // ── Translation state ──────────────────────────────────────
  String? _translatedExtract;
  String? _translatedTitle;
  String _selectedLangCode = 'en';
  bool _translating = false;

  static const _languages = [
    {'code': 'en',    'label': '🇬🇧 English'},
    {'code': 'zh',    'label': '🇨🇳 中文（简体）'},
    {'code': 'zh-tw', 'label': '🇹🇼 中文（繁體）'},
    {'code': 'ms',    'label': '🇲🇾 Bahasa Melayu'},
    {'code': 'ja',    'label': '🇯🇵 日本語'},
    {'code': 'ko',    'label': '🇰🇷 한국어'},
    {'code': 'fr',    'label': '🇫🇷 Français'},
    {'code': 'ar',    'label': '🇸🇦 العربية'},
  ];
  // ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _shimmerAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    if (widget.landmark != 'No landmark detected') {
      _fetchWikipediaInfo();
      _fetchPlaceDetails();
      _fetchAdmissionInfo();
    } else {
      wikiLoading = false;
      placeLoading = false;
      admissionLoading = false;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pageController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  // ============================================================
  // Data Fetching
  // ============================================================

  Future<void> _fetchWikipediaInfo() async {
    final landmarkName = widget.landmark.split(' (Confidence')[0];
    try {
      final wikiResult = await WikipediaService.fetchLandmarkHistory(landmarkName);
      setState(() {
        wikiTitle = wikiResult['title'] ?? landmarkName;
        wikiExtract = wikiResult['summary'] ?? 'No historical info available';
        wikiImages = List<String>.from(wikiResult['images'] ?? [])
            .where((url) => !url.toLowerCase().endsWith('.svg'))
            .toList();
        wikiUrl = wikiResult['wikiUrl'] ?? '';
        if (wikiUrl.isEmpty) {
          wikiUrl =
              'https://en.wikipedia.org/wiki/${landmarkName.replaceAll(' ', '_')}';
        }
        wikiLoading = false;
        if (displayImages.isEmpty) {
          displayImages = wikiImages;
        }
      });
    } catch (e) {
      setState(() {
        wikiTitle = landmarkName;
        wikiExtract = 'Failed to load historical information.';
        wikiLoading = false;
      });
    }
  }

  Future<void> _fetchPlaceDetails() async {
    final landmarkName = widget.landmark.split(' (Confidence')[0];
    final pos = LocationService.instance.currentPosition;

    try {
      final results = await PlacesApiService.searchNearbyWithKeyword(
        lat: pos?.latitude ?? 0,
        lng: pos?.longitude ?? 0,
        keyword: landmarkName,
        radius: 500,
        maxResultCount: 1,
      );

      if (results.isEmpty) {
        setState(() => placeLoading = false);
        return;
      }

      final placeId = results[0]['id'] as String?;
      if (placeId == null) {
        setState(() => placeLoading = false);
        return;
      }

      final details = await PlacesApiService.getPlaceDetails(placeId);

      final photosRaw = details['photos'] as List?;
      final placePhotoUrls = photosRaw
              ?.map((p) => (p as Map<String, dynamic>)['photoUri'] as String?)
              .whereType<String>()
              .toList() ??
          <String>[];

      setState(() {
        placeDetails = details;
        placeLoading = false;
        if (placePhotoUrls.isNotEmpty) {
          displayImages = placePhotoUrls;
        }
      });
    } catch (e) {
      setState(() => placeLoading = false);
    }
  }

  Future<void> _fetchAdmissionInfo() async {
    final landmarkName = widget.landmark.split(' (Confidence')[0];
    final admission = await WikipediaService.fetchAdmissionInfo(landmarkName);
    setState(() {
      admissionInfo = admission;
      admissionLoading = false;
    });
  }

  // ============================================================
  // Translation
  // ============================================================

  Future<void> _translateTo(String langCode) async {
    // Reset to English — restore original text
    if (langCode == 'en') {
      setState(() {
        _selectedLangCode = 'en';
        _translatedExtract = null;
        _translatedTitle = null;
        _isTranslated = false;
      });
      return;
    }

    setState(() {
      _translating = true;
      _selectedLangCode = langCode;
    });

    try {
      final landmarkName = widget.landmark.split(' (Confidence')[0];
      final result = await WikipediaService.fetchSummaryInLanguage(
        landmarkName,
        langCode,
        wikiExtract,
      );
      setState(() {
        _translatedTitle   = result['title']   as String?;
        _translatedExtract = result['extract'] as String?;
        _isTranslated      = result['source']  == 'translated';
        _translating = false;
      });
    } catch (e) {
      setState(() => _translating = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Translation failed for this landmark.',
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final pos = LocationService.instance.currentPosition;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12, top: 8),
          child: CircleAvatar(
            backgroundColor: Colors.white.withAlpha(200),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new,
                  color: Colors.black, size: 18),
              onPressed: () => Navigator.pop(context, true),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          SizedBox(
            height: screenHeight * 0.45,
            width: double.infinity,
            child: Image.memory(widget.imageBytes, fit: BoxFit.cover),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.3),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: 0.55,
            minChildSize: 0.55,
            maxChildSize: 0.95,
            snap: true,
            snapSizes: const [0.55, 0.95],
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(30)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Drag handle
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    // Tab bar
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TabBar(
                        controller: _tabController,
                        labelColor: Colors.black,
                        unselectedLabelColor: Colors.grey[400],
                        indicatorColor: Colors.black,
                        indicatorWeight: 3,
                        indicatorSize: TabBarIndicatorSize.label,
                        labelStyle: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        tabs: const [
                          Tab(text: 'Overview'),
                          Tab(text: 'Info'),
                          Tab(text: 'Reviews'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildOverviewTab(scrollController, pos),
                          _buildInfoTabWrapper(scrollController),
                          _buildReviewsTabWrapper(scrollController),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ============================================================
  // Tab Wrappers
  // ============================================================

  Widget _buildOverviewTab(ScrollController scrollController, dynamic pos) {
    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.landmark == 'No landmark detected')
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 50),
                child: Text(
                  'No landmark detected in this image.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            )
          else ...[
            wikiLoading
                ? _buildLoadingPlaceholder()
                : _buildProSummaryContent(),
            const SizedBox(height: 24),
            if (!wikiLoading)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: _buildInfoCard(
                      // TODO: Replace with real weather API data
                      label: 'Weather',
                      value: '28°C Sunny',
                      icon: Icons.wb_sunny_rounded,
                      color: const Color(0xFFFFF3E0),
                      height: 120,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: pos == null
                        ? const Center(child: CircularProgressIndicator())
                        : GestureDetector(
                            onTap: () {
                              final landmarkLocation =
                                  placeDetails?['location'];
                              final lat =
                                  (landmarkLocation?['latitude'] as num?)
                                          ?.toDouble() ??
                                      pos.latitude;
                              final lng =
                                  (landmarkLocation?['longitude'] as num?)
                                          ?.toDouble() ??
                                      pos.longitude;

                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => RealTimeDetectPage(
                                    landmarkLat: lat,
                                    landmarkLng: lng,
                                    onBack: () => Navigator.pop(context),
                                  ),
                                ),
                              );
                            },
                            child: Builder(
                              builder: (context) {
                                final landmarkLocation =
                                    placeDetails?['location'];
                                final mapLat =
                                    (landmarkLocation?['latitude'] as num?)
                                            ?.toDouble() ??
                                        pos.latitude;
                                final mapLng =
                                    (landmarkLocation?['longitude'] as num?)
                                            ?.toDouble() ??
                                        pos.longitude;

                                return Container(
                                  height: 120,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: Stack(
                                      children: [
                                        // TODO: Move API key to secure config
                                        Image.network(
                                          'https://maps.googleapis.com/maps/api/staticmap?center=$mapLat,$mapLng&zoom=15&size=600x300&&markers=color:red%7Clabel:L%7C$mapLat,$mapLng&markers=color:blue%7Clabel:U%7C${pos.latitude},${pos.longitude}&key=AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc',
                                          fit: BoxFit.cover,
                                          width: double.infinity,
                                          height: double.infinity,
                                          errorBuilder:
                                              (context, error, stackTrace) {
                                            return Container(
                                              color: Colors.grey[200],
                                              child: const Center(
                                                child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Icon(Icons.map_outlined,
                                                        size: 32,
                                                        color: Colors.grey),
                                                    SizedBox(height: 6),
                                                    Text(
                                                      'Map unavailable',
                                                      style: TextStyle(
                                                          fontSize: 11,
                                                          color: Colors.grey),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        Positioned(
                                          top: 10,
                                          right: 10,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color:
                                                  Colors.black.withOpacity(0.5),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: IconButton(
                                              icon: const Icon(
                                                  Icons.open_in_new,
                                                  color: Colors.white,
                                                  size: 20),
                                              onPressed: () {
                                                final mapUrl =
                                                    'https://www.google.com/maps/search/?api=1&query=$mapLat,$mapLng';
                                                launchUrl(Uri.parse(mapUrl),
                                                    mode: LaunchMode
                                                        .externalApplication);
                                              },
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoTabWrapper(ScrollController scrollController) {
    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: widget.landmark == 'No landmark detected'
          ? _noLandmarkMessage()
          : placeLoading || admissionLoading
              ? _buildLoadingPlaceholder()
              : _buildInfoTab(),
    );
  }

  Widget _buildReviewsTabWrapper(ScrollController scrollController) {
    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: widget.landmark == 'No landmark detected'
          ? _noLandmarkMessage()
          : placeLoading
              ? _buildLoadingPlaceholder()
              : _buildReviewsTab(),
    );
  }

  Widget _noLandmarkMessage() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.only(top: 50),
        child: Text(
          'No landmark detected in this image.',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Info Tab
  // ============================================================

  Widget _buildInfoTab() {
    if (placeDetails == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 50),
          child: Column(
            children: [
              Icon(Icons.search_off_rounded, size: 48, color: Colors.grey),
              SizedBox(height: 12),
              Text(
                'No place info found.',
                style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      );
    }

    final d = placeDetails!;
    final openingHours = d['regularOpeningHours'] as Map<String, dynamic>?;
    final openNow = openingHours?['openNow'] as bool?;
    final weekdayRaw = openingHours?['weekdayDescriptions'] as List?;
    final phoneNumber = d['internationalPhoneNumber'] as String?;
    final website = d['websiteUri'] as String?;
    final googleMapsUrl = d['googleMapsUri'] as String?;
    final address = d['formattedAddress'] as String?;
    final rating = (d['rating'] as num?)?.toDouble();

    final weekdays = weekdayRaw?.map((e) {
          final parts = (e as String).split(': ');
          return _OpeningDay(
            day: parts[0],
            hours: parts.length > 1 ? parts[1] : 'Closed',
          );
        }).toList() ??
        <_OpeningDay>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),

        // Open / Closed badge
        if (openNow != null)
          Container(
            margin: const EdgeInsets.only(bottom: 20),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: openNow ? Colors.green[50] : Colors.red[50],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  openNow
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: 16,
                  color:
                      openNow ? Colors.green[700] : Colors.red[700],
                ),
                const SizedBox(width: 6),
                Text(
                  openNow ? 'Open Now' : 'Closed Now',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: openNow
                        ? Colors.green[700]
                        : Colors.red[700],
                  ),
                ),
              ],
            ),
          ),

        // Address
        if (address != null) ...[
          _buildSectionHeader(Icons.location_on_rounded, 'Address'),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              address,
              style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[700],
                  height: 1.5),
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Rating
        if (rating != null) ...[
          _buildSectionHeader(Icons.star_rounded, 'Rating'),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                ...List.generate(5, (i) {
                  final filled = i < rating.floor();
                  final half = !filled && (i < rating);
                  return Icon(
                    half
                        ? Icons.star_half_rounded
                        : Icons.star_rounded,
                    size: 20,
                    color: filled || half
                        ? Colors.amber[600]
                        : Colors.grey[300],
                  );
                }),
                const SizedBox(width: 10),
                Text(
                  rating.toStringAsFixed(1),
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                ),
                Text(
                  ' / 5.0',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Admission
        if (admissionInfo != null) ...[
          _buildSectionHeader(Icons.sell_rounded, 'Admission'),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(Icons.monetization_on_outlined,
                    size: 18, color: Colors.grey[600]),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    admissionInfo!,
                    style: TextStyle(
                        fontSize: 14, color: Colors.grey[700]),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Opening Hours
        if (weekdays.isNotEmpty) ...[
          _buildSectionHeader(
              Icons.access_time_rounded, 'Opening Hours'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: weekdays.asMap().entries.map((entry) {
                final isLast = entry.key == weekdays.length - 1;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            entry.value.day,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          Text(
                            entry.value.hours,
                            style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    if (!isLast)
                      Divider(
                          height: 1,
                          color: Colors.grey[200],
                          indent: 16,
                          endIndent: 16),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Contact
        if (phoneNumber != null || website != null) ...[
          _buildSectionHeader(
              Icons.contact_page_rounded, 'Contact'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                if (phoneNumber != null)
                  _buildTappableRow(
                    icon: Icons.phone_rounded,
                    label: phoneNumber,
                    onTap: () => launchUrl(
                      Uri.parse('tel:$phoneNumber'),
                      mode: LaunchMode.externalApplication,
                    ),
                    showDivider: website != null,
                  ),
                if (website != null)
                  _buildTappableRow(
                    icon: Icons.language_rounded,
                    label: website
                        .replaceFirst('https://', '')
                        .replaceFirst('http://', '')
                        .replaceFirst('www.', ''),
                    onTap: () => launchUrl(
                      Uri.parse(website),
                      mode: LaunchMode.externalApplication,
                    ),
                    showDivider: false,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Google Maps button
        if (googleMapsUrl != null)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(googleMapsUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.map_rounded, size: 18),
              label: const Text('Open in Google Maps'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black,
                side: const BorderSide(color: Colors.black12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),

        const SizedBox(height: 16),
      ],
    );
  }

  // ============================================================
  // Reviews Tab
  // ============================================================

  Widget _buildReviewsTab() {
    if (placeDetails == null ||
        (placeDetails!['reviews'] as List?)?.isEmpty == true) {
      return _buildEmptyReviews();
    }

    final d = placeDetails!;
    final rating = (d['rating'] as num?)?.toDouble() ?? 0.0;
    final userRatingCount = d['userRatingCount'] as int? ?? 0;
    final reviewsRaw = d['reviews'] as List;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),

        // Overall rating card
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.blueGrey.withOpacity(0.08),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              // Big score on the left
              Column(
                children: [
                  Text(
                    rating.toStringAsFixed(1),
                    style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  _buildStarRating(rating),
                  const SizedBox(height: 8),
                  Text(
                    '${_formatCount(userRatingCount)} reviews',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ),
              const SizedBox(width: 32),
              // Star distribution bars on the right
              Expanded(
                child: Column(
                  children: [5, 4, 3, 2, 1].map((star) {
                    return Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Text('$star',
                              style: const TextStyle(fontSize: 10)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                // TODO: Replace with actual distribution
                                value: star == 5
                                    ? 0.8
                                    : (star == 4 ? 0.4 : 0.1),
                                backgroundColor: Colors.grey[100],
                                color: Colors.amber[600],
                                minHeight: 6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),
        _buildSectionHeader(
            Icons.chat_bubble_outline_rounded, 'Community Voice'),
        const SizedBox(height: 16),

        ...reviewsRaw.map((r) => _buildReviewCard(r)).toList(),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildReviewCard(dynamic r) {
    final review = r as Map<String, dynamic>;
    final authorName =
        review['authorAttribution']?['displayName'] as String? ??
            'Traveler';
    final authorPhoto =
        review['authorAttribution']?['photoUri'] as String?;
    final reviewRating = (review['rating'] as num?)?.toInt() ?? 0;
    final text = review['text']?['text'] as String? ?? '';
    final relativeTime =
        review['relativePublishTimeDescription'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.blue.withOpacity(0.1), width: 2),
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundImage: authorPhoto != null
                      ? NetworkImage(authorPhoto)
                      : null,
                  backgroundColor: Colors.blue[50],
                  child:
                      authorPhoto == null ? Text(authorName[0]) : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(authorName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                    Text(relativeTime,
                        style: TextStyle(
                            color: Colors.grey[500], fontSize: 12)),
                  ],
                ),
              ),
              _buildSmallRatingTag(reviewRating),
            ],
          ),
          if (text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12, left: 2),
              child: Text(
                text,
                style: TextStyle(
                    color: Colors.grey[800],
                    height: 1.6,
                    fontSize: 14),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 16),
          Divider(color: Colors.grey[100], thickness: 1),
        ],
      ),
    );
  }

  Widget _buildSmallRatingTag(int score) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.amber[50],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.star_rounded, size: 14, color: Colors.amber[700]),
          const SizedBox(width: 2),
          Text(
            '$score',
            style: TextStyle(
                color: Colors.amber[800],
                fontWeight: FontWeight.bold,
                fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildStarRating(double rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < rating.floor()
              ? Icons.star_rounded
              : Icons.star_half_rounded,
          size: 20,
          color:
              i < rating ? Colors.amber[600] : Colors.grey[300],
        );
      }),
    );
  }

  Widget _buildEmptyReviews() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.forum_outlined, size: 80, color: Colors.grey[200]),
          const SizedBox(height: 16),
          Text(
            'No stories shared yet',
            style: TextStyle(
                color: Colors.grey[400],
                fontSize: 16,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // Overview Tab Components
  // ============================================================

  Widget _buildLoadingPlaceholder() {
    return AnimatedBuilder(
      animation: _shimmerAnimation,
      builder: (context, child) {
        return Opacity(
          opacity: _shimmerAnimation.value,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 32,
                width: 200,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(height: 16),
              ...List.generate(
                4,
                (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    height: 14,
                    width: i == 3 ? 180 : double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProSummaryContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Title row with language picker ──────────────────
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                _translatedTitle ?? wikiTitle,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                ),
              ),
            ),
            const SizedBox(width: 8),

            // 🌐 Language picker button
            PopupMenuButton<String>(
              initialValue: _selectedLangCode,
              onSelected: _translateTo,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              itemBuilder: (_) => _languages
                  .map(
                    (lang) => PopupMenuItem<String>(
                      value: lang['code'],
                      child: Text(
                        lang['label']!,
                        style: TextStyle(
                          fontWeight: lang['code'] == _selectedLangCode
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  )
                  .toList(),
              child: _translating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue[50],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.translate,
                              size: 14, color: Colors.blue[700]),
                          const SizedBox(width: 4),
                          Text(
                            _selectedLangCode.toUpperCase(),
                            style: TextStyle(
                              color: Colors.blue[700],
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),

            const SizedBox(width: 8),

            // Landmark badge
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Landmark',
                style: TextStyle(
                    color: Colors.blue[700],
                    fontSize: 10,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        // ────────────────────────────────────────────────────

        const SizedBox(height: 16),

        // Image carousel
        if (displayImages.isNotEmpty)
          Builder(
            builder: (context) {
              final visibleImages = displayImages
                  .where((url) => !_failedImageUrls.contains(url))
                  .toList();

              if (visibleImages.isEmpty) return const SizedBox.shrink();

              return Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    height: 220,
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: visibleImages.length,
                      onPageChanged: (index) {
                        setState(() => _currentImageIndex = index);
                      },
                      itemBuilder: (context, index) {
                        final imageUrl = visibleImages[index];
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Image.network(
                              imageUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  if (mounted) {
                                    setState(() {
                                      _failedImageUrls.add(imageUrl);
                                      final newLength = displayImages
                                          .where((u) =>
                                              !_failedImageUrls.contains(u))
                                          .length;
                                      if (_currentImageIndex >= newLength) {
                                        _currentImageIndex =
                                            (newLength - 1).clamp(0, newLength);
                                      }
                                    });
                                  }
                                });
                                return Container(
                                  color: Colors.grey[200],
                                  child: const Center(
                                    child: Icon(Icons.broken_image,
                                        size: 40, color: Colors.grey),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (visibleImages.length > 1)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        visibleImages.length,
                        (index) => Container(
                          margin:
                              const EdgeInsets.symmetric(horizontal: 4),
                          width: _currentImageIndex == index ? 24 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _currentImageIndex == index
                                ? Colors.black
                                : Colors.grey[300],
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                ],
              );
            },
          ),

        // Extract / summary text
        Container(
          padding: const EdgeInsets.only(left: 16),
          decoration: BoxDecoration(
            border: Border(
                left: BorderSide(color: Colors.grey[300]!, width: 3)),
          ),
          child: Text(
            _translatedExtract ?? wikiExtract,
            textAlign: TextAlign.justify,
            style: TextStyle(
              fontSize: 15,
              color: Colors.grey[800],
              height: 1.7,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Read more + Wikipedia link
        if (wikiUrl.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _launchWiki(wikiUrl),
              icon: const Icon(Icons.auto_stories, size: 18),
              label: const Text('Read More on Wikipedia'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blue[800],
                textStyle:
                    const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInfoCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    double? height,
  }) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, color.withOpacity(0.8)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: Colors.black87),
          ),
          const Spacer(),
          Text(
            label,
            style: const TextStyle(
                fontSize: 11,
                color: Colors.black54,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // Shared UI Helpers
  // ============================================================

  Widget _buildSectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.black87),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildTappableRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool showDivider,
  }) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 18, color: Colors.grey[600]),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: Colors.grey[400]),
              ],
            ),
          ),
        ),
        if (showDivider)
          Divider(
              height: 1,
              color: Colors.grey[200],
              indent: 16,
              endIndent: 16),
      ],
    );
  }

  // ============================================================
  // Utilities
  // ============================================================

  String _formatCount(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    }
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  Future<void> _launchWiki(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot open URL')),
      );
    }
  }
}

// Private helper — only used within this file
class _OpeningDay {
  final String day;
  final String hours;
  const _OpeningDay({required this.day, required this.hours});
}