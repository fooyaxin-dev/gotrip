import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gotrip/modules/place/detectPlacePage.dart';
import '../../services/location_service.dart';
import '../../services/wikipedia_service.dart';
import '../../services/vision_service.dart';
import '../../services/placesAPI_service.dart';
import '../../services/landmarkHistory_service.dart';
import '../../modules/place/favouriteButton.dart';

class ResultPage extends StatefulWidget {
  final Uint8List? imageBytes;       // null when opened from History (no original photo saved)
  final String? fallbackImageUrl;    // Google Places photo, used when imageBytes is null
  final LandmarkResult landmarkResult;
  final bool skipHistorySave;        // true when opened from History, to avoid re-saving a duplicate entry

  const ResultPage({
    super.key,
    this.imageBytes,
    this.fallbackImageUrl,
    required this.landmarkResult,
    this.skipHistorySave = false,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> with TickerProviderStateMixin {
  late TabController _tabController;

  Map<String, dynamic>? _wikiResult;
  bool _infoLoading = true;

  Map<String, dynamic>? placeDetails;
  bool placeLoading = true;

  List<String> displayImages = [];

  String? admissionInfo;
  bool admissionLoading = true;

  final PageController _pageController = PageController();
  int _currentImageIndex = 0;
  final Set<String> _failedImageUrls = {};

  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  // ── Translation ───────────────────────────────────────────
  String? _translatedExtract;
  String? _translatedTitle;
  String _selectedLangCode = 'en';
  bool _translating = false;
  bool _isTranslated = false;

  // ── History saved flag (avoid saving twice) ───────────────
  bool _historySaved = false;

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

  LandmarkResult get _result => widget.landmarkResult;
  bool get _isDetected => _result.isDetected;
  String get _name => _result.normalizedName;

  String get _displayTitle =>
      _translatedTitle ?? _wikiResult?['title'] ?? _name;

  String get _displayExtract =>
      _translatedExtract ?? _wikiResult?['summary'] ?? '';

  String get _wikiUrl => _wikiResult?['wikiUrl'] ?? '';

  String get _badgeLabel {
    switch (_result.method) {
      case DetectionMethod.visionLandmark: return 'Vision';
      case DetectionMethod.geminiVision:   return 'AI Vision';
      case DetectionMethod.notDetected:    return '';
    }
  }

  Color get _badgeBg {
    switch (_result.method) {
      case DetectionMethod.visionLandmark: return Colors.blue.shade50;
      case DetectionMethod.geminiVision:   return Colors.purple.shade50;
      case DetectionMethod.notDetected:    return Colors.grey.shade100;
    }
  }

  Color get _badgeColor {
    switch (_result.method) {
      case DetectionMethod.visionLandmark: return Colors.blue.shade700;
      case DetectionMethod.geminiVision:   return Colors.purple.shade700;
      case DetectionMethod.notDetected:    return Colors.grey;
    }
  }

  IconData get _badgeIcon {
    switch (_result.method) {
      case DetectionMethod.visionLandmark: return Icons.location_on_rounded;
      case DetectionMethod.geminiVision:   return Icons.auto_awesome;
      case DetectionMethod.notDetected:    return Icons.help_outline;
    }
  }

  // ── Place ID for FavouriteButton ──────────────────────────
  // Use Google Places id if available, fallback to landmark name slug
  String get _placeId =>
      placeDetails?['id'] as String? ??
      _name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');

  String get _placeAddress =>
      placeDetails?['formattedAddress'] as String? ?? '';

  double? get _placeRating =>
      (placeDetails?['rating'] as num?)?.toDouble();

  String? get _placePhoto {
    final photos = placeDetails?['photos'] as List?;
    if (photos != null && photos.isNotEmpty) {
      return (photos[0] as Map<String, dynamic>)['photoUri'] as String?;
    }
    return null;
  }

  double? get _lat {
    final loc = placeDetails?['location'];
    return (loc?['latitude'] as num?)?.toDouble() ?? _result.lat;
  }

  double? get _lng {
    final loc = placeDetails?['location'];
    return (loc?['longitude'] as num?)?.toDouble() ?? _result.lng;
  }

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

    if (_isDetected) {
      // ── FIX ────────────────────────────────────────────────
      // 之前 _fetchInfo() / _fetchPlaceDetails() 各自内部在"成功路径"
      // 里调用 _maybeSaveHistory()，导致任何一个提前 return 或抛异常
      // 的分支都会让这次 scan 完全不落地到 history。
      // 现在改为用 Future.wait 统一等两个请求都跑完（无论成功/失败，
      // 因为两者内部 catch 都不会 rethrow），再调用一次
      // _maybeSaveHistory()，保证"扫一次就存一条记录"。
      Future.wait([_fetchInfo(), _fetchPlaceDetails()]).then((_) {
        _maybeSaveHistory();
      });
    } else {
      _infoLoading    = false;
      placeLoading    = false;
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

  Future<void> _fetchInfo() async {
    try {
      final result = await WikipediaService.fetchLandmarkHistory(_name);
      if (!mounted) return;
      setState(() {
        _wikiResult      = result;
        admissionInfo    = result['admissionInfo'] as String?;
        admissionLoading = false;
        _infoLoading     = false;
        final imgs = List<String>.from(result['images'] ?? []);
        if (displayImages.isEmpty && imgs.isNotEmpty) displayImages = imgs;
      });

      if (admissionInfo == null) {
        final admission = await WikipediaService.fetchAdmissionInfo(_name);
        if (mounted) setState(() => admissionInfo = admission);
      }

      // ── FIX: 不再在这里调用 _maybeSaveHistory() ──────────────
      // 保存检查统一交给 initState 里的 Future.wait().then() 收口，
      // 避免这条成功路径是唯一触发保存的地方。
    } catch (e) {
      debugPrint('⚠️ _fetchInfo error: $e');
      if (!mounted) return;
      setState(() { _infoLoading = false; admissionLoading = false; });
      // 不 rethrow，保证 Future.wait 能继续走到收口逻辑
    }
  }

  Future<void> _fetchPlaceDetails() async {
    final pos = LocationService.instance.currentPosition;
    try {
      final results = await PlacesApiService.searchNearbyWithKeyword(
        lat: pos?.latitude ?? 0,
        lng: pos?.longitude ?? 0,
        keyword: _name,
        radius: 500,
        maxResultCount: 1,
      );

      if (results.isEmpty) {
        // ── FIX: 之前这里只是 return，现在补上日志方便排查 ──────
        debugPrint('⚠️ _fetchPlaceDetails: no nearby place matched "$_name"');
        if (mounted) setState(() => placeLoading = false);
        return;
      }

      final placeId = results[0]['id'] as String?;
      if (placeId == null) {
        debugPrint('⚠️ _fetchPlaceDetails: matched place has no id');
        if (mounted) setState(() => placeLoading = false);
        return;
      }

      final details    = await PlacesApiService.getPlaceDetails(placeId);
      final photosRaw  = details['photos'] as List?;
      final placePhotos = photosRaw
              ?.map((p) => (p as Map<String, dynamic>)['photoUri'] as String?)
              .whereType<String>()
              .toList() ?? <String>[];

      if (!mounted) return;
      setState(() {
        placeDetails = details;
        placeLoading = false;
        if (placePhotos.isNotEmpty) displayImages = placePhotos;
      });

      // ── FIX: 不再在这里调用 _maybeSaveHistory() ──────────────
    } catch (e) {
      debugPrint('⚠️ _fetchPlaceDetails error: $e');
      if (mounted) setState(() => placeLoading = false);
      // 不 rethrow
    }
  }

  // ── 统一收口：无论两个请求成功与否，扫一次就存一条记录 ──────
  void _maybeSaveHistory() {
    if (widget.skipHistorySave) return; // opened from History page, don't create a duplicate entry
    if (!mounted) return;
    if (_historySaved) return;
    _historySaved = true;

    debugPrint(
      '📝 Saving history for "$_name" '
      '(wiki: ${_wikiResult != null}, place: ${placeDetails != null})',
    );

    LandmarkHistoryService.save(
      name:            _name,
      lat:             _lat,
      lng:             _lng,
      wikiUrl:         _wikiUrl.isNotEmpty ? _wikiUrl : null,
      address:         _placeAddress.isNotEmpty ? _placeAddress : null,
      rating:          _placeRating,
      photoUrl:        _placePhoto,
      detectionMethod: _result.method == DetectionMethod.visionLandmark
          ? 'vision' : 'gemini',
    );
  }

  // ============================================================
  // Share
  // ============================================================

  Future<void> _shareLandmark() async {
    final buffer = StringBuffer();
    buffer.writeln('📍 $_name');
    if (_placeAddress.isNotEmpty) buffer.writeln(_placeAddress);
    if (_lat != null && _lng != null) {
      buffer.writeln('📌 https://maps.google.com/?q=$_lat,$_lng');
    }
    if (_wikiUrl.isNotEmpty) {
      buffer.writeln('📖 Read more: $_wikiUrl');
    }
    buffer.writeln('\nDiscover landmarks with GoTrip ✈️');

    await Share.share(buffer.toString());
  }

  // ============================================================
  // Translation
  // ============================================================

  Future<void> _translateTo(String langCode) async {
    if (langCode == 'en') {
      setState(() {
        _selectedLangCode = 'en';
        _translatedExtract = null;
        _translatedTitle   = null;
        _isTranslated      = false;
      });
      return;
    }
    setState(() { _translating = true; _selectedLangCode = langCode; });
    try {
      final result = await WikipediaService.fetchSummaryInLanguage(
        _name, langCode, _displayExtract,
      );
      if (!mounted) return;
      setState(() {
        _translatedTitle   = result['title'] as String?;
        _translatedExtract = result['extract'] as String?;
        _isTranslated      = result['source'] == 'translated';
        _translating       = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _translating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Translation failed for this landmark.'),
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
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
        // ── Action buttons: Share + Favourite ────────────────
        actions: _isDetected
            ? [
                // Share button
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: CircleAvatar(
                    backgroundColor: Colors.white.withAlpha(200),
                    child: IconButton(
                      icon: const Icon(Icons.share_rounded,
                          color: Colors.black, size: 20),
                      onPressed: _shareLandmark,
                      tooltip: 'Share',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Favourite button
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 12),
                  child: CircleAvatar(
                    backgroundColor: Colors.white.withAlpha(200),
                    child: FavouriteButton(
                      placeId:  _placeId,
                      name:     _name,
                      address:  _placeAddress,
                      rating:   _placeRating,
                      photoUrl: _placePhoto ?? displayImages.firstOrNull,
                      lat:      _lat,
                      lng:      _lng,
                      types:    const ['tourist_attraction'],
                      iconSize: 20,
                      activeColor:   Colors.red,
                      inactiveColor: Colors.black,
                    ),
                  ),
                ),
              ]
            : null,
      ),
      body: Stack(
        children: [
          SizedBox(
            height: screenHeight * 0.45,
            width: double.infinity,
            child: _buildHeroImage(),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.3), Colors.transparent],
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
                        blurRadius: 10),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      width: 40, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
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
                            fontWeight: FontWeight.bold, fontSize: 16),
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
  // Hero image: real scan photo > Google Places photo > placeholder
  // ============================================================

  Widget _buildHeroImage() {
    if (widget.imageBytes != null) {
      return Image.memory(widget.imageBytes!, fit: BoxFit.cover);
    }
    if (widget.fallbackImageUrl != null && widget.fallbackImageUrl!.isNotEmpty) {
      return Image.network(
        widget.fallbackImageUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _heroPlaceholder(),
      );
    }
    return _heroPlaceholder();
  }

  Widget _heroPlaceholder() {
    return Container(
      color: const Color(0xFFEDE7F6),
      child: const Center(
        child: Icon(Icons.location_on_rounded,
            size: 64, color: Color(0xFF7C4DFF)),
      ),
    );
  }

  // ============================================================
  // Tab Wrappers (unchanged from your original)
  // ============================================================

  Widget _buildOverviewTab(ScrollController sc, dynamic pos) {
    return SingleChildScrollView(
      controller: sc,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_isDetected)
            _noLandmarkMessage()
          else ...[
            _infoLoading
                ? _buildLoadingPlaceholder()
                : _buildSummaryContent(),
            const SizedBox(height: 24),
            if (!_infoLoading) _buildMapSection(pos),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoTabWrapper(ScrollController sc) {
    return SingleChildScrollView(
      controller: sc,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: !_isDetected
          ? _noLandmarkMessage()
          : placeLoading || admissionLoading
              ? _buildLoadingPlaceholder()
              : _buildInfoTab(),
    );
  }

  Widget _buildReviewsTabWrapper(ScrollController sc) {
    return SingleChildScrollView(
      controller: sc,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: !_isDetected
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
              fontStyle: FontStyle.italic),
        ),
      ),
    );
  }

  // ============================================================
  // Overview: Summary Content
  // ============================================================

  Widget _buildSummaryContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                _displayTitle,
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.8),
              ),
            ),
            const SizedBox(width: 8),
            // Language picker
            PopupMenuButton<String>(
              initialValue: _selectedLangCode,
              onSelected: _translateTo,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              itemBuilder: (_) => _languages
                  .map((lang) => PopupMenuItem<String>(
                        value: lang['code'],
                        child: Text(lang['label']!,
                            style: TextStyle(
                              fontWeight: lang['code'] == _selectedLangCode
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            )),
                      ))
                  .toList(),
              child: _translating
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
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
                          Text(_selectedLangCode.toUpperCase(),
                              style: TextStyle(
                                  color: Colors.blue[700],
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            // Detection method badge
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _badgeBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_badgeIcon, size: 10, color: _badgeColor),
                  const SizedBox(width: 3),
                  Text(_badgeLabel,
                      style: TextStyle(
                          color: _badgeColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (displayImages.isNotEmpty) _buildImageCarousel(),
        if (_displayExtract.isNotEmpty)
          Container(
            padding: const EdgeInsets.only(left: 16),
            decoration: BoxDecoration(
              border: Border(
                  left: BorderSide(color: Colors.grey[300]!, width: 3)),
            ),
            child: Text(
              _displayExtract,
              textAlign: TextAlign.justify,
              style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey[800],
                  height: 1.7,
                  fontStyle: FontStyle.italic),
            ),
          ),
        const SizedBox(height: 16),
        if (_wikiUrl.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _launchUrl(_wikiUrl),
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

  Widget _buildImageCarousel() {
    final visible =
        displayImages.where((u) => !_failedImageUrls.contains(u)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          height: 220,
          child: PageView.builder(
            controller: _pageController,
            itemCount: visible.length,
            onPageChanged: (i) => setState(() => _currentImageIndex = i),
            itemBuilder: (_, i) {
              final url = visible[i];
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        offset: const Offset(0, 10))
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.network(url, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted)
                        setState(() => _failedImageUrls.add(url));
                    });
                    return Container(
                        color: Colors.grey[200],
                        child: const Center(
                            child: Icon(Icons.broken_image,
                                size: 40, color: Colors.grey)));
                  }),
                ),
              );
            },
          ),
        ),
        if (visible.length > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              visible.length,
              (i) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: _currentImageIndex == i ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _currentImageIndex == i
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
  }

