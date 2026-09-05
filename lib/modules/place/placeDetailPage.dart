import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import '../../services/placesAPI_service.dart';
import 'favouriteButton.dart';
import 'routePreviewPage.dart';
import '../../services/categoryImage_Helper.dart';
import '../../services/apps_Loading.dart';
import '../../services/error_handler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/userPreference_service.dart';
import '../../services/location_service.dart';
import '../../models/placeModel.dart';
import '../../services/opening_hours_evaluator.dart';

/// Evaluates the current opening status of a place based on structured weekly
/// periods and the place's local timezone offset.
///
/// Does NOT use cached `regularOpeningHours.openNow`, which is an instantaneous
/// snapshot that grows stale over the cache lifetime.
@visibleForTesting
OpeningStatus evaluateCurrentPlaceOpeningStatus(
  Map<String, dynamic>? placeDetail, {
  DateTime? nowUtc,
}) {
  if (placeDetail == null) return OpeningStatus.unknown;

  final regularHours = placeDetail['regularOpeningHours'];
  if (regularHours is! Map) return OpeningStatus.unknown;

  final rawPeriods = regularHours['periods'];
  if (rawPeriods is! List || rawPeriods.isEmpty) {
    return OpeningStatus.unknown;
  }

  final rawUtcOffset = placeDetail['utcOffsetMinutes'];
  if (rawUtcOffset is! num) {
    return OpeningStatus.unknown;
  }
  final utcOffsetMinutes = rawUtcOffset.toInt();

  // Parse periods safely using OpeningHoursPeriod.fromJson
  final periods = <OpeningHoursPeriod>[];
  for (final item in rawPeriods) {
    try {
      final period = OpeningHoursPeriod.fromJson(item);
      if (period != null && period.isValid) {
        periods.add(period);
      }
    } catch (_) {
      // Malformed entries must not crash the page
    }
  }

  if (periods.isEmpty) {
    return OpeningStatus.unknown;
  }

  // Use UTC instant and apply utcOffsetMinutes exactly once to obtain place local time
  final effectiveNowUtc = (nowUtc ?? DateTime.now()).toUtc();
  final placeLocalTime =
      effectiveNowUtc.add(Duration(minutes: utcOffsetMinutes));

  // Convert Dart weekday (Monday=1..Sunday=7) to Google Places weekday (Sunday=0..Saturday=6)
  final googleWeekday = placeLocalTime.weekday % 7;

  // Calculate arrival minutes from place local midnight
  final arrivalMinutes = placeLocalTime.hour * 60 + placeLocalTime.minute;

  return OpeningHoursEvaluator.evaluateVisit(
    visitWeekday: googleWeekday,
    arrivalMinutes: arrivalMinutes,
    durationMinutes: 1,
    periods: periods,
  );
}

/// Chip displaying the current regular opening status computed dynamically
/// from structured periods and local place time.
class PlaceOpeningStatusChip extends StatelessWidget {
  final Map<String, dynamic>? placeDetail;
  final DateTime? nowUtc;

  const PlaceOpeningStatusChip({
    super.key,
    required this.placeDetail,
    this.nowUtc,
  });

  @override
  Widget build(BuildContext context) {
    final status =
        evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);

    if (status == OpeningStatus.unknown) {
      return const SizedBox.shrink();
    }

