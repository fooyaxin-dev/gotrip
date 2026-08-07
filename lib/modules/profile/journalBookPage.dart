import 'package:flutter/material.dart';
import 'package:page_flip/page_flip.dart';

import '../../services/history_service.dart'; // TripHistory / HistoryEntry live here
import '../../services/journalMeta_service.dart';
import 'package:intl/intl.dart';
import 'journalPage.dart';

const _kJournalAccents = [
  [Color(0xFF2E7D32), Color(0xFFF9A825)], // green -> amber
  [Color(0xFF00796B), Color(0xFF26C6DA)],
  [Color(0xFFAD1457), Color(0xFFFF7043)],
  [Color(0xFF1565C0), Color(0xFF42A5F5)],
  [Color(0xFF6A1B9A), Color(0xFFEC407A)],
];

// One entry = one calendar day's worth of stops from one itinerary.
// A multi-day itinerary produces several of these (one per day visited),
// so the book always reads as "a day per page" — see chat for why.
class _JournalDayPage {
  final String itineraryId;
  final String itineraryTitle;
  final DateTime day;
  final List<HistoryEntry> places;
  final String? coverPhoto;
  final int dayIndex; // 1-based index of this day within its itinerary
  final int dayCount; // total days this itinerary spans

  _JournalDayPage({
    required this.itineraryId,
    required this.itineraryTitle,
    required this.day,
    required this.places,
    required this.dayIndex,
    required this.dayCount,
    this.coverPhoto,
  });
}

List<_JournalDayPage> _buildDayPages(List<TripHistory> trips) {
  final pages = <_JournalDayPage>[];

  for (final trip in trips) {
    final byDay = <DateTime, List<HistoryEntry>>{};
    for (final p in trip.places) {
      final key = DateTime(p.visitedAt.year, p.visitedAt.month, p.visitedAt.day);
      byDay.putIfAbsent(key, () => []).add(p);
    }

    final sortedDays = byDay.keys.toList()..sort();
    for (int i = 0; i < sortedDays.length; i++) {
      final day = sortedDays[i];
      final dayPlaces = byDay[day]!..sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
      final cover = dayPlaces
          .firstWhere((p) => p.photoUrl != null && p.photoUrl!.isNotEmpty,
              orElse: () => dayPlaces.first)
          .photoUrl;

      pages.add(_JournalDayPage(
        itineraryId: trip.itineraryId,
        itineraryTitle: trip.itineraryTitle,
        day: day,
        places: dayPlaces,
        coverPhoto: cover,
        dayIndex: i + 1,
        dayCount: sortedDays.length,
      ));
    }
  }

  return pages;
}

class JournalBookPage extends StatefulWidget {
  final List<TripHistory> trips;
  // Which itinerary to open the book on — the book jumps to that
  // itinerary's *first* day-page. (Trips can now span several pages,
  // so a single page index isn't a stable way to say "open this trip".)
  final String initialItineraryId;
  // true when opened via "View All" (all trips); false when opened from
  // a single trip card (trips will just be that one trip). Only changes
  // the closing page's message.
  final bool isOverall;

  const JournalBookPage({
    super.key,
    required this.trips,
    required this.initialItineraryId,
    this.isOverall = false,
  });

  @override
  State<JournalBookPage> createState() => _JournalBookPageState();
}

class _JournalBookPageState extends State<JournalBookPage> {
  final GlobalKey<PageFlipWidgetState> _controller = GlobalKey<PageFlipWidgetState>();
  late final List<_JournalDayPage> _dayPages;
  late int _initialIndex;
  late int _currentPage;

  // One batch read for the whole book instead of one per page — see chat.
  Map<String, JournalDayMeta> _metaByDocId = {};
  bool _metaLoaded = false;

  @override
  void initState() {
    super.initState();
    _dayPages = _buildDayPages(widget.trips);
    _initialIndex = _dayPages.indexWhere((p) => p.itineraryId == widget.initialItineraryId);
    if (_initialIndex < 0) _initialIndex = 0;
    _currentPage = _initialIndex;
    _loadAllMeta();
  }

  // Overall book gets a table-of-contents as page 0; single-trip books don't.
  int get _pageOffset => widget.isOverall ? 1 : 0;
  int get _totalPages => _dayPages.length + _pageOffset;

