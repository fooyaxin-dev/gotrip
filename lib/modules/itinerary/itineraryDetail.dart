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
  bool _isSaving = false;

  // For auto-scroll to next place card
  final Map<String, GlobalKey> _cardKeys = {};

  // Arrival stream subscription
  StreamSubscription<PlaceArrivalEvent>? _arrivalSub;

  @override
  void initState() {
    super.initState();
    _itinerary     = widget.itinerary;
    _tabController = TabController(length: _itinerary.totalDays, vsync: this);

    // Tell LocationService which places to watch
    LocationService.instance.watchItinerary(_itinerary);

    // Listen for arrivals
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

    // Switch to the correct day tab first
    if (_tabController.index != event.dayIndex) {
      _tabController.animateTo(event.dayIndex);
    }

    // Show Waze-style arrived dialog
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
  // Mark visited
  // ─────────────────────────────────────────────

  void _markVisited(int dayIndex, int placeIndex) {
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);

    final visited = places[placeIndex].copyWith(
      isVisited: true,
      visitedAt: DateTime.now(),
    );
    places[placeIndex] = visited;
    days[dayIndex] = days[dayIndex].copyWith(places: places);

    setState(() => _itinerary = _itinerary.copyWith(days: days));

    // Tell LocationService to stop watching this place
    LocationService.instance.markArrived(visited.placeId);

    // Update watch list with new state
    LocationService.instance.watchItinerary(_itinerary);

    // Auto-save silently
    ItineraryService.instance.update(_itinerary);

    // Write this place into history
    HistoryService.instance.addEntry(
      placeName:      visited.name,
      address:        visited.address,
      photoUrl:       visited.photoUrl,
      visitedAt:      visited.visitedAt!,
      itineraryId:    _itinerary.id,
      itineraryTitle: _itinerary.title,
    );

    // Scroll to next unvisited place
    _scrollToNextPlace(dayIndex);
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
  // CRUD helpers
  // ─────────────────────────────────────────────

  Future<void> _save() async {
    setState(() => _isSaving = true);
    await ItineraryService.instance.update(_itinerary);
    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Itinerary saved!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _removePlace(int dayIndex, int placeIndex) {
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    places.removeAt(placeIndex);
    days[dayIndex] = days[dayIndex].copyWith(places: places);
    setState(() => _itinerary = _itinerary.copyWith(days: days));
    LocationService.instance.watchItinerary(_itinerary);
  }

  void _reorderPlaces(int dayIndex, int oldIndex, int newIndex) {
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    if (newIndex > oldIndex) newIndex--;
    final item = places.removeAt(oldIndex);
    places.insert(newIndex, item);
    days[dayIndex] = days[dayIndex].copyWith(places: places);
    setState(() => _itinerary = _itinerary.copyWith(days: days));
  }

  void _updatePlace(int dayIndex, int placeIndex, ItineraryPlace updated) {
    final days   = List<ItineraryDay>.from(_itinerary.days);
    final places = List<ItineraryPlace>.from(days[dayIndex].places);
    places[placeIndex] = updated;
    // Re-sort by time after any time edit
    places.sort((a, b) => a.suggestedTime.compareTo(b.suggestedTime));
    days[dayIndex] = days[dayIndex].copyWith(places: places);
    setState(() => _itinerary = _itinerary.copyWith(days: days));
  }
  

  // ─────────────────────────────────────────────
  // Time / Duration editing
  // ─────────────────────────────────────────────

  TimeOfDay _parseTime(String t) {
    try {
      final parts = t.split(':');
      return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    } catch (_) {
      return const TimeOfDay(hour: 9, minute: 0);
    }
  }

  Future<void> _pickTime(
      int dayIndex, int placeIndex, ItineraryPlace place) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _parseTime(place.suggestedTime),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF7C4DFF),
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      final hh = picked.hour.toString().padLeft(2, '0');
      final mm = picked.minute.toString().padLeft(2, '0');
      _updatePlace(dayIndex, placeIndex,
          place.copyWith(suggestedTime: '$hh:$mm'));
    }
  }

  Future<void> _pickDuration(
      int dayIndex, int placeIndex, ItineraryPlace place) async {
    const presets = [15, 30, 45, 60, 90, 120, 150, 180, 240];
    int selected  = place.durationMinutes;

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Visit Duration',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Select how long you plan to stay',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: presets.map((mins) {
                  final isSelected = selected == mins;
                  final label = mins < 60
                      ? '$mins min'
                      : mins % 60 == 0
                          ? '${mins ~/ 60}h'
                          : '${mins ~/ 60}h ${mins % 60}min';
                  return ChoiceChip(
                    label: Text(label),
                    selected: isSelected,
                    onSelected: (_) => setSheet(() => selected = mins),
                    selectedColor: const Color(0xFF7C4DFF),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.black87,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              Row(children: [
                const Text('Custom:', style: TextStyle(fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: selected.toDouble(),
                    min: 10, max: 480, divisions: 47,
                    activeColor: const Color(0xFF7C4DFF),
                    label: selected < 60
                        ? '$selected min'
                        : '${selected ~/ 60}h ${selected % 60 == 0 ? "" : "${selected % 60}min"}',
                    onChanged: (v) => setSheet(() => selected = v.round()),
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    selected < 60
                        ? '$selected min'
                        : selected % 60 == 0
                            ? '${selected ~/ 60}h'
                            : '${selected ~/ 60}h ${selected % 60}m',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF7C4DFF)),
                    textAlign: TextAlign.end,
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C4DFF),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Confirm',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      }),
    );

    if (selected != place.durationMinutes && mounted) {
      _updatePlace(dayIndex, placeIndex,
          place.copyWith(durationMinutes: selected));
    }
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
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  // ─────────────────────────────────────────────
  // Sliver Header  (now with progress bar)
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
        icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.edit_outlined, color: Colors.white),
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
                    Icon(Icons.auto_awesome_rounded,
                        color: Colors.white70, size: 14),
                    SizedBox(width: 6),
                    Text('AI Generated Itinerary',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ]),
                  const SizedBox(height: 8),
                  Text(_itinerary.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    '${_itinerary.totalDays} ${_itinerary.totalDays == 1 ? "day" : "days"} · '
                    'Starting ${_itinerary.startDate}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 12),

                  // ── Progress bar ──
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
          final day  = _itinerary.days.length > i ? _itinerary.days[i] : null;
          final date = day != null
              ? DateFormat('MMM dd').format(DateTime.parse(day.date))
              : 'Day ${i + 1}';
          final isComplete = day?.isCompleted ?? false;
          return Tab(text: '${isComplete ? "✅ " : ""}Day ${i + 1}\n$date');
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
            Text('No places yet',
                style: TextStyle(color: Colors.grey[500])),
          ],
        ),
      );
    }

    final nextPlace = day.nextPlace;

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      onReorder: (old, neo) => _reorderPlaces(dayIndex, old, neo),
      itemCount: day.places.length,
      itemBuilder: (_, i) {
        final place     = day.places[i];
        final isVisited = place.isVisited;
        final isNext    = !isVisited && nextPlace?.placeId == place.placeId;

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
  // Place Card  —  3 states: visited / next / upcoming
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

            // ── "Next Stop" banner ──
            if (isNext)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
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

            // ── "Visited" banner ──
            if (isVisited)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(18)),
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

            // ── Top row: time + duration + delete + drag ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(children: [

                // Time chip
                GestureDetector(
                  onTap: isVisited
                      ? null
                      : () => _pickTime(dayIndex, placeIndex, place),
                  child: Container(
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
                      if (!isVisited) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.edit_rounded,
                            size: 10, color: Color(0xFF7C4DFF)),
                      ],
                    ]),
                  ),
                ),
                const SizedBox(width: 8),

                // Duration chip
                GestureDetector(
                  onTap: isVisited
                      ? null
                      : () => _pickDuration(dayIndex, placeIndex, place),
                  child: Container(
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
                      if (!isVisited) ...[
                        const SizedBox(width: 3),
                        Icon(Icons.edit_rounded,
                            size: 10, color: Colors.grey[500]),
                      ],
                    ]),
                  ),
                ),
                const Spacer(),

                if (!isVisited) ...[
                  GestureDetector(
                    onTap: () => _confirmRemove(dayIndex, placeIndex),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.delete_outline_rounded,
                          size: 16, color: Colors.red[400]),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.drag_handle_rounded,
                      color: Colors.grey, size: 20),
                ],
              ]),
            ),

            // ── Place info ──
            Padding(
              key: cardKey, // used for Scrollable.ensureVisible
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: place.photoUrl != null
                      ? Image.network(
                          place.photoUrl!,
                          width: 70, height: 70, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholderImg(),
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
                          // Strike-through when visited
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

            // ── Action buttons — hidden when visited ──
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

                    // ── DEBUG ONLY: simulate arrival without GPS ──
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
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.orange[50],
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.orange[300]!),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.bug_report_rounded,
                                  size: 13, color: Colors.orange[700]),
                              const SizedBox(width: 5),
                              Text('Simulate Arrival',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange[700],
                                      fontWeight: FontWeight.w600)),
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
  // Bottom Bar
  // ─────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, -4))
        ],
      ),
      child: SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: _isSaving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF7C4DFF),
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
          ),
          child: _isSaving
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.save_rounded, size: 18),
                    SizedBox(width: 8),
                    Text('Save Itinerary',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Dialog helpers
  // ─────────────────────────────────────────────

  void _confirmRemove(int dayIndex, int placeIndex) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Text('Remove Place',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Remove this place from your itinerary?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _removePlace(dayIndex, placeIndex);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Remove',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

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
            onPressed: () {
              Navigator.pop(context);
              if (ctrl.text.trim().isNotEmpty) {
                setState(() => _itinerary =
                    _itinerary.copyWith(title: ctrl.text.trim()));
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
    if (result != null && result['action'] == 'start_navigation' && mounted) {
      _navigate(place);
    }
  }

  void _navigate(ItineraryPlace place) {
    if (place.lat == null || place.lng == null) return;
    
    final pos = LocationService.instance.currentPosition;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to get your current location')),
      );
      return;
    }

    Navigator.push(context, MaterialPageRoute(
      builder: (_) => RoutePreviewPage(
        startLat:        pos.latitude,
        startLng:        pos.longitude,
        endLat:          place.lat!,
        endLng:          place.lng!,
        destinationName: place.name,
      ),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Waze-style arrived dialog  (extracted widget for cleanliness)
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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