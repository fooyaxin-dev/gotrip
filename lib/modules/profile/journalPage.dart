import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../services/history_service.dart'; // TripHistory / HistoryEntry live here
import '../../services/journalMeta_service.dart';
import '../../services/error_handler.dart';

// ═══════════════════════════════════════════════════════════════════════════
// A SINGLE HAND-DRAWN JOURNAL PAGE (one calendar day of one itinerary)
// ═══════════════════════════════════════════════════════════════════════════
//
// Photos: the user's own picks (via JournalMetaService) take priority.
// If they've never customised this day, we fall back to whatever photos
// got attached automatically at check-in (HistoryEntry.photoUrl / trip
// coverPhoto) — see _loadPhotos() / _effectivePhotos().

class JournalPage extends StatefulWidget {
  final String itineraryId;
  final String title;
  final DateTime date;
  final List<HistoryEntry> places;
  final String? autoCoverPhoto;
  final List<Color> accent;
  final String? dayBadge; // e.g. "Day 2/3" — null if the trip is a single day

  // Pre-resolved from journalBook.dart's single batch Firestore read.
  // null = user never customised this field -> fall back to auto content.
  // Passing these in (instead of each page fetching on its own) is what
  // avoids the "shows auto, then pops to custom a few seconds later" flash.
  final List<String>? initialPhotos;
  final String? initialNotes;
  // false in the "View All" overall book — editing only happens from a
  // trip's own journal, so nothing here writes to Firestore in that view.
  final bool editable;

  const JournalPage({
    super.key,
    required this.itineraryId,
    required this.title,
    required this.date,
    required this.places,
    required this.accent,
    this.autoCoverPhoto,
    this.dayBadge,
    this.initialPhotos,
    this.initialNotes,
    this.editable = true,
  });

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  // Seeded directly from the props — journalBook.dart already did the
  // (single, batched) Firestore read before building this widget.
  late List<String>? _customPhotos;
  late String? _customNotes;

  @override
  void initState() {
    super.initState();
    _customPhotos = widget.initialPhotos;
    _customNotes = widget.initialNotes;
  }

  List<String> _autoPhotoUrls() {
    final urls = <String>[];
    if (widget.autoCoverPhoto != null && widget.autoCoverPhoto!.isNotEmpty) urls.add(widget.autoCoverPhoto!);
    for (final p in widget.places) {
      if (p.photoUrl != null && p.photoUrl!.isNotEmpty && !urls.contains(p.photoUrl)) urls.add(p.photoUrl!);
    }
    return urls.take(5).toList();
  }

  /// What actually gets shown: the user's saved selection if they've ever
  /// saved one (even an empty one — that's a deliberate "no photos"), else
  /// the auto check-in photos as a fallback.
  List<String> _effectivePhotos() => _customPhotos ?? _autoPhotoUrls();