  Widget _buildMapSection(dynamic pos) {
    if (pos == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final lat = _lat ?? pos.latitude;
    final lng = _lng ?? pos.longitude;

    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RealTimeDetectPage(
              landmarkLat: lat,
              landmarkLng: lng,
              onBack: () => Navigator.pop(context),
            ),
          )),
      child: Container(
        height: 180,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.network(
            'https://maps.googleapis.com/maps/api/staticmap'
            '?center=$lat,$lng&zoom=15&size=600x300'
            '&markers=color:red%7Clabel:L%7C$lat,$lng'
            '&markers=color:blue%7Clabel:U%7C${pos.latitude},${pos.longitude}'
            '&key=AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey[200],
              child: const Center(
                  child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.map_outlined, size: 32, color: Colors.grey),
                  SizedBox(height: 6),
                  Text('Map unavailable',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              )),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Info Tab (unchanged from your original)
  // ============================================================

  Widget _buildInfoTab() {
    if (placeDetails == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 50),
          child: Column(children: [
            Icon(Icons.search_off_rounded, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('No place info found.',
                style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontStyle: FontStyle.italic)),
          ]),
        ),
      );
    }

    final d            = placeDetails!;
    final openingHours = d['regularOpeningHours'] as Map<String, dynamic>?;
    final openNow      = openingHours?['openNow'] as bool?;
    final weekdayRaw   = openingHours?['weekdayDescriptions'] as List?;
    final phoneNumber  = d['internationalPhoneNumber'] as String?;
    final website      = d['websiteUri'] as String?;
    final googleMapsUrl = d['googleMapsUri'] as String?;
    final address      = d['formattedAddress'] as String?;
    final rating       = (d['rating'] as num?)?.toDouble();

    final weekdays = weekdayRaw?.map((e) {
          final parts = (e as String).split(': ');
          return _OpeningDay(
              day: parts[0],
              hours: parts.length > 1 ? parts[1] : 'Closed');
        }).toList() ??
        <_OpeningDay>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (openNow != null)
          Container(
            margin: const EdgeInsets.only(bottom: 20),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: openNow ? Colors.green[50] : Colors.red[50],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  openNow
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: 16,
                  color:
                      openNow ? Colors.green[700] : Colors.red[700]),
              const SizedBox(width: 6),
              Text(openNow ? 'Open Now' : 'Closed Now',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: openNow
                          ? Colors.green[700]
                          : Colors.red[700])),
            ]),
          ),
        if (address != null) ...[
          _sectionHeader(Icons.location_on_rounded, 'Address'),
          const SizedBox(height: 10),
          _infoBox(
              child: Text(address,
                  style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[700],
                      height: 1.5))),
          const SizedBox(height: 24),
        ],
        if (rating != null) ...[
          _sectionHeader(Icons.star_rounded, 'Rating'),
          const SizedBox(height: 10),
          _infoBox(
              child: Row(children: [
            ...List.generate(5, (i) {
              final filled = i < rating.floor();
              final half   = !filled && i < rating;
              return Icon(
                  half
                      ? Icons.star_half_rounded
                      : Icons.star_rounded,
                  size: 20,
                  color: filled || half
                      ? Colors.amber[600]
                      : Colors.grey[300]);
            }),
            const SizedBox(width: 10),
            Text(rating.toStringAsFixed(1),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
            Text(' / 5.0',
                style: TextStyle(
                    fontSize: 13, color: Colors.grey[500])),
          ])),
          const SizedBox(height: 24),
        ],
        if (admissionInfo != null) ...[
          _sectionHeader(Icons.sell_rounded, 'Admission'),
          const SizedBox(height: 10),
          _infoBox(
              child: Row(children: [
            Icon(Icons.monetization_on_outlined,
                size: 18, color: Colors.grey[600]),
            const SizedBox(width: 12),
            Expanded(
                child: Text(admissionInfo!,
                    style: TextStyle(
                        fontSize: 14, color: Colors.grey[700]))),
          ])),
          const SizedBox(height: 24),
        ],
        if (weekdays.isNotEmpty) ...[
          _sectionHeader(Icons.access_time_rounded, 'Opening Hours'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: weekdays.asMap().entries.map((entry) {
                final isLast = entry.key == weekdays.length - 1;
                return Column(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        Text(entry.value.day,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87)),
                        Text(entry.value.hours,
                            style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[600])),
                      ],
                    ),
                  ),
                  if (!isLast)
                    Divider(
                        height: 1,
                        color: Colors.grey[200],
                        indent: 16,
                        endIndent: 16),
                ]);
              }).toList(),
            ),
          ),
          const SizedBox(height: 24),
        ],
        if (phoneNumber != null || website != null) ...[
          _sectionHeader(Icons.contact_page_rounded, 'Contact'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              if (phoneNumber != null)
                _tappableRow(
                    icon: Icons.phone_rounded,
                    label: phoneNumber,
                    onTap: () => launchUrl(
                        Uri.parse('tel:$phoneNumber'),
                        mode: LaunchMode.externalApplication),
                    showDivider: website != null),
              if (website != null)
                _tappableRow(
                    icon: Icons.language_rounded,
                    label: website
                        .replaceFirst('https://', '')
                        .replaceFirst('http://', '')
                        .replaceFirst('www.', ''),
                    onTap: () => launchUrl(Uri.parse(website),
                        mode: LaunchMode.externalApplication),
                    showDivider: false),
            ]),
          ),
          const SizedBox(height: 24),
        ],
        if (googleMapsUrl != null)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(googleMapsUrl),
                  mode: LaunchMode.externalApplication),
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
  // Reviews Tab (unchanged from your original)
  // ============================================================

  Widget _buildReviewsTab() {
    if (placeDetails == null ||
        (placeDetails!['reviews'] as List?)?.isEmpty == true) {
      return _buildEmptyReviews();
    }

    final d               = placeDetails!;
    final rating          = (d['rating'] as num?)?.toDouble() ?? 0.0;
    final userRatingCount = d['userRatingCount'] as int? ?? 0;
    final reviewsRaw      = d['reviews'] as List;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                  color: Colors.blueGrey.withOpacity(0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 10))
            ],
          ),
          child: Row(children: [
            Column(children: [
              Text(rating.toStringAsFixed(1),
                  style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A1A))),
              _buildStarRating(rating),
              const SizedBox(height: 8),
              Text('${_formatCount(userRatingCount)} reviews',
                  style:
                      TextStyle(fontSize: 12, color: Colors.grey[500])),
            ]),
            const SizedBox(width: 32),
            Expanded(
                child: Column(
              children: [5, 4, 3, 2, 1]
                  .map((star) => Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Text('$star',
                              style: const TextStyle(fontSize: 10)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: star == 5
                                  ? 0.8
                                  : (star == 4 ? 0.4 : 0.1),
                              backgroundColor: Colors.grey[100],
                              color: Colors.amber[600],
                              minHeight: 6,
                            ),
                          )),
                        ]),
                      ))
                  .toList(),
            )),
          ]),
        ),
        const SizedBox(height: 32),
        _sectionHeader(
            Icons.chat_bubble_outline_rounded, 'Community Voice'),
        const SizedBox(height: 16),
        ...reviewsRaw
            .map((r) => _buildReviewCard(r as Map<String, dynamic>)),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildReviewCard(Map<String, dynamic> review) {
    final authorName  = review['authorAttribution']?['displayName'] as String? ?? 'Traveler';
    final authorPhoto = review['authorAttribution']?['photoUri'] as String?;
    final reviewRating = (review['rating'] as num?)?.toInt() ?? 0;
    final text        = review['text']?['text'] as String? ?? '';
    final relativeTime = review['relativePublishTimeDescription'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 20,
            backgroundImage:
                authorPhoto != null ? NetworkImage(authorPhoto) : null,
            backgroundColor: Colors.blue[50],
            child: authorPhoto == null ? Text(authorName[0]) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(authorName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                Text(relativeTime,
                    style:
                        TextStyle(color: Colors.grey[500], fontSize: 12)),
              ])),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(Icons.star_rounded,
                  size: 14, color: Colors.amber[700]),
              const SizedBox(width: 2),
              Text('$reviewRating',
                  style: TextStyle(
                      color: Colors.amber[800],
                      fontWeight: FontWeight.bold,
                      fontSize: 12)),
            ]),
          ),
        ]),
        if (text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12, left: 2),
            child: Text(text,
                style: TextStyle(
                    color: Colors.grey[800],
                    height: 1.6,
                    fontSize: 14),
                maxLines: 5,
                overflow: TextOverflow.ellipsis),
          ),
        const SizedBox(height: 16),
        Divider(color: Colors.grey[100], thickness: 1),
      ]),
    );
  }

  Widget _buildStarRating(double rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
          5,
          (i) => Icon(
              i < rating.floor()
                  ? Icons.star_rounded
                  : Icons.star_half_rounded,
              size: 20,
              color: i < rating ? Colors.amber[600] : Colors.grey[300])),
    );
  }

  Widget _buildEmptyReviews() {
    return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.forum_outlined, size: 80, color: Colors.grey[200]),
      const SizedBox(height: 16),
      Text('No stories shared yet',
          style: TextStyle(
              color: Colors.grey[400],
              fontSize: 16,
              fontWeight: FontWeight.w500)),
    ]));
  }

  // ============================================================
  // Shared UI helpers (unchanged)
  // ============================================================

  Widget _buildLoadingPlaceholder() {
    return AnimatedBuilder(
      animation: _shimmerAnimation,
      builder: (_, __) => Opacity(
        opacity: _shimmerAnimation.value,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  height: 32,
                  width: 200,
                  decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(8))),
              const SizedBox(height: 16),
              Container(
                  height: 220,
                  decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(20))),
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
                                borderRadius: BorderRadius.circular(6))),
                      )),
            ]),
      ),
    );
  }

  Widget _sectionHeader(IconData icon, String title) {
    return Row(children: [
      Icon(icon, size: 18, color: Colors.black87),
      const SizedBox(width: 8),
      Text(title,
          style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3)),
    ]);
  }

  Widget _infoBox({required Widget child}) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(16)),
      child: child,
    );
  }

  Widget _tappableRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool showDivider,
  }) {
    return Column(children: [
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Icon(icon, size: 18, color: Colors.grey[600]),
            const SizedBox(width: 12),
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 14,
                        color: Colors.blue,
                        decoration: TextDecoration.underline),
                    overflow: TextOverflow.ellipsis)),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: Colors.grey[400]),
          ]),
        ),
      ),
      if (showDivider)
        Divider(
            height: 1,
            color: Colors.grey[200],
            indent: 16,
            endIndent: 16),
    ]);
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000)    return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Cannot open URL')));
    }
  }
}

class _OpeningDay {
  final String day;
  final String hours;
  const _OpeningDay({required this.day, required this.hours});
}