    final isOpen = status == OpeningStatus.open;
    final color = isOpen ? Colors.green : Colors.red;
    final text = isOpen ? "● Open Now" : "○ Closed Now";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color[50],
        borderRadius: BorderRadius.circular(20),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 2,
        children: [
          Text(
            text,
            style: TextStyle(
              color: color[700],
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          Text(
            '· Based on regular hours',
            style: TextStyle(
              color: color[700]?.withValues(alpha: 0.75) ?? color[700],
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// Responsive recommendation explanation card extracted from [PlaceDetailPage].
///
/// Handles narrow viewports (e.g. 320px) and large accessibility text scales
/// (e.g. 1.5x, 2.0x) without [RenderFlex] overflow. When space is constrained,
/// the header wraps the match tier chip to the next line and allows the title
/// to wrap across multiple lines without truncating.
class WhyRecommendedCard extends StatelessWidget {
  final String matchTier;
  final List<String> explanationReasons;

  const WhyRecommendedCard({
    super.key,
    required this.matchTier,
    required this.explanationReasons,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF7C4DFF).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF7C4DFF).withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final double maxWidth = constraints.maxWidth;
              return Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome_rounded,
                          color: Color(0xFF7C4DFF),
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Why this was recommended',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C4DFF),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        matchTier,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          ...explanationReasons.map((reason) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• ',
                        style: TextStyle(
                            color: Color(0xFF7C4DFF),
                            fontWeight: FontWeight.bold)),
                    Expanded(
                      child: Text(
                        reason,
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF334155),
                            height: 1.3),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

class PlaceDetailPage extends StatefulWidget {
  final String placeId; // Google ID for google places, 'geo_xxx' for geoapify
  final String? placeName; // needed for Geoapify → Google Text Search
  final double? lat;
  final double? lng;
  final double? userLat;
  final double? userLng;
  final String source; // 'google' or 'geoapify'

  const PlaceDetailPage({
    super.key,
    required this.placeId,
    this.placeName,
    this.lat,
    this.lng,
    this.userLat,
    this.userLng,
    this.source = 'google',
  });

  @override
  State<PlaceDetailPage> createState() => _PlaceDetailPageState();
}

class _PlaceDetailPageState extends State<PlaceDetailPage> {
  Map<String, dynamic>? placeDetail;
  bool loading = true;
  String? error;
  int _currentPhotoIndex = 0;

  late PageController _pageController;
  Timer? _autoPlayTimer;
  bool _isUserInteracting = false;

  List<String> _photoUrls = [];
  String? _firstPhotoUrl;

  // The resolved Google Place ID — may differ from widget.placeId for Geoapify places
  String? _resolvedGooglePlaceId;

  bool get _isGeoapify =>
      widget.source == 'geoapify' || widget.placeId.startsWith('geo_');

  // ── Reviews: filter + sort ─────────────────────────────────
  // NOTE: Google Places Details API only ever returns up to 5 reviews
  // per place, regardless of how many the place actually has. Filtering
  // and sorting here only operate on that small sample — never the full
  // review count — so the UI is careful to say "sample", not "all
  // reviews".
  int? _reviewFilterStars; // null = All
  String _reviewSort = 'relevant'; // 'relevant' | 'highest' | 'lowest'

  List<dynamic> get _allReviews => (placeDetail?['reviews'] as List?) ?? [];

  List<dynamic> get _filteredReviews {
    var list = List<dynamic>.from(_allReviews);

    if (_reviewFilterStars != null) {
      list = list
          .where((r) => (r['rating'] as num?)?.toInt() == _reviewFilterStars)
          .toList();
    }

    switch (_reviewSort) {
      case 'highest':
        list.sort((a, b) =>
            ((b['rating'] as num?) ?? 0).compareTo((a['rating'] as num?) ?? 0));
        break;
      case 'lowest':
        list.sort((a, b) =>
            ((a['rating'] as num?) ?? 0).compareTo((b['rating'] as num?) ?? 0));
        break;
      default:
        break; // keep Google's original "most relevant" order
    }
    return list;
  }

  Map<int, int> get _ratingCounts {
    final counts = {5: 0, 4: 0, 3: 0, 2: 0, 1: 0};
    for (final r in _allReviews) {
      final stars = (r['rating'] as num?)?.toInt();
      if (stars != null && counts.containsKey(stars)) {
        counts[stars] = counts[stars]! + 1;
      }
    }
    return counts;
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 1.0);
    _fetchPlaceDetails();
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startAutoPlay(int total) {
    _autoPlayTimer?.cancel();
    if (total <= 1) return;
    _autoPlayTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_isUserInteracting) return;
      final nextPage = (_currentPhotoIndex + 1) % total;
      _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // 3) 新增这个方法
  Future<void> _precachePhotos(List<String> urls) async {
    await Future.wait(
      urls.map((u) => precacheImage(CachedNetworkImageProvider(u), context)
          .catchError((_) {})),
    );
  }

  Future<void> _fetchPlaceDetails() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      String googlePlaceId;

      if (_isGeoapify) {
        // ── Step 1: Resolve Geoapify place → Google Place ID ─────────────────
        // Uses Text Search with name + coords, result cached in Firestore
        final name = widget.placeName ?? '';
        if (name.isEmpty || widget.lat == null || widget.lng == null) {
          setState(() {
            error = 'Not enough information to load place details.';
            loading = false;
          });
          return;
        }

        setState(() {
          // Show a more specific loading message while resolving
          loading = true;
        });

        final resolvedId = await PlacesApiService.findGooglePlaceId(
          geoInternalId: widget.placeId,
          placeName: name,
          lat: widget.lat!,
          lng: widget.lng!,
        );

        if (resolvedId == null) {
          setState(() {
            error = 'Could not find details for this place.';
            loading = false;
          });
          return;
        }

        googlePlaceId = resolvedId;
        _resolvedGooglePlaceId = resolvedId;
      } else {
        // ── Google place: use placeId directly ───────────────────────────────
        googlePlaceId = widget.placeId;
        _resolvedGooglePlaceId = widget.placeId;
      }

      // ── Step 2: Fetch detail (same flow for both sources) ─────────────────
      // Firebase cache is keyed by Google Place ID, so Geoapify places
      // get cached too after the first lookup — subsequent taps are free.
      final data = await PlacesApiService.getPlaceDetails(googlePlaceId);

      // ── Build photo URLs ──────────────────────────────────────────────────
      final List<String> urls = [];
      String? firstUrl;
      final photos = data['photos'] as List?;
      if (photos != null && photos.isNotEmpty) {
        for (final photo in photos) {
          urls.add(
              PlacesApiService.buildPhotoUrl(photo['name'], maxWidth: 800));
        }
        firstUrl =
            PlacesApiService.buildPhotoUrl(photos[0]['name'], maxWidth: 400);
      }

      // 2) _fetchPlaceDetails 里：先 precache 完所有照片，才启动 autoplay
      setState(() {
        placeDetail = data;
        _photoUrls = urls;
        _firstPhotoUrl = firstUrl;
        loading = false;
        _reviewFilterStars = null;
        _reviewSort = 'relevant';
      });

      // 🆕 现在 placeDetail 已经有真正的数据了，才提取 primaryType/types 记录 time affinity
      final List<String> types =
          (data['types'] as List?)?.map((e) => e.toString()).toList() ?? [];
      final primaryType = data['primaryType'] as String? ??
          (types.isNotEmpty ? types.first : null);

      UserPreferenceService.instance.updateFromPlaceView(
        primaryType: primaryType,
        allTypes: types,
      );

      if (urls.length > 1) {
        await _precachePhotos(urls); // ← 等图片真的进缓存
        if (mounted) _startAutoPlay(urls.length);
      }
    } catch (e) {
      setState(() {
        error = ErrorHandler.userFriendlyMessage(e,
            defaultMessage:
                'Unable to load place details. Please check your connection and try again.');
        loading = false;
      });
    }
  }

  void _navigateToGuide(String name) async {
    if (widget.lat == null || widget.lng == null) return;

    double? startLat;
    double? startLng;

    // Prefer fresh live position from LocationService if active and recent (within 10s)
    final livePos = LocationService.instance.currentPosition;
    final isCachedFresh = LocationService.isPositionFresh(livePos);

    if (isCachedFresh && livePos != null) {
      startLat = livePos.latitude;
      startLng = livePos.longitude;
    } else {
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        ).timeout(const Duration(seconds: 3));
        if (pos.latitude.isFinite &&
            pos.longitude.isFinite &&
            (pos.latitude != 0.0 || pos.longitude != 0.0)) {
          startLat = pos.latitude;
          startLng = pos.longitude;
        }
      } catch (_) {
        // Fall back to passed coordinates only after fresh location retrieval fails
      }

      if (startLat == null &&
          widget.userLat != null &&
          widget.userLng != null &&
          widget.userLat != 0.0 &&
          widget.userLng != 0.0 &&
          widget.userLat!.isFinite &&
          widget.userLng!.isFinite) {
        startLat = widget.userLat;
        startLng = widget.userLng;
      }
    }

    if (startLat == null ||
        startLng == null ||
        !startLat.isFinite ||
        !startLng.isFinite ||
        (startLat == 0.0 && startLng == 0.0)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to get current location.')),
        );
      }
      return;
    }

    if (!mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RoutePreviewPage(
            startLat: startLat!,
            startLng: startLng!,
            endLat: widget.lat!,
            endLng: widget.lng!,
            destinationName: name,
          ),
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Place Details')),
      body: loading
          ? _buildLoadingState()
          : error != null
              ? _buildErrorState()
              : _buildContent(),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const TravelLoadingIndicator(),
          const SizedBox(height: 16),
          Text(
            _isGeoapify ? 'Fetching place details...' : 'Loading...',
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return AppErrorStateView(
      icon: Icons.location_off_rounded,
      title: 'Place Details Unavailable',
      message: error ?? 'Unable to load details for this place.',
      onRetry: _fetchPlaceDetails,
      retryLabel: 'Try Again',
      onSecondary: () => Navigator.pop(context),
      secondaryLabel: 'Go Back',
    );
  }

  Widget _buildContent() {
    final name = placeDetail?['displayName']?['text'] ?? 'Unknown';
    final address = placeDetail?['formattedAddress'] ?? 'No address';
    final rating = (placeDetail?['rating'] as num?)?.toDouble();
    final phone = placeDetail?['internationalPhoneNumber'];
    final website = placeDetail?['websiteUri'];

    final List<String> types =
        (placeDetail?['types'] as List?)?.map((e) => e.toString()).toList() ??
            [];

    final primaryType = placeDetail?['primaryType'] as String? ??
        (types.isNotEmpty ? types.first : null);

    // For FavouriteButton: Geoapify places now have a resolved Google Place ID
    // so we pass that instead of the internal geo_ id
    final favPlaceId = _resolvedGooglePlaceId ?? widget.placeId;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPhotoCarousel(_photoUrls, primaryType, types),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + Favourite + Rating
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                    ),
                    Row(children: [
                      FavouriteButton(
                        placeId: favPlaceId, // ← resolved Google ID
                        name: name,
                        address: address,
                        rating: rating,
                        photoUrl: _firstPhotoUrl,
                        lat: widget.lat,
                        lng: widget.lng,
                        types: types,
                        iconSize: 26,
                        activeColor: Colors.red,
                        inactiveColor: Colors.grey,
                        showBackground: false,
                      ),
                      if (rating != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.orange[50],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(children: [
                            const Icon(Icons.star,
                                color: Colors.orange, size: 18),
                            const SizedBox(width: 4),
                            Text(rating.toString(),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange)),
                          ]),
                        ),
                    ]),
                  ],
                ),
                const SizedBox(height: 10),

                PlaceOpeningStatusChip(placeDetail: placeDetail),

                const SizedBox(height: 20),
                const Divider(),

                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final textScale =
                          MediaQuery.textScalerOf(context).scale(1.0);
                      final useSingleRow =
                          constraints.maxWidth >= 300 && textScale <= 1.3;

                      final actionButtons = [
                        _buildActionButton(
                          Icons.phone,
                          "Call",
                          phone != null,
                          semanticLabel: "Call place",
                          disabledSemanticLabel: "Call unavailable",
                          tooltip: "Call",
                          onTap:
                              phone != null ? () => _launchPhone(phone) : null,
                        ),
                        _buildActionButton(
                          Icons.public,
                          "Website",
                          website != null,
                          semanticLabel: "Open place website",
                          disabledSemanticLabel: "Website unavailable",
                          tooltip: "Website",
                          onTap: website != null
                              ? () => _launchWebsite(website)
                              : null,
                        ),
                        _buildActionButton(
                          Icons.directions,
                          "Directions",
                          widget.lat != null && widget.lng != null,
                          semanticLabel: "Get directions",
                          disabledSemanticLabel: "Directions unavailable",
                          tooltip: "Directions",
                          onTap: () => _navigateToGuide(name),
                        ),
                        _buildActionButton(
                          Icons.share,
                          "Share",
                          true,
                          semanticLabel: "Share place",
                          tooltip: "Share",
                          onTap: () => _sharePlace(name, address, website),
                        ),
                      ];

                      if (useSingleRow) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: actionButtons
                              .map((btn) => Expanded(child: btn))
                              .toList(),
                        );
                      }

                      return Wrap(
                        spacing: 8,
                        runSpacing: 12,
                        alignment: WrapAlignment.spaceAround,
                        children: actionButtons
                            .map((btn) => SizedBox(
                                  width: (constraints.maxWidth - 24) / 2,
                                  child: btn,
                                ))
                            .toList(),
                      );
                    },
                  ),
                ),
                const Divider(),
                const SizedBox(height: 16),

                _buildWhyRecommendedSection(
                  primaryType: primaryType,
                  types: types,
                  rating: rating,
                  priceLevel: placeDetail?['priceLevel'] as int?,
                ),

                _buildInfoSection(Icons.location_on, "Address", address),

                if (placeDetail?['regularOpeningHours']
                        ?['weekdayDescriptions'] !=
                    null)
                  _buildOpeningHours(placeDetail!['regularOpeningHours']
                      ['weekdayDescriptions']),

                if (phone != null)
                  _buildInfoSection(Icons.call, "Phone", phone),
                if (website != null)
                  _buildInfoSection(Icons.language, "Website", website),

                const Divider(),
                const SizedBox(height: 10),

                const Text("Reviews",
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),

                if (_allReviews.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text("No reviews yet",
                        style: TextStyle(color: Colors.grey)),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Showing ${_allReviews.length} review${_allReviews.length == 1 ? '' : 's'} '
                      'returned by Google for this place.',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[400],
                          fontStyle: FontStyle.italic),
                    ),
                  ),
                  _buildReviewFilterChips(_ratingCounts, _allReviews.length),
                  const SizedBox(height: 10),
                  _buildReviewSortButton(),
                  const SizedBox(height: 16),
                  if (_filteredReviews.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No ${_reviewFilterStars ?? ''}★ reviews in this sample.',
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 13),
                        ),
                      ),
                    )
                  else
                    ..._filteredReviews.map((r) => _buildReviewItem(r)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoCarousel(
      List<String> photoUrls, String? primaryType, List<String> types) {
    if (photoUrls.isEmpty) {
      return SizedBox(
        height: 250,
        width: double.infinity,
        child: Image.asset(
          CategoryImageHelper.getAssetPath(primaryType, types),
          fit: BoxFit.cover,
        ),
      );
    }

    return Stack(
      children: [
        SizedBox(
          height: 250,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification)
                _isUserInteracting = true;
              if (notification is ScrollEndNotification)
                _isUserInteracting = false;
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              itemCount: photoUrls.length,
              physics: const PageScrollPhysics(),
              onPageChanged: (index) =>
                  setState(() => _currentPhotoIndex = index),
              // 1) itemBuilder 里换成 CachedNetworkImage,而不是裸的 NetworkImage
              itemBuilder: (context, index) => GestureDetector(
                onTap: () => _showFullScreenPhoto(context, photoUrls, index),
                child: CachedNetworkImage(
                  imageUrl: photoUrls[index],
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 200),
                  placeholder: (_, __) => Container(
                    color: Colors.grey[200],
                    child: const Center(child: TravelLoadingIndicator()),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: Colors.grey[200],
                    child: Icon(Icons.broken_image_rounded,
                        color: Colors.grey[400]),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (photoUrls.length > 1) ...[
          Positioned(
            bottom: 15,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                  photoUrls.length,
                  (index) => AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: _currentPhotoIndex == index ? 10 : 8,
                        height: _currentPhotoIndex == index ? 10 : 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _currentPhotoIndex == index
                              ? Colors.white
                              : Colors.white.withOpacity(0.4),
                        ),
                      )),
            ),
          ),
          Positioned(
            top: 15,
            right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                '${_currentPhotoIndex + 1}/${photoUrls.length}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _showFullScreenPhoto(
      BuildContext context, List<String> photoUrls, int initialIndex) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: PageView.builder(
          controller: PageController(initialPage: initialIndex),
          itemCount: photoUrls.length,
          itemBuilder: (context, index) => InteractiveViewer(
            child: Center(
              child: CachedNetworkImage(
                imageUrl: photoUrls[index],
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    ));
  }

  Widget _buildWhyRecommendedSection({
    required String? primaryType,
    required List<String> types,
    required double? rating,
    required int? priceLevel,
  }) {
    double? distMeters;
    if (widget.lat != null &&
        widget.lng != null &&
        widget.userLat != null &&
        widget.userLng != null) {
      distMeters = Geolocator.distanceBetween(
        widget.userLat!,
        widget.userLng!,
        widget.lat!,
        widget.lng!,
      );
    }

    final recScore = UserPreferenceService.instance.recommendationScore(
      primaryType: primaryType,
      allTypes: types,
      rating: rating,
      distanceMeters: distMeters,
      priceLevel: priceLevel,
      originType: RecommendationOriginType.gps,
    );

    final expl = recScore.explanation;
    if (expl == null || expl.explanationReasons.isEmpty) {
      return const SizedBox.shrink();
    }

    return WhyRecommendedCard(
      matchTier: expl.matchTier,
      explanationReasons: expl.explanationReasons,
    );
  }

  Widget _buildActionButton(
    IconData icon,
    String label,
    bool isAvailable, {
    VoidCallback? onTap,
    String? semanticLabel,
    String? disabledSemanticLabel,
    String? tooltip,
  }) {
    final effectiveLabel = isAvailable
        ? (semanticLabel ?? label)
        : (disabledSemanticLabel ?? '$label unavailable');
    final effectiveTooltip = tooltip ?? label;

    return Semantics(
      button: true,
      enabled: isAvailable,
      label: effectiveLabel,
      excludeSemantics: true,
      child: Tooltip(
        message: effectiveTooltip,
        child: Opacity(
          opacity: isAvailable ? 1.0 : 0.3,
          child: InkWell(
            onTap: isAvailable ? onTap : null,
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.blue[50],
                      child: Icon(icon, color: Colors.blue[600]),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildInfoSection(IconData icon, String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.grey[600], size: 20),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                const SizedBox(height: 4),
                SelectableText(
                  content,
                  style: const TextStyle(fontSize: 15, height: 1.4),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.copy_rounded, size: 18, color: Colors.grey[500]),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _copyToClipboard(content, title),
          ),
        ],
      ),
    );
  }

  Widget _buildOpeningHours(List<dynamic> weekdayDescriptions) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.access_time_filled, color: Colors.grey[600], size: 20),
          const SizedBox(width: 15),
          Expanded(
            child: Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: const Text("Opening Hours",
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 10),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: weekdayDescriptions
                    .map((desc) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(desc.toString(),
                              style: TextStyle(
                                  color: Colors.grey[700], fontSize: 14)),
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Review filter chips ──────────────────────────────────────
  // Options are built from the small sample Google returns (max 5),
  // so counts here reflect that sample, not the place's true rating
  // distribution.
  Widget _buildReviewFilterChips(Map<int, int> counts, int total) {
    final options = <int?>[null, 5, 4, 3, 2, 1];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: options.map((star) {
          final isSelected = _reviewFilterStars == star;
          final count = star == null ? total : (counts[star] ?? 0);
          final label = star == null ? 'All ($total)' : '$star★ ($count)';
          final disabled = star != null && count == 0;

          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: 12)),
              selected: isSelected,
              onSelected: disabled
                  ? null
                  : (_) => setState(() => _reviewFilterStars = star),
              selectedColor: Colors.black,
              labelStyle: TextStyle(
                color: isSelected
                    ? Colors.white
                    : (disabled ? Colors.grey[300] : Colors.black87),
              ),
              backgroundColor: Colors.grey[100],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide.none,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildReviewSortButton() {
    const labels = {
      'relevant': 'Most relevant',
      'highest': 'Highest rated',
      'lowest': 'Lowest rated',
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<String>(
        initialValue: _reviewSort,
        onSelected: (v) => setState(() => _reviewSort = v),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        itemBuilder: (_) => labels.entries
            .map((e) => PopupMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort_rounded, size: 16, color: Colors.grey[600]),
            const SizedBox(width: 4),
            Text(labels[_reviewSort]!,
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                    fontWeight: FontWeight.w600)),
            Icon(Icons.arrow_drop_down_rounded, color: Colors.grey[600]),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewItem(Map<String, dynamic> review) {
    final authorName =
        review['authorAttribution']?['displayName'] ?? 'Anonymous';
    final photoUrl = review['authorAttribution']?['photoUri'];
    final rating = review['rating'] ?? 0;
    final text = review['text']?['text'] ?? '';
    final timeDesc = review['relativePublishTimeDescription'] ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: Colors.blue[100],
              backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
              child: photoUrl == null
                  ? Text(authorName[0],
                      style: const TextStyle(color: Colors.blue))
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(authorName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(timeDesc,
                      style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                ],
              ),
            ),
            Row(
              children: List.generate(
                  5,
                  (index) => Icon(
                        Icons.star,
                        size: 14,
                        color:
                            index < rating ? Colors.orange : Colors.grey[300],
                      )),
            ),
          ]),
          const SizedBox(height: 12),
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 14, color: Colors.black87, height: 1.5),
          ),
        ],
      ),
    );
  }

  Future<void> _launchPhone(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Unable to make a call')));
    }
  }

  Future<void> _launchWebsite(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open website')));
    }
  }

  void _sharePlace(String name, String address, String? website) {
    final text = website != null
        ? 'Check out this place: $name\nAddress: $address\n$website'
        : 'Check out this place: $name\nAddress: $address';
    Share.share(text);
  }
}