  Future<void> _loadAllMeta() async {
    final meta = await JournalMetaService.instance.fetchAllMeta();
    if (!mounted) return;
    setState(() {
      _metaByDocId = meta;
      _metaLoaded = true;
    });

    // Overall book always opens on the Contents page (index 0) — no
    // auto-jump. Only single-trip books jump straight to their one trip.
    if (widget.isOverall) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _initialIndex + _pageOffset;
      if (target > 0) {
        _controller.currentState?.goToPage(target);
      }
    });
  }

  void _jumpToDayPage(int dayPageIndex) {
    final target = dayPageIndex + _pageOffset;
    _controller.currentState?.goToPage(target);
    setState(() => _currentPage = target); // page_flip has no onPageChanged, so track it ourselves
  }

  // Rough swipe-direction tracker — page_flip doesn't expose a page-change
  // callback (confirmed: only goToPage() is public), so this is an estimate
  // based on drag distance/direction, not a true "did the flip complete"
  // signal. Using Listener (not GestureDetector) so it only observes raw
  // pointer events and never competes with the package's own drag handling.
  double? _dragStartX;

  void _onPointerDown(PointerDownEvent e) => _dragStartX = e.position.dx;

  void _onPointerUp(PointerUpEvent e) {
    final startX = _dragStartX;
    _dragStartX = null;
    if (startX == null) return;
    final delta = e.position.dx - startX;
    if (delta.abs() < 40) return; // too small to count as a page turn
    setState(() {
      if (delta < 0) {
        _currentPage = (_currentPage + 1).clamp(0, _totalPages - 1);
      } else {
        _currentPage = (_currentPage - 1).clamp(0, _totalPages - 1);
      }
    });
  }

  Color _accentForItinerary(String itineraryId) =>
      _kJournalAccents[itineraryId.hashCode.abs() % _kJournalAccents.length].first;

  List<Color> _accentPairForItinerary(String itineraryId) =>
      _kJournalAccents[itineraryId.hashCode.abs() % _kJournalAccents.length];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2B231C), // dark "desk" backdrop so the book pops
      body: SafeArea(
        child: !_metaLoaded
            ? const Center(child: CircularProgressIndicator(color: Colors.white70))
            : Stack(
                children: [
                  Listener(
                    onPointerDown: _onPointerDown,
                    onPointerUp: _onPointerUp,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
                      child: PageFlipWidget(
                      key: _controller,
                      backgroundColor: const Color(0xFF2B231C),
                      lastPage: _buildLastPage(),
                      children: [
                        if (widget.isOverall) _buildTocPage(),
                        for (final dp in _dayPages)
                          JournalPage(
                            itineraryId: dp.itineraryId,
                            title: dp.itineraryTitle,
                            date: dp.day,
                            places: dp.places,
                            autoCoverPhoto: dp.coverPhoto,
                            accent: _accentPairForItinerary(dp.itineraryId),
                            dayBadge: dp.dayCount > 1 ? 'DAY ${dp.dayIndex}/${dp.dayCount}' : null,
                            // only editable from a trip's own journal, not from "View All"
                            editable: !widget.isOverall,
                            // pre-resolved from the single batch read below — no per-page
                            // Firestore fetch, no "auto content then pop to custom" flash
                            initialPhotos: _metaByDocId[
                                JournalMetaService.instance.docId(dp.itineraryId, dp.day)]?.photos,
                            initialNotes: _metaByDocId[
                                JournalMetaService.instance.docId(dp.itineraryId, dp.day)]?.notes,
                          ),
                      ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    left: 8,
                    child: _RoundIconButton(
                      icon: Icons.close,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 12,
                    child: _buildPageCounter(_totalPages),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildPageCounter(int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${_currentPage + 1} / $total',
        style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  // One row per TRIP (itineraryId), not per day-page — tapping a row jumps
  // to that trip's first day. Order follows _dayPages' order (trips
  // newest-first, from HistoryService.fetchGrouped's sort).
  List<MapEntry<String, List<_JournalDayPage>>> _tripGroupsForToc() {
    final groups = <String, List<_JournalDayPage>>{};
    for (final dp in _dayPages) {
      groups.putIfAbsent(dp.itineraryId, () => []).add(dp);
    }
    return groups.entries.toList();
  }

  Widget _buildTocPage() {
    final tripGroups = _tripGroupsForToc();

    return Container(
      color: const Color(0xFFF6EEDD),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Contents',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF2B2118))),
              const SizedBox(height: 4),
              Text('${tripGroups.length} trip${tripGroups.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: Colors.brown.shade400)),
              const SizedBox(height: 18),
              Expanded(
                child: ListView.separated(
                  itemCount: tripGroups.length,
                  separatorBuilder: (_, __) => Divider(color: Colors.brown.withOpacity(0.15), height: 20),
                  itemBuilder: (_, i) {
                    final days = tripGroups[i].value;
                    final firstDay = days.first;
                    final lastDay = days.last;
                    final totalPlaces = days.fold<int>(0, (sum, d) => sum + d.places.length);
                    final accent = _accentForItinerary(firstDay.itineraryId);
                    final dateLabel = days.length > 1
                        ? '${DateFormat('d MMM').format(firstDay.day)} – ${DateFormat('d MMM yyyy').format(lastDay.day)}'
                        : DateFormat('d MMM yyyy').format(firstDay.day);
                    final firstDayIndexInBook = _dayPages.indexOf(firstDay);

                    return InkWell(
                      onTap: () => _jumpToDayPage(firstDayIndexInBook),
                      child: Row(
                        children: [
                          Container(
                            width: 8, height: 8,
                            margin: const EdgeInsets.only(right: 10),
                            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  firstDay.itineraryTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF2B2118)),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$dateLabel'
                                  '${days.length > 1 ? ' · ${days.length} days' : ''}'
                                  ' · $totalPlaces place${totalPlaces == 1 ? '' : 's'}',
                                  style: TextStyle(fontSize: 11, color: Colors.brown.shade400),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, size: 18, color: Colors.brown.shade300),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLastPage() {
    final message = widget.isOverall
        ? "That's every trip so far.\nGo make the next page. ✈"
        : "That's this trip, page by page.\nBack to make more memories. ✈";
    return Container(
      color: const Color(0xFFF6EEDD),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, color: Color(0xFF2B2118), height: 1.6),
          ),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white70, size: 18),
      ),
    );
  }
}