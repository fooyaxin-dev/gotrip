import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/placeModal.dart';
import '../../models/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../itinerary/itineraryDetail.dart';
import '../../services/route_service.dart';

class RouteOptimizerPage extends StatefulWidget {
  final List<PlaceModel> places;
  final double startLat;
  final double startLng;
  final String? startLocationName;
  final TravelMode travelMode;

  const RouteOptimizerPage({
    super.key,
    required this.places,
    required this.startLat,
    required this.startLng,
    this.startLocationName,
    this.travelMode = TravelMode.walk,
  });

  @override
  State<RouteOptimizerPage> createState() => _RouteOptimizerPageState();
}

class _RouteOptimizerPageState extends State<RouteOptimizerPage> {

  late List<PlaceModel> _orderedPlaces;
  bool _isAutoSorted   = true;
  bool _isSaving       = false;

  List<double> _legDistances   = [];
  List<int>    _legMinutes     = [];
  double       _totalKm        = 0;
  int          _totalTravelMin = 0;

  // Map
  GoogleMapController? _mapController;
  Set<Marker>   _markers   = {};
  Set<Polyline> _polylines = {};

  // Sheet
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final ValueNotifier<double> _sheetExtentNotifier = ValueNotifier(0.45);

  // Undo delete
  PlaceModel? _lastDeletedPlace;
  int?        _lastDeletedIndex;

  // ─────────────────────────────────────────────
  // Getters
  // ─────────────────────────────────────────────

  double get _speedMps {
    switch (widget.travelMode) {
      case TravelMode.walk:  return 1.4;
      case TravelMode.motor: return 6.0;
      case TravelMode.drive: return 12.0;
    }
  }

  IconData get _travelIcon {
    switch (widget.travelMode) {
      case TravelMode.walk:  return Icons.directions_walk_rounded;
      case TravelMode.motor: return Icons.motorcycle_rounded;
      case TravelMode.drive: return Icons.directions_car_rounded;
    }
  }

  String get _travelLabel {
    switch (widget.travelMode) {
      case TravelMode.walk:  return 'walk';
      case TravelMode.motor: return 'ride';
      case TravelMode.drive: return 'drive';
    }
  }

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _orderedPlaces = List.from(widget.places);
    _recalcLegs();
    _updateMapOverlays();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    _sheetController.dispose();
    _sheetExtentNotifier.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Leg calculation
  // ─────────────────────────────────────────────

  void _recalcLegs() {
    final legs    = <double>[];
    final legMins = <int>[];
    double totalM  = 0;
    double prevLat = widget.startLat;
    double prevLng = widget.startLng;

    for (final place in _orderedPlaces) {
      final lat = place.lat ?? prevLat;
      final lng = place.lng ?? prevLng;
      final d   = Geolocator.distanceBetween(prevLat, prevLng, lat, lng);
      legs.add(d);
      legMins.add((d / _speedMps / 60).round());
      totalM  += d;
      prevLat  = lat;
      prevLng  = lng;
    }

    setState(() {
      _legDistances   = legs;
      _legMinutes     = legMins;
      _totalKm        = totalM / 1000;
      _totalTravelMin = legMins.fold(0, (a, b) => a + b);
    });
  }

  // ─────────────────────────────────────────────
  // Map overlays
  // ─────────────────────────────────────────────

