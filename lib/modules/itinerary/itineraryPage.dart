// pages/itinerary/itinerary_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../../services/userPreference_service.dart';
import '../itinerary/itineraryGeneratePage.dart';
import 'itineraryDetail.dart';

class ItineraryPage extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onPlanTrip; 
  const ItineraryPage({super.key, this.onBack, this.onPlanTrip});

  @override
  State<ItineraryPage> createState() => _ItineraryPageState();
}

class _ItineraryPageState extends State<ItineraryPage> {
  List<ItineraryModel> _itineraries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await ItineraryService.instance.fetchAll();
    if (mounted) setState(() { _itineraries = list; _loading = false; });
  }

  Future<void> _delete(ItineraryModel item) async {
    await ItineraryService.instance.delete(item.id);
    setState(() => _itineraries.remove(item));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Itinerary deleted'),
            behavior: SnackBarBehavior.floating),
      );
    }
  }

  // Build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8F6FF),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Colors.black87, size: 20),
          onPressed: () {
            if (widget.onBack != null) {
              widget.onBack!();
            } else {
              Navigator.pop(context);
            }
          },
        ),
        title: const Text('My Itineraries',
            style: TextStyle(color: Colors.black87, fontSize: 18,
                fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF7C4DFF)),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _itineraries.isEmpty
              ? _buildEmpty()
              : _buildList(),
    );
  }

  // Empty state
  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF7C4DFF).withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.map_outlined,
                size: 56, color: Color(0xFF7C4DFF)),
          ),
          const SizedBox(height: 20),
          const Text('No itineraries yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E))),
          const SizedBox(height: 8),
          Text('Tap the button below to plan your first trip',
              style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: _goGenerate, 
            icon: const Icon(Icons.auto_awesome_rounded),
            label: const Text('Plan a Trip'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C4DFF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ],
      ),
    );
  }


  // List
  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: _itineraries.length,
      itemBuilder: (_, i) => _buildCard(_itineraries[i]),
    );
  }

  Widget _buildCard(ItineraryModel item) {
    final totalPlaces = item.days.fold<int>(
        0, (sum, d) => sum + d.places.length);

    String? firstPhoto;
    for (final day in item.days) {
      for (final place in day.places) {
        if (place.photoUrl != null && place.photoUrl!.isNotEmpty) {
          firstPhoto = place.photoUrl;
          break;
        }
      }
      if (firstPhoto != null) break;
    }

    return GestureDetector(
      onTap: () async {
        final saved = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
              builder: (_) => ItineraryDetailPage(itinerary: item)),
        );
        if (saved == true) _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06),
              blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // Photo banner
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20)),
              child: SizedBox(
                height: 140,
                width: double.infinity,
                child: firstPhoto != null
                    ? Image.network(firstPhoto, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _bannerPlaceholder())
                    : _bannerPlaceholder(),
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(item.title,
                            style: const TextStyle(fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A1A2E))),
                      ),
                      GestureDetector(
                        onTap: () => _confirmDelete(item),
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
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _chip(Icons.calendar_today_rounded, item.startDate),
                      const SizedBox(width: 8),
                      _chip(Icons.wb_sunny_outlined,
                          '${item.totalDays} ${item.totalDays == 1 ? "day" : "days"}'),
                      const SizedBox(width: 8),
                      _chip(Icons.place_rounded, '$totalPlaces places'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Created ${DateFormat('MMM dd, yyyy').format(item.createdAt)}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bannerPlaceholder() => Container(
    color: const Color(0xFF7C4DFF).withOpacity(0.08),
    child: const Center(
      child: Icon(Icons.map_rounded, size: 48, color: Color(0xFF7C4DFF)),
    ),
  );

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF7C4DFF).withOpacity(0.07),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: const Color(0xFF7C4DFF)),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(fontSize: 11,
                  color: Color(0xFF5E35B1),
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }


  // Actions
  void _confirmDelete(ItineraryModel item) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Itinerary',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Delete "${item.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () { Navigator.pop(context); _delete(item); },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Delete',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _goGenerate() async {
    await UserPreferenceService.instance.load();
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const GenerateItineraryPage(),
      ),
    );
    _load(); // generate page pop 回来就 reload
  }

}