  Future<void> _openPhotoEditor() async {
    final result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PhotoEditSheet(
          itineraryId: widget.itineraryId,
          date: widget.date,
          initialPhotos: _effectivePhotos(),
        ),
      ),
    );
    if (result != null && mounted) setState(() => _customPhotos = result);
  }

  Future<void> _openNotesEditor(List<HistoryEntry> sortedPlaces) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _NotesEditSheet(
          itineraryId: widget.itineraryId,
          date: widget.date,
          initialText: _customNotes ?? _autoCaption(sortedPlaces),
        ),
      ),
    );
    if (result != null && mounted) setState(() => _customNotes = result);
  }

  @override
  Widget build(BuildContext context) {
    final sortedPlaces = [...widget.places]..sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
    final dateFmt = DateFormat('d');
    final monthFmt = DateFormat('MMM').format(widget.date).toUpperCase();
    final weekdayFmt = DateFormat('EEE').format(widget.date).toUpperCase();
    final photos = _effectivePhotos();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF6EEDD), // kraft/cream paper
        border: Border(left: BorderSide(color: Colors.brown.shade300, width: 1)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 14, offset: const Offset(4, 0)),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            left: 34,
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: Colors.brown.withOpacity(0.12)),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDateHeader(dateFmt.format(widget.date), monthFmt, weekdayFmt),
                  const SizedBox(height: 6),
                  _buildTitleRow(sortedPlaces.length),
                  const SizedBox(height: 20),
                  _buildTimeline(sortedPlaces),
                  const SizedBox(height: 14),
                  _buildPhotoSectionHeader(),
                  const SizedBox(height: 8),
                  if (photos.isNotEmpty) _buildPhotoStrip(photos) else _buildEmptyPhotoState(),
                  const SizedBox(height: 18),
                  _buildRuledJournalText(sortedPlaces),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── clean vertical timeline: one row per stop, never overlaps ──
  Widget _buildTimeline(List<HistoryEntry> places) {
    if (places.isEmpty) {
      return Text('No stops logged for this trip yet.',
          style: GoogleFonts.kalam(fontSize: 13, color: Colors.brown.shade300));
    }
    return Column(
      children: [
        for (int i = 0; i < places.length; i++) _buildTimelineRow(places[i], i, i == places.length - 1),
      ],
    );
  }

  Widget _buildTimelineRow(HistoryEntry place, int index, bool isLast) {
    final dotColor = index == 0 ? widget.accent.first : Colors.white;
    final timeStr = DateFormat('h:mm a').format(place.visitedAt);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                timeStr,
                style: GoogleFonts.kalam(fontSize: 10, color: Colors.brown.shade400, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          Column(
            children: [
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.brown.shade700, width: 1.6),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: widget.accent.first.withOpacity(0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Text(
                place.placeName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.kalam(fontSize: 14, fontWeight: FontWeight.w700, color: const Color(0xFF2B2118)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateHeader(String day, String month, String weekday) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          day,
          style: GoogleFonts.caveat(
            fontSize: 64,
            height: 0.9,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF2B2118),
          ),
        ),
        const SizedBox(width: 10),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(month,
                  style: GoogleFonts.kalam(
                      fontSize: 14, fontWeight: FontWeight.w700, color: Colors.brown.shade700)),
              Text(weekday,
                  style: GoogleFonts.kalam(fontSize: 11, color: Colors.brown.shade400)),
            ],
          ),
        ),
        const Spacer(),
        _buildStamp(),
      ],
    );
  }

  Widget _buildStamp() {
    return Transform.rotate(
      angle: -0.14,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: widget.accent.first.withOpacity(0.6), width: 1.4),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'GOTRIP',
          style: GoogleFonts.kalam(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: widget.accent.first.withOpacity(0.75),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleRow(int stopCount) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.kalam(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF2B2118),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (widget.dayBadge != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: widget.accent.first.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(widget.dayBadge!,
                style: GoogleFonts.kalam(fontSize: 10, fontWeight: FontWeight.w700, color: widget.accent.first)),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          '$stopCount STOP${stopCount == 1 ? '' : 'S'}',
          style: GoogleFonts.kalam(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.brown.shade400),
        ),
      ],
    );
  }

  Widget _buildPhotoSectionHeader() {
    return Row(
      children: [
        Text('Photos',
            style: GoogleFonts.kalam(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.brown.shade600)),
        const SizedBox(width: 6),
        if (_customPhotos == null)
          Text('(auto)', style: GoogleFonts.kalam(fontSize: 11, color: Colors.brown.shade300)),
        const Spacer(),
        if (widget.editable)
          InkWell(
            onTap: _openPhotoEditor,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: widget.accent.first.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.edit, size: 14, color: widget.accent.first),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyPhotoState() {
    final content = Container(
      height: 90,
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.brown.withOpacity(0.25), style: BorderStyle.solid),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Text(
          widget.editable ? '+ add photos from this day' : 'No photos for this day',
          style: GoogleFonts.kalam(fontSize: 12, color: Colors.brown.shade400),
        ),
      ),
    );
    return widget.editable ? InkWell(onTap: _openPhotoEditor, child: content) : content;
  }

  Widget _buildPhotoStrip(List<String> urls) {
    return SizedBox(
      height: 168,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        itemBuilder: (_, i) {
          final angle = (i.isEven ? -1 : 1) * (0.05 + Random(i).nextDouble() * 0.05);
          return GestureDetector(
            onTap: () => Navigator.of(context).push(
              PageRouteBuilder(
                opaque: false,
                barrierColor: Colors.black.withOpacity(0.95),
                pageBuilder: (_, __, ___) => _PhotoViewerPage(urls: urls, initialIndex: i),
              ),
            ),
            child: Transform.rotate(
              angle: angle,
              child: Container(
                margin: const EdgeInsets.only(right: 14),
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 8, offset: const Offset(1, 4))],
                ),
                child: SizedBox(
                  width: 130,
                  height: 130,
                  child: CachedNetworkImage(
                    imageUrl: urls[i],
                    fit: BoxFit.cover,
                    // decode at ~display size (x2 for retina) instead of the full
                    // upload resolution — this is what was making page-flip janky,
                    // decoding a 1600px image just to show it at 130px costs real
                    // CPU/GPU time on every frame of the flip animation.
                    memCacheWidth: 260,
                    memCacheHeight: 260,
                    placeholder: (_, __) => Container(color: Colors.grey[200]),
                    errorWidget: (_, __, ___) => Container(color: Colors.grey[300]),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRuledJournalText(List<HistoryEntry> places) {
    final caption = _customNotes ?? _autoCaption(places);
    return Container(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Today.',
                  style: GoogleFonts.kalam(
                      fontSize: 14, fontWeight: FontWeight.w700, color: Colors.brown.shade700)),
              const SizedBox(width: 6),
              if (_customNotes == null)
                Text('(auto)', style: GoogleFonts.kalam(fontSize: 11, color: Colors.brown.shade300)),
              const Spacer(),
              if (widget.editable)
                InkWell(
                  onTap: () => _openNotesEditor(places),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: widget.accent.first.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.edit, size: 14, color: widget.accent.first),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            caption,
            style: GoogleFonts.kalam(fontSize: 14, height: 1.7, color: const Color(0xFF3A2E22)),
          ),
        ],
      ),
    );
  }

  String _autoCaption(List<HistoryEntry> places) {
    if (places.isEmpty) return 'A quiet day with no stops logged.';
    final names = places.map((p) => p.placeName).toList();
    if (names.length == 1) return 'Spent today exploring ${names.first}.';
    final last = names.removeLast();
    return 'Wandered through ${names.join(', ')} and ended up at $last. '
        '${places.length} places, one good day.';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// NOTES EDITOR — freeform textbox, prefilled with either the user's saved
// entry or the auto-generated caption so they're editing, not starting blank.
// ═══════════════════════════════════════════════════════════════════════════
class _NotesEditSheet extends StatefulWidget {
  final String itineraryId;
  final DateTime date;
  final String initialText;

  const _NotesEditSheet({
    required this.itineraryId,
    required this.date,
    required this.initialText,
  });

  @override
  State<_NotesEditSheet> createState() => _NotesEditSheetState();
}

class _NotesEditSheetState extends State<_NotesEditSheet> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await JournalMetaService.instance.saveNotes(widget.itineraryId, widget.date, _controller.text.trim());
      if (mounted) Navigator.of(context).pop(_controller.text.trim());
    } catch (e) {
      if (mounted) {
        ErrorHandler.showError(context, error: e, message: 'Failed to save note. Please try again.');
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit journal entry'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _controller,
          maxLines: null,
          minLines: 8,
          autofocus: true,
          style: GoogleFonts.kalam(fontSize: 15, height: 1.6),
          decoration: const InputDecoration(
            hintText: "What happened today?",
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PHOTO EDITOR — pick from the day's auto check-in photos, remove any,
// or upload new ones from the camera roll. Saves to JournalMetaService.
// ═══════════════════════════════════════════════════════════════════════════
class _PhotoEditSheet extends StatefulWidget {
  final String itineraryId;
  final DateTime date;
  final List<String> initialPhotos;

  const _PhotoEditSheet({
    required this.itineraryId,
    required this.date,
    required this.initialPhotos,
  });

  @override
  State<_PhotoEditSheet> createState() => _PhotoEditSheetState();
}

class _PhotoEditSheetState extends State<_PhotoEditSheet> {
  late List<String> _photos;
  final List<String> _pendingUploads = [];
  bool _uploading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _photos = [...widget.initialPhotos];
  }

  Future<void> _pickAndUpload() async {
    if (_uploading || _saving) return;

    try {
      final picker = ImagePicker();
      final picked = await picker.pickMultiImage(imageQuality: 80, maxWidth: 1600, maxHeight: 1600);
      if (picked.isEmpty) return;

      setState(() {
        _uploading = true;
        _pendingUploads.clear();
        _pendingUploads.addAll(picked.map((x) => x.path));
      });

      final results = List<String?>.filled(picked.length, null);
      int nextIdx = 0;
      int errorCount = 0;

      Future<void> worker() async {
        while (true) {
          int current;
          if (nextIdx >= picked.length) return;
          current = nextIdx++;

          try {
            final url = await JournalMetaService.instance.uploadPhoto(
              widget.itineraryId,
              widget.date,
              File(picked[current].path),
            );
            results[current] = url;
          } catch (e) {
            errorCount++;
            debugPrint('Upload failed for photo $current: $e');
          }
        }
      }

      final concurrency = min(2, picked.length);
      final workers = List.generate(concurrency, (_) => worker());
      await Future.wait(workers);

      if (!mounted) return;

      final successful = results.whereType<String>().toList();
      setState(() {
        _photos.addAll(successful);
        _pendingUploads.clear();
      });

      if (errorCount > 0) {
        ErrorHandler.showError(
          context,
          message: errorCount == picked.length
              ? 'Upload failed. Please check your connection and try again.'
              : '$errorCount photo(s) failed to upload. Please try again.',
        );
      } else if (successful.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photos uploaded. Tap Save to keep your changes.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ErrorHandler.showError(context, error: e, message: 'Upload failed. Please check your connection and try again.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _pendingUploads.clear();
        });
      }
    }
  }

  Future<void> _save() async {
    if (_saving || _uploading) return;
    setState(() => _saving = true);
    try {
      await JournalMetaService.instance.savePhotos(widget.itineraryId, widget.date, _photos);
      if (mounted) Navigator.of(context).pop(_photos);
    } catch (e) {
      if (mounted) {
        ErrorHandler.showError(context, error: e, message: 'Failed to save photos. Please try again.');
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _photos.length + _pendingUploads.length + 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit day photos'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: (_saving || _uploading) ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8,
          ),
          itemCount: totalCount,
          itemBuilder: (_, i) {
            // Existing uploaded remote photos
            if (i < _photos.length) {
              final url = _photos[i];
              return Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox.expand(
                      child: CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: InkWell(
                      onTap: (_uploading || _saving)
                          ? null
                          : () => setState(() => _photos.removeAt(i)),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              );
            }

            // In-flight pending local photos with progress spinner
            final pendingIndex = i - _photos.length;
            if (pendingIndex < _pendingUploads.length) {
              final path = _pendingUploads[pendingIndex];
              return Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox.expand(
                      child: Image.file(File(path), fit: BoxFit.cover),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }

            // Add photo button
            return InkWell(
              onTap: (_uploading || _saving) ? null : _pickAndUpload,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: _uploading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_photo_alternate_outlined, color: Colors.grey),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FULL-SCREEN PHOTO VIEWER — pinch to zoom, swipe between the page's photos.
// ═══════════════════════════════════════════════════════════════════════════
class _PhotoViewerPage extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;

  const _PhotoViewerPage({required this.urls, required this.initialIndex});

  @override
  State<_PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<_PhotoViewerPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: widget.urls.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: widget.urls[i],
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white38, size: 48),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoundCloseButton(onTap: () => Navigator.of(context).pop()),
                    if (widget.urls.length > 1)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_index + 1} / ${widget.urls.length}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundCloseButton extends StatelessWidget {
  final VoidCallback onTap;
  const _RoundCloseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), shape: BoxShape.circle),
        child: const Icon(Icons.close, color: Colors.white70, size: 18),
      ),
    );
  }
}