  Future<void> _updateMapOverlays() async {
    final newMarkers   = <Marker>{};
    final newPolylines = <Polyline>{};

    newMarkers.add(Marker(
      markerId: const MarkerId('__start__'),
      position: LatLng(widget.startLat, widget.startLng),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      infoWindow: InfoWindow(
          title: widget.startLocationName ?? 'Your Location'),
    ));

    for (int i = 0; i < _orderedPlaces.length; i++) {
      final place = _orderedPlaces[i];
      if (place.lat == null || place.lng == null) continue;
      final icon = await _buildNumberedPin(
          i + 1, _stopColor(i, _orderedPlaces.length));
      newMarkers.add(Marker(
        markerId: MarkerId('stop_$i'),
        position: LatLng(place.lat!, place.lng!),
        icon: icon,
        infoWindow: InfoWindow(title: place.name),
      ));
    }

    final polylinePoints = <LatLng>[
      LatLng(widget.startLat, widget.startLng),
      for (final p in _orderedPlaces)
        if (p.lat != null && p.lng != null) LatLng(p.lat!, p.lng!),
    ];

    if (polylinePoints.length >= 2) {
      newPolylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: polylinePoints,
        color: const Color(0xFF4A90D9),
        width: 3,
        patterns: [PatternItem.dash(16), PatternItem.gap(8)],
      ));
    }

    if (mounted) {
      setState(() {
        _markers   = newMarkers;
        _polylines = newPolylines;
      });
      _fitCamera(polylinePoints);
    }
  }

  void _fitCamera(List<LatLng> points) {
    if (_mapController == null || points.isEmpty) return;
    if (points.length == 1) {
      _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(points.first, 15));
      return;
    }
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in points) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      ), 60,
    ));
  }

  Future<BitmapDescriptor> _buildNumberedPin(int number, Color color) async {
    const size = 48.0;
    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder);
    canvas.drawCircle(
      const Offset(size / 2 + 1, size / 2 + 2),
      size / 2 - 4,
      Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 4,
        Paint()..color = color);
    canvas.drawCircle(
      const Offset(size / 2, size / 2), size / 2 - 4,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '$number',
        style: const TextStyle(
            color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));
    final img  = await recorder.endRecording()
        .toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
  }

  // ─────────────────────────────────────────────
  // Reorder / Remove / Re-optimize
  // ─────────────────────────────────────────────

  void _reorder(int oldIndex, int newIndex) {
    if (oldIndex == 0 || newIndex == 0) return;
    final realOld = oldIndex - 1;
    var   realNew = newIndex - 1;
    if (realNew > realOld) realNew--;
    final item = _orderedPlaces.removeAt(realOld);
    _orderedPlaces.insert(realNew, item);
    _isAutoSorted = false;
    _recalcLegs();
    _updateMapOverlays();
  }

  // FIX 3: undo support
  void _removePlace(int index) {
    final removed = _orderedPlaces[index];
    setState(() {
      _lastDeletedPlace = removed;
      _lastDeletedIndex = index;
      _orderedPlaces.removeAt(index);
    });
    _recalcLegs();
    _updateMapOverlays();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${removed.name} removed',
          style: const TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: const Color(0xFF1A1A2E),
        action: SnackBarAction(
          label: 'Undo',
          textColor: const Color(0xFF9B8FFF),
          onPressed: _undoDelete,
        ),
      ),
    );
  }

  void _undoDelete() {
    if (_lastDeletedPlace == null || _lastDeletedIndex == null) return;
    setState(() {
      _orderedPlaces.insert(
        _lastDeletedIndex!.clamp(0, _orderedPlaces.length),
        _lastDeletedPlace!,
      );
      _lastDeletedPlace = null;
      _lastDeletedIndex = null;
    });
    _recalcLegs();
    _updateMapOverlays();
  }

  void _reOptimize() {
    final remaining = List<PlaceModel>.from(_orderedPlaces);
    final result    = <PlaceModel>[];
    double curLat   = widget.startLat;
    double curLng   = widget.startLng;

    while (remaining.isNotEmpty) {
      PlaceModel? nearest;
      double minDist = double.infinity;
      for (final p in remaining) {
        if (p.lat == null || p.lng == null) continue;
        final d = Geolocator.distanceBetween(curLat, curLng, p.lat!, p.lng!);
        if (d < minDist) { minDist = d; nearest = p; }
      }
      if (nearest == null) break;
      result.add(nearest);
      remaining.remove(nearest);
      curLat = nearest.lat!;
      curLng = nearest.lng!;
    }

    setState(() {
      _orderedPlaces = result;
      _isAutoSorted  = true;
    });
    _recalcLegs();
    _updateMapOverlays();
  }

  // ─────────────────────────────────────────────
  // Save
  // ─────────────────────────────────────────────

  Future<void> _saveAndContinue() async {
    if (_orderedPlaces.isEmpty) return;
    setState(() => _isSaving = true);

    final now     = DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd').format(now);
    var curHour   = 9;
    var curMin    = 0;

    final itineraryPlaces = <ItineraryPlace>[];

    for (int i = 0; i < _orderedPlaces.length; i++) {
      final p = _orderedPlaces[i];
      if (i < _legMinutes.length) {
        curMin  += _legMinutes[i];
        curHour += curMin ~/ 60;
        curMin   = curMin % 60;
      }
      if (curHour >= 21) { curHour = 21; curMin = 0; }

      final timeStr  = '${curHour.toString().padLeft(2, '0')}:${curMin.toString().padLeft(2, '0')}';
      final duration = p.primaryType == 'restaurant' ? 60 : 90;

      itineraryPlaces.add(ItineraryPlace(
        placeId:         p.id,
        name:            p.name,
        address:         p.address ?? '',
        photoUrl:        p.photoUrl,
        lat:             p.lat,
        lng:             p.lng,
        primaryType:     p.primaryType,
        suggestedTime:   timeStr,
        durationMinutes: duration,
        notes:           'Added by you',
      ));

      curMin  += duration;
      curHour += curMin ~/ 60;
      curMin   = curMin % 60;
      if (curHour >= 21) { curHour = 21; curMin = 0; }
    }

    final itinerary = ItineraryModel(
      id:        '',
      title:     'My Custom Trip',
      startDate: dateStr,
      totalDays: 1,
      days: [ItineraryDay(dayNumber: 1, date: dateStr, places: itineraryPlaces)],
      createdAt: now,
    );

    final savedId = await ItineraryService.instance.save(itinerary);
    if (!mounted) return;
    setState(() => _isSaving = false);

    if (savedId == null) {
      final isLoggedIn = FirebaseAuth.instance.currentUser != null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isLoggedIn
            ? 'Failed to save itinerary'
            : 'Please log in to save itinerary'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    final saved = ItineraryModel.fromMap(savedId, itinerary.toMap());
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ItineraryDetailPage(itinerary: saved)),
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      body: Stack(
        children: [

          // ── Map behind everything ──
          Column(children: [
            _buildHeader(),
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: _sheetExtentNotifier,
                builder: (context, extent, _) {
                  return GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _orderedPlaces.isNotEmpty &&
                              _orderedPlaces.first.lat != null
                          ? LatLng(_orderedPlaces.first.lat!,
                              _orderedPlaces.first.lng!)
                          : LatLng(widget.startLat, widget.startLng),
                      zoom: 13,
                    ),
                    markers:   _markers,
                    polylines: _polylines,
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    padding: EdgeInsets.only(bottom: screenHeight * extent),
                    onMapCreated: (c) {
                      _mapController = c;
                      final points = <LatLng>[
                        LatLng(widget.startLat, widget.startLng),
                        for (final p in _orderedPlaces)
                          if (p.lat != null && p.lng != null)
                            LatLng(p.lat!, p.lng!),
                      ];
                      Future.delayed(const Duration(milliseconds: 400),
                          () => _fitCamera(points));
                    },
                  );
                },
              ),
            ),
          ]),

          // ── Draggable sheet ──
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (n) {
              _sheetExtentNotifier.value = n.extent;
              return false;
            },
            child: DraggableScrollableSheet(
              controller:       _sheetController,
              initialChildSize: 0.45,
              minChildSize:     0.14, // just enough to show handle + summary
              maxChildSize:     0.85,
              snap:             true,
              snapSizes:        const [0.14, 0.45, 0.85],
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24)),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    )],
                  ),
                  child: _buildSheetContent(scrollController),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Header
  // ─────────────────────────────────────────────

  Widget _buildHeader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white, size: 18),
                  onPressed: () => Navigator.pop(context),
                ),
                const Expanded(
                  child: Text('Plan Your Route',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                ),
                GestureDetector(
                  onTap: _reOptimize,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.4)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_fix_high_rounded,
                          color: Colors.white, size: 14),
                      SizedBox(width: 5),
                      Text('Re-optimize',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(children: [
                  const Icon(Icons.info_outline_rounded,
                      color: Colors.white60, size: 13),
                  const SizedBox(width: 5),
                  const Text('Drag stops to reorder • Tap × to remove',
                      style: TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _isAutoSorted
                          ? Colors.green.withOpacity(0.25)
                          : Colors.orange.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                        _isAutoSorted
                            ? Icons.auto_awesome_rounded
                            : Icons.edit_rounded,
                        size: 10,
                        color: _isAutoSorted
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _isAutoSorted ? 'Auto-sorted' : 'Edited',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: _isAutoSorted
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                        ),
                      ),
                    ]),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Sheet content
  // ─────────────────────────────────────────────

  Widget _buildSheetContent(ScrollController scrollController) {
    return Column(
      children: [

        // ── FIX: large drag handle area with tap-to-cycle ──
        GestureDetector(
          onTap: () {
            final current = _sheetExtentNotifier.value;
            final next = current < 0.30
                ? 0.45
                : current < 0.65
                    ? 0.85
                    : 0.14;
            _sheetController.animateTo(
              next,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
          behavior: HitTestBehavior.translucent,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              // Handle bar
              Container(
                width: 44, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 6),
              // FIX: hint text so user knows they can drag/tap
              ValueListenableBuilder<double>(
                valueListenable: _sheetExtentNotifier,
                builder: (_, extent, __) {
                  final label = extent < 0.20
                      ? '↑ Tap to expand'
                      : extent > 0.70
                          ? '↓ Tap to collapse'
                          : 'Drag or tap to resize';
                  return Text(label,
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[400],
                          letterSpacing: 0.3));
                },
              ),
            ]),
          ),
        ),

        // Summary
        _buildSummaryBar(),
        const Divider(height: 1, thickness: 0.5),

        // Stop list
        Expanded(child: _buildStopList(scrollController)),

        // Bottom bar
        _buildBottomBar(),
      ],
    );
  }

  // ─────────────────────────────────────────────
  // Summary bar
  // ─────────────────────────────────────────────

  Widget _buildSummaryBar() {
    final visitMin = _orderedPlaces.fold<int>(
        0, (s, p) => s + (p.primaryType == 'restaurant' ? 60 : 90));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(children: [
        _summaryChip(Icons.place_rounded,
            '${_orderedPlaces.length} stops', const Color(0xFF7C4DFF)),
        const SizedBox(width: 10),
        _summaryChip(Icons.straighten_rounded,
            '${_totalKm.toStringAsFixed(1)} km', Colors.blue),
        const SizedBox(width: 10),
        _summaryChip(_travelIcon,
            '$_totalTravelMin min $_travelLabel', Colors.teal),
        const SizedBox(width: 10),
        _summaryChip(Icons.schedule_rounded,
            '~${(visitMin / 60).toStringAsFixed(1)}h', Colors.orange),
      ]),
    );
  }

  Widget _summaryChip(IconData icon, String label, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    ]);
  }

  // ─────────────────────────────────────────────
  // Stop list
  // ─────────────────────────────────────────────

  Widget _buildStopList(ScrollController scrollController) {
    if (_orderedPlaces.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.playlist_remove_rounded,
              size: 56, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text('No stops left',
              style: TextStyle(fontSize: 15, color: Colors.grey[400])),
          const SizedBox(height: 6),
          Text('Go back to add more places',
              style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ]),
      );
    }

    return CustomScrollView(
      controller: scrollController,
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          sliver: SliverReorderableList(
            itemCount: _orderedPlaces.length + 1,
            onReorder: _reorder,
            itemBuilder: (context, index) {
              if (index == 0) {
                return _buildStartNode(key: const ValueKey('__start__'));
              }
              final i = index - 1;
              return _buildStopItem(i,
                  key: ValueKey(_orderedPlaces[i].id));
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  // ── Start node — visually distinct, no drag handle ──

  Widget _buildStartNode({required Key key}) {
    // FIX 1: wrap in IgnorePointer for reorder + no drag handle shown
    return ReorderableDelayedDragStartListener(
      index: 0,
      enabled: false, // start node cannot be dragged
      key: key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.blue[200]!),
            ),
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: const BoxDecoration(
                    color: Color(0xFF378ADD), shape: BoxShape.circle),
                child: const Icon(Icons.my_location_rounded,
                    color: Colors.white, size: 16),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.startLocationName ?? 'Your Location',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF185FA5)),
                    ),
                    const Text('Starting point · fixed',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFF378ADD))),
                  ],
                ),
              ),
              // Lock icon to signal it cannot be moved
              Icon(Icons.lock_outline_rounded,
                  size: 16, color: Colors.blue[300]),
            ]),
          ),
          if (_orderedPlaces.isNotEmpty) _buildLegConnector(0),
        ],
      ),
    );
  }

  // ── Stop item ─────────────────────────────────

  Widget _buildStopItem(int index, {required Key key}) {
    final place    = _orderedPlaces[index];
    final isLast   = index == _orderedPlaces.length - 1;
    final numColor = _stopColor(index, _orderedPlaces.length);

    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[100]!),
            boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 8,
                offset: const Offset(0, 3))],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [

              // ── Drag handle — large touch area, clear affordance ──
              ReorderableDragStartListener(
                index: index + 1,
                child: Container(
                  width: 48,
                  height: 76,
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.drag_indicator_rounded,
                          color: Colors.grey[400], size: 22),
                    ],
                  ),
                ),
              ),

              // Number badge
              Container(
                width: 30, height: 30,
                decoration: BoxDecoration(
                    color: numColor, shape: BoxShape.circle),
                child: Center(
                  child: Text('${index + 1}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 10),

              // Photo
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: place.photoUrl != null
                    ? Image.network(place.photoUrl!,
                        width: 52, height: 52, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _photoPlaceholder())
                    : _photoPlaceholder(),
              ),
              const SizedBox(width: 10),

              // Info
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(place.name,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A2E)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Row(children: [
                        if (place.rating != null) ...[
                          const Icon(Icons.star_rounded,
                              color: Colors.orange, size: 13),
                          const SizedBox(width: 2),
                          Text(place.rating.toString(),
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(place.address ?? '',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[500]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: numColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          place.primaryType == 'restaurant'
                              ? '~60 min visit'
                              : '~90 min visit',
                          style: TextStyle(
                              fontSize: 10,
                              color: numColor,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Remove
              GestureDetector(
                onTap: () => _removePlace(index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                        color: Colors.red[50], shape: BoxShape.circle),
                    child: Icon(Icons.close_rounded,
                        size: 16, color: Colors.red[400]),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!isLast) _buildLegConnector(index + 1),
      ],
    );
  }

  // ── Leg connector ─────────────────────────────

  Widget _buildLegConnector(int toIndex) {
    if (toIndex >= _legDistances.length) return const SizedBox.shrink();
    final km  = (_legDistances[toIndex] / 1000).toStringAsFixed(1);
    final min = _legMinutes[toIndex];

    return Padding(
      padding: const EdgeInsets.only(left: 30),
      child: Row(children: [
        Column(children: List.generate(4, (_) => Container(
          width: 2, height: 5,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: Colors.blue[200],
            borderRadius: BorderRadius.circular(1),
          ),
        ))),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.blue[50],
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.blue[100]!),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_travelIcon, size: 11, color: Colors.blue[600]),
            const SizedBox(width: 4),
            Text('$km km · $min min',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue[700],
                    fontWeight: FontWeight.w500)),
          ]),
        ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // Bottom bar
  // ─────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, 10 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(0, -3))],
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF7C4DFF).withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: const Color(0xFF7C4DFF).withOpacity(0.2)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${_orderedPlaces.length}',
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF7C4DFF))),
            const Text('stops',
                style: TextStyle(fontSize: 10, color: Color(0xFF7C4DFF))),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: (_orderedPlaces.isEmpty || _isSaving)
                  ? null
                  : _saveAndContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C4DFF),
                disabledBackgroundColor: Colors.grey[300],
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
                        Icon(Icons.check_circle_rounded,
                            color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Text('Confirm Route',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold)),
                        SizedBox(width: 6),
                        Icon(Icons.arrow_forward_rounded,
                            color: Colors.white70, size: 16),
                      ],
                    ),
            ),
          ),
        ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────

  Color _stopColor(int index, int total) {
    if (total <= 1) return const Color(0xFF534AB7);
    final t = index / (total - 1);
    return Color.lerp(
        const Color(0xFF534AB7), const Color(0xFFAFA9EC), t)!;
  }

  Widget _photoPlaceholder() => Container(
    width: 52, height: 52,
    color: Colors.grey[100],
    child: Icon(Icons.location_on_rounded,
        color: Colors.grey[300], size: 24),
  );
}