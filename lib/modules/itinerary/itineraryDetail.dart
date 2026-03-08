// pages/itinerary/itinerary_detail_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../itinerary/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../../services/location_service.dart';
import '../place/placeDetailPage.dart';
import '../place/detectPlacePage.dart';

class ItineraryDetailPage extends StatefulWidget {
  final ItineraryModel itinerary;
  const ItineraryDetailPage({super.key, required this.itinerary});

  @override
  State<ItineraryDetailPage> createState() => _ItineraryDetailPageState();
}

class _ItineraryDetailPageState extends State<ItineraryDetailPage>
    with SingleTickerProviderStateMixin {

  late ItineraryModel _itinerary;
  late TabController _tabController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _itinerary = widget.itinerary;
    _tabController = TabController(
        length: _itinerary.totalDays, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
        const SnackBar(content: Text('✅ Itinerary saved!'),
            behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _removePlace(int dayIndex, int placeIndex) {
    final days    = List<ItineraryDay>.from(_itinerary.days);
    final places  = List<ItineraryPlace>.from(days[dayIndex].places);
    places.removeAt(placeIndex);
    days[dayIndex] = days[dayIndex].copyWith(places: places);
    setState(() => _itinerary = _itinerary.copyWith(days: days));
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
  // Sliver Header
  // ─────────────────────────────────────────────

  Widget _buildSliverHeader() {
    return SliverAppBar(
      expandedHeight: 200,
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
                  const Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded,
                          color: Colors.white70, size: 14),
                      SizedBox(width: 6),
                      Text('AI Generated Itinerary',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_itinerary.title,
                      style: const TextStyle(color: Colors.white, fontSize: 26,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    '${_itinerary.totalDays} ${_itinerary.totalDays == 1 ? "day" : "days"} · '
                    'Starting ${_itinerary.startDate}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
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
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        tabs: List.generate(_itinerary.totalDays, (i) {
          final day  = _itinerary.days.length > i ? _itinerary.days[i] : null;
          final date = day != null
              ? DateFormat('MMM dd').format(DateTime.parse(day.date))
              : 'Day ${i + 1}';
          return Tab(text: 'Day ${i + 1}\n$date');
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
            Icon(Icons.add_location_alt_outlined, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text('No places yet', style: TextStyle(color: Colors.grey[500])),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      onReorder: (old, neo) => _reorderPlaces(dayIndex, old, neo),
      itemCount: day.places.length,
      itemBuilder: (_, i) {
        return _buildPlaceCard(day.places[i], dayIndex, i,
            key: ValueKey('${dayIndex}_$i'));
      },
    );
  }

  // ─────────────────────────────────────────────
  // Place Card
  // ─────────────────────────────────────────────

  Widget _buildPlaceCard(ItineraryPlace place, int dayIndex, int placeIndex,
      {required Key key}) {
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06),
            blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        children: [
          // Top row: time + drag handle + delete
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C4DFF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    const Icon(Icons.access_time_rounded,
                        size: 12, color: Color(0xFF7C4DFF)),
                    const SizedBox(width: 4),
                    Text(place.suggestedTime,
                        style: const TextStyle(fontSize: 12,
                            color: Color(0xFF7C4DFF),
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${place.durationMinutes} min',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ),
                const Spacer(),
                // Delete button
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
                // Drag handle
                const Icon(Icons.drag_handle_rounded,
                    color: Colors.grey, size: 20),
              ],
            ),
          ),

          // Place info row
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Photo
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: place.photoUrl != null
                      ? Image.network(place.photoUrl!,
                          width: 70, height: 70, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholderImg())
                      : _placeholderImg(),
                ),
                const SizedBox(width: 14),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(place.name,
                          style: const TextStyle(fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A2E)),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(place.address,
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (place.notes != null) ...[
                        const SizedBox(height: 6),
                        Text(place.notes!,
                            style: TextStyle(fontSize: 11,
                                color: Colors.grey[600],
                                fontStyle: FontStyle.italic),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: _actionBtn(
                    icon:  Icons.info_outline_rounded,
                    label: 'Details',
                    color: const Color(0xFF7C4DFF),
                    onTap: () => _openDetail(place),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _actionBtn(
                    icon:  Icons.navigation_rounded,
                    label: 'Navigate',
                    color: const Color(0xFF2ECC71),
                    onTap: () => _navigate(place),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholderImg() => Container(
    width: 70, height: 70,
    decoration: BoxDecoration(
      color: Colors.grey[100],
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(Icons.location_on_rounded, color: Colors.grey[300], size: 30),
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
            Text(label, style: TextStyle(fontSize: 12,
                color: color, fontWeight: FontWeight.w600)),
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
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06),
            blurRadius: 12, offset: const Offset(0, -4))],
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
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.save_rounded, size: 18),
                    SizedBox(width: 8),
                    Text('Save Itinerary',
                        style: TextStyle(fontSize: 15,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Actions
  // ─────────────────────────────────────────────

  void _confirmRemove(int dayIndex, int placeIndex) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Remove Place',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Remove this place from your itinerary?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
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
    final pos = LocationService.instance.currentPosition;
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
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => RealTimeDetectPage(
        landmarkLat: place.lat!,
        landmarkLng: place.lng!,
        onBack: () => Navigator.pop(context),
      ),
    ));
  }
}