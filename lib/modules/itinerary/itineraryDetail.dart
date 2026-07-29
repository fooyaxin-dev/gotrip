// pages/itinerary/itinerary_detail_page.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../../services/history_service.dart';
import '../../services/location_service.dart';
import '../place/placeDetailPage.dart';
import '../place/routePreviewPage.dart';
import '../place/routeOptimizerPage.dart';
import '../../services/route_service.dart';
import '../../services/error_handler.dart';
import '../../services/achievement_service.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ItineraryDetailPage extends StatefulWidget {
  final ItineraryModel itinerary;
  const ItineraryDetailPage({super.key, required this.itinerary});

  @override
  State<ItineraryDetailPage> createState() => _ItineraryDetailPageState();
}

class _ItineraryDetailPageState extends State<ItineraryDetailPage>
    with SingleTickerProviderStateMixin {

  late ItineraryModel _itinerary;
  late TabController  _tabController;

  final Map<String, GlobalKey> _cardKeys = {};
  StreamSubscription<PlaceArrivalEvent>? _arrivalSub;

  @override
  void initState() {
    super.initState();
    _itinerary     = widget.itinerary;
    _tabController = TabController(
      length: _itinerary.days.length,
      vsync: this,
    );
    LocationService.instance.watchItinerary(_itinerary);
    _arrivalSub = LocationService.instance.arrivalStream.listen(_onArrival);
  }

  @override
  void dispose() {
    _arrivalSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Arrival handler
  // ─────────────────────────────────────────────

  void _onArrival(PlaceArrivalEvent event) {
    if (!mounted) return;

    if (_tabController.index != event.dayIndex) {
      _tabController.animateTo(event.dayIndex);
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ArrivedDialog(
        placeName: event.placeName,
        onConfirm: () {
          Navigator.pop(context);
          _markVisited(event.dayIndex, event.placeIndex);
        },
        onDismiss: () => Navigator.pop(context),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Mark visited — with achievement unlock detection
  // ─────────────────────────────────────────────

  Future<void> _markVisited(int dayIndex, int placeIndex) async {
    // ── Step 1: Snapshot achievements BEFORE the check-in ──
    final statsBefore = await AchievementService.instance.fetchStats();
    final groupsBefore = AchievementService.instance.buildGroups(statsBefore);

    // ── Step 2: Update itinerary state ──
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);

    final visited = places[placeIndex].copyWith(
      isVisited: true,
      visitedAt: DateTime.now(),
    );
    places[placeIndex] = visited;
    days[dayIndex] = days[dayIndex].copyWith(places: places);

    setState(() => _itinerary = _itinerary.copyWith(days: days));

    LocationService.instance.markArrived(visited.placeId);
    LocationService.instance.watchItinerary(_itinerary);

    // Itinerary is always already saved (non-empty id) by the time it
    // reaches this page — RouteOptimizerPage handles the initial save.
    // Every check-in just keeps Firestore in sync from here on.
    if (_itinerary.id.isNotEmpty) {
      ItineraryService.instance.update(_itinerary);
    }

    // ── Step 3: Save to history ──
    try {
      await HistoryService.instance.addEntry(
        placeName:      visited.name,
        address:        visited.address,
        photoUrl:       visited.photoUrl,
        visitedAt:      visited.visitedAt!,
        itineraryId:    _itinerary.id,
        itineraryTitle: _itinerary.title,
        placeId:        visited.placeId,
        primaryType:    visited.primaryType,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.orange[700],
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }

    _scrollToNextPlace(dayIndex);

    _cardKeys.removeWhere((key, _) =>
        !_itinerary.days.any((d) => d.places.any((p) => p.placeId == key)));

    // ── Step 4: Snapshot achievements AFTER the check-in ──
    // Small delay to let Firestore writes propagate before re-fetching.
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    AchievementService.instance.invalidateStatsCache(); 
    final statsAfter  = await AchievementService.instance.fetchStats();
    final groupsAfter = AchievementService.instance.buildGroups(statsAfter);

    // ── Step 5: Detect new unlocks & show dialog ──
    final newUnlocks = AchievementService.instance.checkForNewUnlocks(
      oldGroups: groupsBefore,
      newGroups: groupsAfter,
    );

    // Always persist the current top badge to Firestore after a check-in,
    // regardless of whether THIS check-in unlocked something new. This keeps
    // users/{uid}.topBadge* in sync even if a threshold was already crossed
    // before this write existed, or if a previous check-in's write was missed.
    if (mounted) {
      await AchievementService.instance.saveTopBadgeToFirestore();
    }

    if (newUnlocks.isNotEmpty && mounted) {
      _showUnlockDialog(newUnlocks);
    }
  }

  // ─────────────────────────────────────────────
  // Achievement unlock celebration dialog
  // ─────────────────────────────────────────────

  void _showUnlockDialog(List<NewUnlock> unlocks) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _AchievementUnlockedDialog(unlocks: unlocks),
    );
  }

  void _scrollToNextPlace(int dayIndex) {
    final day       = _itinerary.days[dayIndex];
    final nextPlace = day.nextPlace;
    if (nextPlace == null) return;

    final key = _cardKeys[nextPlace.placeId];
    if (key?.currentContext == null) return;

    Future.delayed(const Duration(milliseconds: 300), () {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        alignment: 0.15,
      );
    });
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      body: NestedScrollView(
        headerSliverBuilder: (_, __) => [_buildSliverHeader()],
        body: Column(
          children: [
            _buildTabBar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: List.generate(
                  _itinerary.totalDays,
                  (i) => _buildDayView(i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Sliver Header
  // ─────────────────────────────────────────────

  Widget _buildSliverHeader() {
    final total    = _itinerary.totalPlaces;
    final visited  = _itinerary.totalVisited;
    final progress = total == 0 ? 0.0 : visited / total;

    return SliverAppBar(
      expandedHeight: 220,
      pinned: true,
      backgroundColor: const Color(0xFF5E35B1),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new,
            color: Colors.white, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.edit_road_rounded, color: Colors.white),
          tooltip: 'Edit itinerary',
          onPressed: _editItinerary,
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, color: Colors.white),
          tooltip: 'Edit title',
          onPressed: _editTitle,
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Row(children: [
                    Icon(Icons.map_rounded,
                        color: Colors.white70, size: 14),
                    SizedBox(width: 6),
                    Text('Your Trip',
                        style: TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ]),
                  const SizedBox(height: 8),
                  Text(_itinerary.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    '${_itinerary.totalDays} '
                    '${_itinerary.totalDays == 1 ? "day" : "days"} · '
                    'Starting ${_itinerary.startDate}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation(Colors.white),
                          minHeight: 5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('$visited / $total visited',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11)),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Tab Bar
  // ─────────────────────────────────────────────

  Widget _buildTabBar() {
    return Container(
      color: Colors.white,
      child: TabBar(
        controller: _tabController,
        isScrollable: _itinerary.totalDays > 3,
        labelColor: const Color(0xFF7C4DFF),
        unselectedLabelColor: Colors.grey,
        indicatorColor: const Color(0xFF7C4DFF),
        labelStyle:
            const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        tabs: List.generate(_itinerary.totalDays, (i) {
          final day  = _itinerary.days.length > i
              ? _itinerary.days[i]
              : null;
          final date = day != null
              ? DateFormat('MMM dd').format(DateTime.parse(day.date))
              : 'Day ${i + 1}';
          final isComplete = day?.isCompleted ?? false;
          return Tab(
              text: '${isComplete ? "✅ " : ""}Day ${i + 1}\n$date');
        }),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Day View
  // ─────────────────────────────────────────────

  Widget _buildDayView(int dayIndex) {
    if (dayIndex >= _itinerary.days.length) {
      return const Center(child: Text('No places for this day'));
    }

    final day = _itinerary.days[dayIndex];

    if (day.places.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_location_alt_outlined,
                size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text('No places for this day',
                style: TextStyle(color: Colors.grey[500])),
          ],
        ),
      );
    }

    final nextPlace = day.nextPlace;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: day.places.length,
      itemBuilder: (_, i) {
        final place     = day.places[i];
        final isVisited = place.isVisited;
        final isNext    = !isVisited &&
            nextPlace?.placeId == place.placeId;

        _cardKeys.putIfAbsent(place.placeId, () => GlobalKey());

        return _buildPlaceCard(
          place, dayIndex, i,
          isNext:    isNext,
          isVisited: isVisited,
          key:       ValueKey('${dayIndex}_${place.placeId}'),
          cardKey:   _cardKeys[place.placeId]!,
        );
      },
    );
  }

  // ─────────────────────────────────────────────
  // Place Card
  // ─────────────────────────────────────────────

  Widget _buildPlaceCard(
    ItineraryPlace place,
    int dayIndex,
    int placeIndex, {
    required Key key,
    required GlobalKey cardKey,
    required bool isVisited,
    required bool isNext,
  }) {
    final Color borderColor = isVisited
        ? Colors.grey[300]!
        : isNext
            ? const Color(0xFF7C4DFF)
            : Colors.transparent;

    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: isVisited ? Colors.grey[50] : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor, width: isNext ? 2 : 1),
        boxShadow: isVisited
            ? []
            : [
                BoxShadow(
                  color: isNext
                      ? const Color(0xFF7C4DFF).withOpacity(0.15)
                      : Colors.black.withOpacity(0.06),
                  blurRadius: isNext ? 16 : 10,
                  offset: const Offset(0, 4),
                )
              ],
      ),
      child: Opacity(
        opacity: isVisited ? 0.5 : 1.0,
        child: Column(
          children: [

            // Next Stop banner
            if (isNext)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    vertical: 6, horizontal: 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF7C4DFF),
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: const Row(children: [
                  Icon(Icons.navigation_rounded,
                      size: 13, color: Colors.white),
                  SizedBox(width: 6),
                  Text('Next Stop',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ]),
              ),

            // Visited banner
            if (isVisited)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    vertical: 6, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18)),
                ),
                child: Row(children: [
                  Icon(Icons.check_circle_rounded,
                      size: 13, color: Colors.green[600]),
                  const SizedBox(width: 6),
                  Text(
                    'Visited${place.visitedAt != null ? "  ·  ${DateFormat('hh:mm a').format(place.visitedAt!)}" : ""}',
                    style: TextStyle(
                        color: Colors.green[700],
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ]),
              ),

            // Top row: time + duration (display only, not editable here)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(children: [
                // Time chip
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C4DFF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color:
                            const Color(0xFF7C4DFF).withOpacity(0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.access_time_rounded,
                        size: 12, color: Color(0xFF7C4DFF)),
                    const SizedBox(width: 4),
                    Text(place.suggestedTime,
                        style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF7C4DFF),
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
                const SizedBox(width: 8),

                // Duration chip
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: Row(children: [
                    Icon(Icons.timelapse_rounded,
                        size: 11, color: Colors.grey[600]),
                    const SizedBox(width: 3),
                    Text(_formatDuration(place.durationMinutes),
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[700])),
                  ]),
                ),
              ]),
            ),

            // Place info
            Padding(
              key: cardKey,
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: place.photoUrl != null
                  ? CachedNetworkImage(
                      imageUrl: place.photoUrl!,
                      width: 70, height: 70, fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _placeholderImg(),
                    )
                  : _placeholderImg(),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        place.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isVisited
                              ? Colors.grey[500]
                              : const Color(0xFF1A1A2E),
                          decoration: isVisited
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(place.address,
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey[500]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (place.notes != null) ...[
                        const SizedBox(height: 6),
                        Text(place.notes!,
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                                fontStyle: FontStyle.italic),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
              ]),
            ),

            // Action buttons
            if (!isVisited)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: [
                    Row(children: [
                      Expanded(
                        child: _actionBtn(
                          icon: Icons.info_outline_rounded,
                          label: 'Details',
                          color: const Color(0xFF7C4DFF),
                          onTap: () => _openDetail(place),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _actionBtn(
                          icon: Icons.navigation_rounded,
                          label: 'Navigate',
                          color: const Color(0xFF2ECC71),
                          onTap: () => _navigate(place),
                        ),
                      ),
                    ]),

                    // Debug only
                    if (kDebugMode) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => _onArrival(PlaceArrivalEvent(
                          placeId:    place.placeId,
                          placeName:  place.name,
                          dayIndex:   dayIndex,
                          placeIndex: placeIndex,
                        )),
                        child: Container(
                          width: double.infinity,
                          padding:
                              const EdgeInsets.symmetric(vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.orange[50],
                            borderRadius:
                                BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.orange[300]!),
                          ),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            children: [
                              Icon(Icons.bug_report_rounded,
                                  size: 13,
                                  color: Colors.orange[700]),
                              const SizedBox(width: 5),
                              Text('Simulate Arrival',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange[700],
                                      fontWeight:
                                          FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int mins) {
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}min';
  }

  Widget _placeholderImg() => Container(
        width: 70, height: 70,
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.location_on_rounded,
            color: Colors.grey[300], size: 30),
      );

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Edit itinerary — re-opens RouteOptimizerPage on this already-saved
  // itinerary so the user can still reorder/remove/move places or change
  // times mid-trip, not just at the moment it was first generated.
  // ─────────────────────────────────────────────

  Future<void> _editItinerary() async {
    double startLat;
    double startLng;
    String? startName;

    final hasStoredOrigin =
        _itinerary.originLat != null && _itinerary.originLng != null;

    if (hasStoredOrigin && _itinerary.isOriginCurrentLocation) {
      final pos = LocationService.instance.currentPosition;
      if (pos != null) {
        startLat  = pos.latitude;
        startLng  = pos.longitude;
        startName = 'Your Location';
      } else {
        startLat  = _itinerary.originLat!;
        startLng  = _itinerary.originLng!;
        startName = _itinerary.originName;
      }
    } else if (hasStoredOrigin) {
      startLat  = _itinerary.originLat!;
      startLng  = _itinerary.originLng!;
      startName = _itinerary.originName;
    } else {
      final pos = LocationService.instance.currentPosition;
      if (pos != null) {
        startLat  = pos.latitude;
        startLng  = pos.longitude;
        startName = 'Your Location';
      } else {
        final fallback = _itinerary.days
            .expand((d) => d.places)
            .where((p) => p.lat != null && p.lng != null)
            .toList();
        if (fallback.isEmpty) return;
        startLat  = fallback.first.lat!;
        startLng  = fallback.first.lng!;
        startName = null;
      }
    }

    // 🔧 不再写死 TravelMode.walk —— 读回当初存的出行方式，
    // 这样 signature 里的 travelMode 才能跟当初生成时一致，缓存才可能命中
    final resolvedTravelMode = travelModeFromString(_itinerary.travelMode);

    final updated = await Navigator.push<ItineraryModel>(
      context,
      MaterialPageRoute(
        builder: (_) => RouteOptimizerPage(
          itinerary: _itinerary,
          startLat: startLat,
          startLng: startLng,
          startLocationName: startName,
          travelMode: resolvedTravelMode,   // 🔧 CHANGED
          isEditingExisting: true,
          leftoverPlaceIds: _itinerary.leftoverPlaceIds, 
        ),
      ),
    );

    if (updated == null || !mounted) return;

    final daysChanged = updated.days.length != _itinerary.days.length;
    setState(() => _itinerary = updated);

    if (daysChanged) {
      _tabController.dispose();
      _tabController = TabController(length: _itinerary.days.length, vsync: this);
    }

    LocationService.instance.watchItinerary(_itinerary);
    _cardKeys.removeWhere((key, _) =>
        !_itinerary.days.any((d) => d.places.any((p) => p.placeId == key)));
  }

  // ─────────────────────────────────────────────
  // Dialog helpers
  // ─────────────────────────────────────────────

  void _editTitle() {
    final ctrl = TextEditingController(text: _itinerary.title);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Title',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              if (ctrl.text.trim().isNotEmpty) {
                final updated = _itinerary.copyWith(title: ctrl.text.trim());
                setState(() => _itinerary = updated);
                if (_itinerary.id.isNotEmpty) {
                  try {
                    await ItineraryService.instance.update(_itinerary);
                  } catch (e) {
                    if (mounted) {
                      ErrorHandler.showError(context, message: 'Failed to save title. Please try again.');
                    }
                  }
                }
              }
            },

            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C4DFF),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Save',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(ItineraryPlace place) async {
    final pos    = LocationService.instance.currentPosition;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceDetailPage(
          placeId: place.placeId,
          lat:     place.lat,
          lng:     place.lng,
          userLat: pos?.latitude,
          userLng: pos?.longitude,
        ),
      ),
    );
    if (result != null &&
        result['action'] == 'start_navigation' &&
        mounted) {
      _navigate(place);
    }
  }

  void _navigate(ItineraryPlace place) {
    if (place.lat == null || place.lng == null) return;

    final pos = LocationService.instance.currentPosition;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Unable to get your current location')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePreviewPage(
          startLat:        pos.latitude,
          startLng:        pos.longitude,
          endLat:          place.lat!,
          endLng:          place.lng!,
          destinationName: place.name,
        ),
      ),
    ).then((arrived) {
      if (arrived == true && mounted) {
        final dayIndex   = _tabController.index;
        final placeIndex = _itinerary.days[dayIndex].places
            .indexWhere((p) => p.placeId == place.placeId);
        if (placeIndex != -1) {
          _markVisited(dayIndex, placeIndex);
        }
      }
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Achievement unlocked celebration dialog
// ─────────────────────────────────────────────────────────────────────────────

class _AchievementUnlockedDialog extends StatelessWidget {
  final List<NewUnlock> unlocks;

  const _AchievementUnlockedDialog({required this.unlocks});

  static const _tierColors = {
    'bronze': Color(0xFFCD7F32),
    'silver': Color(0xFFA8A9AD),
    'gold':   Color(0xFFFFD700),
  };

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Trophy icon ──
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF7C4DFF).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Text('🏆', style: TextStyle(fontSize: 40)),
              ),
            ),
            const SizedBox(height: 16),

            const Text(
              'Achievement Unlocked!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              unlocks.length == 1
                  ? 'You just earned a new badge!'
                  : 'You just earned ${unlocks.length} new badges!',
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),

            // ── Unlocked badges list ──
            ...unlocks.map((u) {
              final color = _tierColors[u.tier.level] ?? const Color(0xFF7C4DFF);
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color.withOpacity(0.3)),
                ),
                child: Row(children: [
                  // Badge circle
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withOpacity(0.15),
                      border: Border.all(color: color, width: 2),
                    ),
                    child: Center(
                      child: Text(u.tier.emoji,
                          style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(u.tier.label,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold)),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              u.tier.level.toUpperCase(),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: color,
                              ),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 2),
                        Text(u.tier.desc,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                ]),
              );
            }),

            const SizedBox(height: 8),

            // ── Close button ──
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C4DFF),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('Awesome! 🎉',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Waze-style arrived dialog
// ─────────────────────────────────────────────────────────────────────────────

class _ArrivedDialog extends StatelessWidget {
  final String placeName;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;

  const _ArrivedDialog({
    required this.placeName,
    required this.onConfirm,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFF7C4DFF).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.location_on_rounded,
                  size: 36, color: Color(0xFF7C4DFF)),
            ),
            const SizedBox(height: 16),
            const Text("You've arrived! 🎉",
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              placeName,
              style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF7C4DFF),
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Are you visiting this place?',
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onDismiss,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.grey[300]!),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding:
                        const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text('Not yet',
                      style: TextStyle(color: Colors.grey[600])),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: onConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C4DFF),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding:
                        const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text("Yes, I'm here!",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}