import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../../services/landmarkHistory_service.dart';
import '../../services/vision_service.dart';
import '../../services/error_handler.dart';
import 'landmarkResult.dart';
import '../../services/apps_Loading.dart';

class LandmarkHistoryPage extends StatefulWidget {
  const LandmarkHistoryPage({super.key});

  @override
  State<LandmarkHistoryPage> createState() => _LandmarkHistoryPageState();
}

class _LandmarkHistoryPageState extends State<LandmarkHistoryPage> {
  List<LandmarkHistoryEntry> _entries = [];
  bool _loading = true;
  final Set<String> _deletingIds = {};
  bool _isClearing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await LandmarkHistoryService.fetch(limit: 50);
    if (mounted) setState(() { _entries = data; _loading = false; });
  }

  Future<void> _delete( 
    LandmarkHistoryEntry entry,
  ) async {
    if (_deletingIds.contains(entry.id) || _isClearing) return;
    _deletingIds.add(entry.id);

    try {
      await LandmarkHistoryService.delete(entry.id);

      if (!mounted) return;

      setState(() {
        _entries.removeWhere(
          (e) => e.id == entry.id,
        );
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Removed from history'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ErrorHandler.showError(
        context,
        message:
            'Failed to remove item. Please try again.',
      );
    } finally {
      _deletingIds.remove(entry.id);
    }
  }

  // ── Reconstruct a LandmarkResult from a saved history entry ──
  // and jump back into ResultPage to view the full info again.
  void _openDetail(LandmarkHistoryEntry entry) {
    final DetectionMethod method;
    switch (entry.detectionMethod) {
      case 'vision':
        method = DetectionMethod.visionLandmark;
        break;
      case 'gemini':
        method = DetectionMethod.geminiVision;
        break;
      default:
        method = DetectionMethod.notDetected;
    }

    final result = LandmarkResult(
      landmark: entry.name,
      normalizedName: entry.name,
      rawJson: '',
      lat: entry.lat,
      lng: entry.lng,
      confidence: 1.0,
      method: method,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ResultPage(
          imageBytes: null,               // original scan photo isn't stored
          fallbackImageUrl: entry.photoUrl, // fall back to the Google Places photo
          landmarkResult: result,
          skipHistorySave: true,          // don't create a duplicate history entry
        ),
      ),
    );
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Clear History'),
        content: const Text('Remove all scanned landmark records?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      if (_isClearing) return;
      setState(() => _isClearing = true);
      try {
        await LandmarkHistoryService.clearAll();
        if (mounted) setState(() => _entries = []);
      } catch (e) {
        if (mounted) {
          ErrorHandler.showError(context, message: 'Failed to clear history. Please try again.');
        }
      } finally {
        if (mounted) setState(() => _isClearing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('Scan History',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: [
          if (_entries.isNotEmpty)
            TextButton(
              onPressed: _isClearing ? null : _clearAll,
              child: Text(
                _isClearing ? 'Clearing...' : 'Clear All',
                style: TextStyle(
                  color: _isClearing ? Colors.grey : Colors.redAccent,
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: TravelLoadingIndicator())
          : _entries.isEmpty
              ? _buildEmpty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _entries.length,
                    itemBuilder: (_, i) => _buildCard(_entries[i]),
                  ),
                ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_rounded, size: 72, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text('No scans yet',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold,
                  color: Colors.grey[500])),
          const SizedBox(height: 8),
          Text('Landmarks you scan will appear here',
              style: TextStyle(fontSize: 13, color: Colors.grey[400])),
        ],
      ),
    );
  }

  Widget _buildCard(LandmarkHistoryEntry entry) {
    return Dismissible(
      key: Key(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.redAccent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      onDismissed: (_) => _delete(entry),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openDetail(entry),
          child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // ── Thumbnail ──────────────────────────────────────
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                bottomLeft: Radius.circular(16),
              ),
              child: SizedBox(
                width: 90,
                height: 90,
                child: _buildThumbnail(entry),
              ),
            ),

            // ── Info ───────────────────────────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    if (entry.address != null)
                      Text(entry.address!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[500])),
                    const SizedBox(height: 6),
                    Text(
                      _formatDate(entry.scannedAt),
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey[400]),
                    ),
                  ],
                ),
              ),
            ),

            // ── Rating ─────────────────────────────────────────
            if (entry.rating != null)
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Column(
                  children: [
                    const Icon(Icons.star_rounded,
                        color: Colors.amber, size: 18),
                    Text(entry.rating!.toStringAsFixed(1),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
          ],
        ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(LandmarkHistoryEntry entry) {
    // Priority: Google Places photo > scanned image base64 > placeholder
    if (entry.photoUrl != null && entry.photoUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: entry.photoUrl!,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _placeholder(),
      );
    }
    if (entry.imageBase64 != null && entry.imageBase64!.isNotEmpty) {
      try {
        final bytes = base64Decode(entry.imageBase64!);
        return CachedNetworkImage(
          imageUrl: 'data:image/jpeg;base64,$bytes',
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _placeholder(),
        );
      } catch (_) {}
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFFEDE7F6),
      child: const Icon(Icons.location_on_rounded,
          color: Color(0xFF7C4DFF), size: 32),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    if (diff.inDays < 7)     return '${diff.inDays}d ago';
    return DateFormat('d MMM').format(dt);
  }
}