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
      final key =
          DateTime(p.visitedAt.year, p.visitedAt.month, p.visitedAt.day);
      byDay.putIfAbsent(key, () => []).add(p);
    }

    final sortedDays = byDay.keys.toList()..sort();
    for (int i = 0; i < sortedDays.length; i++) {
      final day = sortedDays[i];
      final dayPlaces = byDay[day]!
        ..sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
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
  // Optional metadata loader injected for test observation and verification.
  // Defaults to JournalMetaService.instance.fetchAllMeta in production.
  final Future<Map<String, JournalDayMeta>> Function()? metaLoader;

  const JournalBookPage({
    super.key,
    required this.trips,
    required this.initialItineraryId,
    this.isOverall = false,
    this.metaLoader,
  });

  @override
  State<JournalBookPage> createState() => _JournalBookPageState();
}

class _JournalBookPageState extends State<JournalBookPage> {
  final GlobalKey<PageFlipWidgetState> _controller =
      GlobalKey<PageFlipWidgetState>();
  late final List<_JournalDayPage> _dayPages;
  late int _initialIndex;
  late int _currentPage;

  // One batch read for the whole book instead of one per page — see chat.
  // Starts null (not yet loaded); empty map after a failed/empty load.
  Map<String, JournalDayMeta>? _metaByDocId;

  // Small non-blocking error flag shown if metadata load fails.
  bool _metaFailed = false;

  // Track the wall-clock start time for perf traces.
  late final DateTime _loadStart;

