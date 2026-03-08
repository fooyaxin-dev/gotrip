// pages/itinerary/generate_itinerary_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../itinerary/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../../services/placeModal.dart';
import '../../services/userPreference_service.dart';
import 'itineraryDetail.dart';

class GenerateItineraryPage extends StatefulWidget {
  final List<PlaceModel> nearbyPlaces;
  const GenerateItineraryPage({super.key, required this.nearbyPlaces});

  @override
  State<GenerateItineraryPage> createState() => _GenerateItineraryPageState();
}

class _GenerateItineraryPageState extends State<GenerateItineraryPage> {
  DateTime _startDate    = DateTime.now();
  int _totalDays         = 1;
  int _placesPerDay      = 4;
  bool _isGenerating     = false;
  final _titleController = TextEditingController(text: 'My Trip');

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Generate
  // ─────────────────────────────────────────────

  Future<void> _generate() async {
    if (widget.nearbyPlaces.isEmpty) {
      _showSnack('No nearby places found. Please try again.');
      return;
    }

    setState(() => _isGenerating = true);

    try {
      final itinerary = await ItineraryService.instance.generate(
        nearbyPlaces: widget.nearbyPlaces,
        startDate:    DateFormat('yyyy-MM-dd').format(_startDate),
        totalDays:    _totalDays,
        placesPerDay: _placesPerDay,
        tripTitle:    _titleController.text.trim().isEmpty
            ? 'My Trip'
            : _titleController.text.trim(),
      );

      if (!mounted) return;

      if (itinerary == null) {
        _showSnack('Failed to generate itinerary. Please try again.');
        return;
      }

      // Save to Firestore
      final savedId = await ItineraryService.instance.save(itinerary);
      if (!mounted) return;

      final saved = ItineraryModel(
        id:        savedId ?? '',
        title:     itinerary.title,
        startDate: itinerary.startDate,
        totalDays: itinerary.totalDays,
        days:      itinerary.days,
        createdAt: itinerary.createdAt,
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ItineraryDetailPage(itinerary: saved),
        ),
      );
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pickDate() async {
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
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.black87, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Plan Your Trip',
            style: TextStyle(color: Colors.black87, fontSize: 18,
                fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
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
                  const Text('✨ AI Trip Planner',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  const Text('Create your\nperfect itinerary',
                      style: TextStyle(color: Colors.white, fontSize: 26,
                          fontWeight: FontWeight.bold, height: 1.2)),
                  const SizedBox(height: 12),
                  Text(
                    '${widget.nearbyPlaces.length} places available nearby',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── Trip Title ──
            _buildSectionLabel('Trip Name'),
            const SizedBox(height: 10),
            _buildTextField(_titleController, 'e.g. Weekend Getaway'),

            const SizedBox(height: 24),

            // ── Start Date ──
            _buildSectionLabel('Start Date'),
            const SizedBox(height: 10),
            _buildDatePicker(),

            const SizedBox(height: 24),

            // ── Total Days ──
            _buildSectionLabel('Number of Days'),
            const SizedBox(height: 10),
            _buildNumberSelector(
              value:    _totalDays,
              min:      1,
              max:      7,
              onChanged: (v) => setState(() => _totalDays = v),
              suffix:   _totalDays == 1 ? 'day' : 'days',
            ),

            const SizedBox(height: 24),

            // ── Places per Day ──
            _buildSectionLabel('Places per Day'),
            const SizedBox(height: 10),
            _buildNumberSelector(
              value:    _placesPerDay,
              min:      2,
              max:      6,
              onChanged: (v) => setState(() => _placesPerDay = v),
              suffix:   'places',
            ),

            const SizedBox(height: 24),

            // ── Preferences Summary ──
            _buildSectionLabel('Based on Your Preferences'),
            const SizedBox(height: 10),
            _buildPreferencesSummary(prefs),

            const SizedBox(height: 32),

            // ── Trip Summary ──
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF7C4DFF).withOpacity(0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      color: Color(0xFF7C4DFF), size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$_totalDays ${_totalDays == 1 ? "day" : "days"} · '
                      '${_totalDays * _placesPerDay} places total · '
                      'Starting ${DateFormat('MMM dd').format(_startDate)}',
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF5E35B1),
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── Generate Button ──
            SizedBox(
              width: double.infinity,
              height: 58,
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
                          const SizedBox(width: 20, height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white)),
                          const SizedBox(width: 12),
                          const Text('Generating your trip...',
                              style: TextStyle(fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                        ],
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.auto_awesome_rounded, size: 20),
                          SizedBox(width: 8),
                          Text('Generate Itinerary',
                              style: TextStyle(fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
              ),
            ),

            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Widgets
  // ─────────────────────────────────────────────

  Widget _buildSectionLabel(String label) => Text(label,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
          color: Color(0xFF1A1A2E)));

  Widget _buildTextField(TextEditingController ctrl, String hint) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: TextField(
        controller: ctrl,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }

  Widget _buildDatePicker() {
    return GestureDetector(
      onTap: _pickDate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
              blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today_rounded,
                color: Color(0xFF7C4DFF), size: 20),
            const SizedBox(width: 12),
            Text(DateFormat('EEEE, MMM dd yyyy').format(_startDate),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
                    color: Colors.black87)),
            const Spacer(),
            Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
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
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          _circleBtn(Icons.remove_rounded, value > min
              ? () => onChanged(value - 1) : null),
          Expanded(
            child: Center(
              child: Text('$value $suffix',
                  style: const TextStyle(fontSize: 16,
                      fontWeight: FontWeight.bold, color: Color(0xFF1A1A2E))),
            ),
          ),
          _circleBtn(Icons.add_rounded, value < max
              ? () => onChanged(value + 1) : null),
        ],
      ),
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
        child: Icon(icon, size: 18,
            color: enabled ? const Color(0xFF7C4DFF) : Colors.grey[400]),
      ),
    );
  }

  Widget _buildPreferencesSummary(prefs) {
    final categories = (prefs.categories as List<String>);
    final cuisines   = (prefs.cuisines   as List<String>);

    const catLabels = {
      'restaurant':         '🍜 Food',
      'park':               '🌿 Nature',
      'tourist_attraction': '🏛️ Historical',
      'shopping_mall':      '🛍️ Shopping',
      'amusement_park':     '🎭 Entertainment',
    };

    final allTags = [
      ...categories.map((c) => catLabels[c] ?? c),
      ...cuisines.map((c) => '${c[0].toUpperCase()}${c.substring(1)} cuisine'),
    ];

    if (allTags.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Text('No preferences set. Go to Settings → Edit Preferences.',
            style: TextStyle(color: Colors.grey[500], fontSize: 13)),
      );
    }

    return Wrap(
      spacing: 8, runSpacing: 8,
      children: allTags.map((tag) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF7C4DFF).withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.2)),
        ),
        child: Text(tag, style: const TextStyle(
            fontSize: 12, color: Color(0xFF5E35B1),
            fontWeight: FontWeight.w500)),
      )).toList(),
    );
  }
}