  @override
  void initState() {
    super.initState();
    _loadStart = DateTime.now();
    _dayPages = _buildDayPages(widget.trips);
    _initialIndex =
        _dayPages.indexWhere((p) => p.itineraryId == widget.initialItineraryId);
    if (_initialIndex < 0) _initialIndex = 0;
    // When isOverall=true ("View All"), always start on the Table of Contents (page 0).
    // When isOverall=false (single trip), open that trip's first day-page.
    _currentPage = widget.isOverall ? 0 : _initialIndex;

    debugPrint(
      '[JOURNAL_PERF][LOAD_START] dayPageCount=${_dayPages.length} isOverall=${widget.isOverall}',
    );

    // Book is built immediately from History fallback data; metadata
    // loads in the background and updates affected pages when ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.isOverall && _totalPages > 0 && _initialIndex > 0) {
        _controller.currentState
            ?.goToPage(_initialIndex.clamp(0, _totalPages - 1));
      }
      currentPage.value = -1;
      final visibleMs = DateTime.now().difference(_loadStart).inMilliseconds;
      debugPrint(
        '[JOURNAL_PERF][BOOK_VISIBLE] elapsedMs=$visibleMs source=history_fallback',
      );
      _loadAllMeta();
    });
  }

  // Overall book gets a table-of-contents as page 0; single-trip books don't.
  int get _pageOffset => widget.isOverall ? 1 : 0;
  int get _totalPages => _dayPages.length + _pageOffset;

  Future<void> _loadAllMeta() async {
    try {
      final fetcher =
          widget.metaLoader ?? JournalMetaService.instance.fetchAllMeta;
      final meta = await fetcher();
      if (!mounted) return;
      final elapsed = DateTime.now().difference(_loadStart).inMilliseconds;
      debugPrint(
        '[JOURNAL_PERF][META_READY] elapsedMs=$elapsed metaDocCount=${meta.length}',
      );
      setState(() {
        _metaByDocId = meta;
        _metaFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      final elapsed = DateTime.now().difference(_loadStart).inMilliseconds;
      debugPrint(
        '[JOURNAL_PERF][META_FAILED] elapsedMs=$elapsed action=keep_history_fallback',
      );
      setState(() {
        _metaByDocId = {}; // empty — pages continue showing History fallback
        _metaFailed = true;
      });
    }
  }

  void _jumpToDayPage(int dayPageIndex) {
    final target = dayPageIndex + _pageOffset;
    _controller.currentState?.goToPage(target);
    currentPage.value = -1;
    if (_currentPage != target) {
      setState(() => _currentPage = target);
      final activeWindow = _activePhotoPageIndexes(target);
      debugPrint(
        '[JOURNAL_PERF][PAGE_ACTIVE] pageIndex=$target '
        'dayIndex=$dayPageIndex activePhotoPageIndexes=$activeWindow',
      );
    }
  }

  /// Called when PageFlipWidget successfully completes a flip animation.
  /// Cancelled or small drags do not trigger onPageFlipped in the package,
  /// ensuring _currentPage only changes upon verified page transitions.
  void _onPageFlipped(int pageNumber) {
    if (_currentPage != pageNumber) {
      setState(() => _currentPage = pageNumber);
      final dayIndex = pageNumber - _pageOffset;
      final activeWindow = _activePhotoPageIndexes(pageNumber);
      debugPrint(
        '[JOURNAL_PERF][PAGE_ACTIVE] pageIndex=$pageNumber '
        'dayIndex=$dayIndex activePhotoPageIndexes=$activeWindow',
      );
    }
  }

  Color _accentForItinerary(String itineraryId) =>
      _kJournalAccents[itineraryId.hashCode.abs() % _kJournalAccents.length]
          .first;

  List<Color> _accentPairForItinerary(String itineraryId) =>
      _kJournalAccents[itineraryId.hashCode.abs() % _kJournalAccents.length];

  /// Returns the set of book-page indexes near the current page (for logging).
  /// Photo loading is no longer gated by this window — all day-page thumbnails
  /// load progressively with bounded decode (260×260) once the book is mounted.
  /// The page_flip package does not expose reliable per-page priority scheduling,
  /// so all pages receive photoLoadingEnabled=true.
  Set<int> _activePhotoPageIndexes(int currentBookPage) {
    return {
      currentBookPage - 1,
      currentBookPage,
      currentBookPage + 1,
    }.where((i) => i >= 0 && i < _totalPages).toSet();
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      backgroundColor:
          const Color(0xFF2B231C), // dark "desk" backdrop so the book pops
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
              child: PageFlipWidget(
                key: _controller,
                backgroundColor: const Color(0xFF2B231C),
                initialIndex: widget.isOverall
                    ? 0
                    : (_totalPages > 0
                        ? _initialIndex.clamp(0, _totalPages - 1)
                        : 0),
                onPageFlipped: _onPageFlipped,
                lastPage: _buildLastPage(),
                children: [
                  if (widget.isOverall) _buildTocPage(),
                  for (int di = 0; di < _dayPages.length; di++) ...[
                    _buildDayJournalPage(di),
                  ],
                ],
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
            // Non-blocking metadata error chip — shown only in the top area
            // so the book remains fully usable.
            if (_metaFailed)
              Positioned(
                top: 4,
                left: 52,
                child: _MetaRetryChip(onRetry: () {
                  setState(() {
                    _metaFailed = false;
                    _metaByDocId = null;
                  });
                  _loadAllMeta();
                }),
              ),
          ],
        ),
      ),
    );
  }

  /// Build one journal day-page widget.
  /// All day pages load thumbnails progressively with bounded decode (260×260).
  /// Full-resolution images are only loaded when the full-screen viewer opens.
  Widget _buildDayJournalPage(int dayIndex) {
    final dp = _dayPages[dayIndex];

    // Resolve metadata: if not yet loaded, pass null (History fallback).
    // Once loaded, look up the curated metadata for this day.
    final docId = JournalMetaService.instance.docId(dp.itineraryId, dp.day);
    final meta = _metaByDocId?[docId];

    // Use a stable key based on identity (itineraryId + date) so that
    // ordinary parent rebuilds (e.g. page counter update) do not restart
    // image downloads for the same page.
    return KeyedSubtree(
      key: ValueKey('${dp.itineraryId}_${dp.day.millisecondsSinceEpoch}'),
      child: JournalPage(
        itineraryId: dp.itineraryId,
        title: dp.itineraryTitle,
        date: dp.day,
        places: dp.places,
        autoCoverPhoto: dp.coverPhoto,
        accent: _accentPairForItinerary(dp.itineraryId),
        dayBadge: dp.dayCount > 1 ? 'DAY ${dp.dayIndex}/${dp.dayCount}' : null,
        // only editable from a trip's own journal, not from "View All"
        editable: !widget.isOverall,
        // Pre-resolved from the batch read; null until metadata arrives
        // (page shows History fallback while loading).
        initialPhotos: meta?.photos,
        initialNotes: meta?.notes,
        photoLoadingEnabled: true,
      ),
    );
  }

  Widget _buildPageCounter(int total) {
    final displayPage = total > 0 ? (_currentPage + 1).clamp(1, total) : 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$displayPage / $total',
        style: const TextStyle(
            color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
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
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2B2118))),
              const SizedBox(height: 4),
              Text(
                  '${tripGroups.length} trip${tripGroups.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: Colors.brown.shade400)),
              const SizedBox(height: 18),
              Expanded(
                child: ListView.separated(
                  itemCount: tripGroups.length,
                  separatorBuilder: (_, __) => Divider(
                      color: Colors.brown.withOpacity(0.15), height: 20),
                  itemBuilder: (_, i) {
                    final days = tripGroups[i].value;
                    final firstDay = days.first;
                    final lastDay = days.last;
                    final totalPlaces =
                        days.fold<int>(0, (sum, d) => sum + d.places.length);
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
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 10),
                            decoration: BoxDecoration(
                                color: accent, shape: BoxShape.circle),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  firstDay.itineraryTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF2B2118)),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$dateLabel'
                                  '${days.length > 1 ? ' · ${days.length} days' : ''}'
                                  ' · $totalPlaces place${totalPlaces == 1 ? '' : 's'}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.brown.shade400),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              size: 18, color: Colors.brown.shade300),
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
            style: const TextStyle(
                fontSize: 16, color: Color(0xFF2B2118), height: 1.6),
          ),
        ),
      ),
    );
  }
}

// Small non-blocking chip shown when the background metadata fetch fails.
// Tapping retries the load without disrupting the visible journal pages.
class _MetaRetryChip extends StatelessWidget {
  final VoidCallback onRetry;
  const _MetaRetryChip({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRetry,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.refresh, size: 12, color: Colors.white70),
            SizedBox(width: 4),
            Text('Sync', style: TextStyle(fontSize: 11, color: Colors.white70)),
          ],
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
        decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12), shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white70, size: 18),
      ),
    );
  }
}
