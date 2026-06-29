import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/itineraryModel.dart';
import '../itinerary/itineraryDetail.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Achievement Model
// ─────────────────────────────────────────────────────────────────────────────

class _Achievement {
  final String emoji;
  final String title;
  final String desc;
  final bool unlocked;

  const _Achievement({
    required this.emoji,
    required this.title,
    required this.desc,
    required this.unlocked,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Data Models
// ─────────────────────────────────────────────────────────────────────────────

class _DashboardData {
  final int placesVisited;
  final int citiesExplored;
  final int favPlaces;
  final int tripsTaken;
  final Map<String, double> favCategoryDistribution;
  final Map<String, int> visitedCategoryDistribution;
  final List<_IncompleteTrip> incompleteTrips;      // ALL TIME
  final List<_UnvisitedFav> unvisitedFavourites;    // ALL TIME
  final Map<String, int> monthlyActivityFull;
  final double totalDistanceKm;                      // FILTERED
  final List<_Achievement> achievements;             // FILTERED

  const _DashboardData({
    required this.placesVisited,
    required this.citiesExplored,
    required this.favPlaces,
    required this.tripsTaken,
    required this.favCategoryDistribution,
    required this.visitedCategoryDistribution,
    required this.incompleteTrips,
    required this.unvisitedFavourites,
    required this.monthlyActivityFull,
    required this.totalDistanceKm,
    required this.achievements,
  });
}

class _IncompleteTrip {
  final String id;
  final String title;
  final int visited;
  final int total;
  final String startDate;
  final ItineraryModel itinerary;

  const _IncompleteTrip({
    required this.id,
    required this.title,
    required this.visited,
    required this.total,
    required this.startDate,
    required this.itinerary,
  });

  double get progress => total == 0 ? 0 : visited / total;
}

class _UnvisitedFav {
  final String placeId;
  final String name;
  final String address;
  final String? photoUrl;
  final double? rating;

  const _UnvisitedFav({
    required this.placeId,
    required this.name,
    required this.address,
    this.photoUrl,
    this.rating,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// City Extractor
// ─────────────────────────────────────────────────────────────────────────────

String _extractCity(String address) {
  if (address.isEmpty) return '';
  final postcodeRegex = RegExp(r'\d{4,6}\s+([A-Za-z][^,]+)');
  final postcodeMatch = postcodeRegex.firstMatch(address);
  if (postcodeMatch != null) return postcodeMatch.group(1)!.trim();
  final parts = address.split(',').map((s) => s.trim()).toList();
  if (parts.length >= 2) {
    final candidate = parts[parts.length - 2];
    if (!RegExp(r'^\d+$').hasMatch(candidate) && candidate.isNotEmpty) {
      return candidate;
    }
  }
  if (parts.isNotEmpty) return parts.last;
  return '';
}

// ─────────────────────────────────────────────────────────────────────────────
// Category mapper
// ─────────────────────────────────────────────────────────────────────────────

const _kCategoryLabels = {
  'Food':       ['restaurant', 'cafe', 'coffee_shop', 'bakery', 'bar', 'fast_food_restaurant', 'food_court', 'dessert_shop'],
  'Nature':     ['park', 'national_park', 'botanical_garden', 'garden', 'hiking_area', 'beach'],
  'Attraction': ['tourist_attraction', 'historical_landmark', 'monument', 'museum', 'art_gallery'],
  'Shopping':   ['shopping_mall', 'supermarket', 'grocery_store', 'department_store', 'clothing_store'],
  'Transport':  ['subway_station', 'bus_station', 'bus_stop', 'transit_station', 'train_station'],
};

const _kCategoryColors = {
  'Food':       Color(0xFFFF6B35),
  'Nature':     Color(0xFF2ECC71),
  'Attraction': Color(0xFF3498DB),
  'Shopping':   Color(0xFF9B59B6),
  'Transport':  Color(0xFF1ABC9C),
  'Others':     Color(0xFFBDC3C7),
};

String _mapTypeToCategory(List<String> types) {
  for (final entry in _kCategoryLabels.entries) {
    for (final t in types) {
      if (entry.value.contains(t)) return entry.key;
    }
  }
  return 'Others';
}

// ─────────────────────────────────────────────────────────────────────────────
// Haversine distance helper (km)
// ─────────────────────────────────────────────────────────────────────────────

double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLng = (lng2 - lng1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
      sin(dLng / 2) * sin(dLng / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

// ─────────────────────────────────────────────────────────────────────────────
// Raw data — loaded once from Firestore
// ─────────────────────────────────────────────────────────────────────────────

class _RawData {
  final List<({DateTime visitedAt, String address, String? placeId, String placeName})> historyEntries;
  final List<({DateTime savedAt, String placeId, String name, String address, List<String> types, String? photoUrl, double? rating})> favouriteEntries;
  final List<ItineraryModel> itineraryModels;

  const _RawData({
    required this.historyEntries,
    required this.favouriteEntries,
    required this.itineraryModels,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard Page
// ─────────────────────────────────────────────────────────────────────────────

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  _RawData? _rawData;
  bool _isLoading = true;
  String? _errorMsg;

  int _selectedMonths = 6;
  bool _showLineChart = true;

  @override
  void initState() {
    super.initState();
    _loadRawData();
  }

  // ─────────────────────────────────────────────
  // Load raw data ONCE from Firestore
  // ─────────────────────────────────────────────

  Future<void> _loadRawData() async {
    setState(() { _isLoading = true; _errorMsg = null; });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) { setState(() => _isLoading = false); return; }

      final db      = FirebaseFirestore.instance;
      final results = await Future.wait([
        db.collection('users').doc(uid).collection('history').get(),
        db.collection('users').doc(uid).collection('favourites').get(),
        db.collection('users').doc(uid).collection('itineraries').get(),
      ]);

      final historySnap     = results[0] as QuerySnapshot;
      final favouritesSnap  = results[1] as QuerySnapshot;
      final itinerariesSnap = results[2] as QuerySnapshot;

      // ── History ──
      final historyEntries = <({DateTime visitedAt, String address, String? placeId, String placeName})>[];
      for (final doc in historySnap.docs) {
        final data      = doc.data() as Map<String, dynamic>;
        final timestamp = data['visitedAt'] as Timestamp?;
        if (timestamp == null) continue;
        historyEntries.add((
          visitedAt: timestamp.toDate(),
          address:   data['address']   as String? ?? '',
          placeId:   data['placeId']   as String?,
          placeName: data['placeName'] as String? ?? '',
        ));
      }

      // ── Favourites ──
      final favouriteEntries = <({DateTime savedAt, String placeId, String name, String address, List<String> types, String? photoUrl, double? rating})>[];
      for (final doc in favouritesSnap.docs) {
        final data    = doc.data() as Map<String, dynamic>;
        final savedAt = (data['savedAt'] as Timestamp?)?.toDate() ?? DateTime(2000);
        favouriteEntries.add((
          savedAt:  savedAt,
          placeId:  data['placeId']  as String? ?? doc.id,
          name:     data['name']     as String? ?? '',
          address:  data['address']  as String? ?? '',
          types:    (data['types']   as List?)?.map((e) => e.toString()).toList() ?? [],
          photoUrl: data['photoUrl'] as String?,
          rating:   (data['rating']  as num?)?.toDouble(),
        ));
      }

      // ── Itineraries ──
      final itineraryModels = itinerariesSnap.docs
          .map((doc) => ItineraryModel.fromMap(
                doc.id, doc.data() as Map<String, dynamic>))
          .toList();

      setState(() {
        _rawData = _RawData(
          historyEntries:   historyEntries,
          favouriteEntries: favouriteEntries,
          itineraryModels:  itineraryModels,
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _isLoading = false; _errorMsg = e.toString(); });
    }
  }

  // ─────────────────────────────────────────────
  // Compute in-memory — no extra Firestore calls
  // ─────────────────────────────────────────────

  _DashboardData _computeData(_RawData raw, int months) {
    final now    = DateTime.now();
    final cutoff = DateTime(now.year, now.month - months + 1, 1);

    // ── Filtered by time range ──
    final filteredHistory     = raw.historyEntries.where((e) => e.visitedAt.isAfter(cutoff)).toList();
    final filteredFavourites  = raw.favouriteEntries.where((e) => e.savedAt.isAfter(cutoff)).toList();
    final filteredItineraries = raw.itineraryModels.where((m) => m.createdAt.isAfter(cutoff)).toList();

    // ── Top Card ──
    final placesVisited = filteredHistory.length;
    final citySet = <String>{};
    for (final e in filteredHistory) {
      final city = _extractCity(e.address);
      if (city.isNotEmpty) citySet.add(city);
    }
    for (final e in filteredFavourites) {
      final city = _extractCity(e.address);
      if (city.isNotEmpty) citySet.add(city);
    }
    final citiesExplored = citySet.length;
    final favPlaces      = filteredFavourites.length;
    final tripsTaken     = filteredItineraries.length;

    // ── Favourite Category Donut (filtered) ──
    final favCatCount = <String, double>{};
    for (final e in filteredFavourites) {
      final cat = _mapTypeToCategory(e.types);
      favCatCount[cat] = (favCatCount[cat] ?? 0) + 1;
    }

    // ── Visited Category Bar (filtered) ──
    final visitedCatCount = <String, int>{};
    final visitedPlaceIds = filteredHistory
        .where((e) => e.placeId != null)
        .map((e) => e.placeId!)
        .toSet();
    for (final e in raw.favouriteEntries) {
      if (visitedPlaceIds.contains(e.placeId)) {
        final cat = _mapTypeToCategory(e.types);
        visitedCatCount[cat] = (visitedCatCount[cat] ?? 0) + 1;
      }
    }
    for (final model in filteredItineraries) {
      for (final day in model.days) {
        for (final place in day.places) {
          if (place.visitedAt == null || place.visitedAt!.isBefore(cutoff)) continue;
          final cat = _mapTypeToCategory([place.primaryType ?? '']);
          visitedCatCount[cat] = (visitedCatCount[cat] ?? 0) + 1;
        }
      }
    }

    // ── Incomplete Trips (ALL TIME) ──
    final incompleteTrips = <_IncompleteTrip>[];
    for (final model in raw.itineraryModels) {
      if (model.totalPlaces > 0 && model.totalVisited < model.totalPlaces) {
        incompleteTrips.add(_IncompleteTrip(
          id:        model.id,
          title:     model.title,
          visited:   model.totalVisited,
          total:     model.totalPlaces,
          startDate: model.startDate,
          itinerary: model,
        ));
      }
    }
    incompleteTrips.sort((a, b) => a.progress.compareTo(b.progress));

    // ── Unvisited Favourites (ALL TIME) ──
    final historyPlaceNames = raw.historyEntries
        .map((e) => e.placeName.toLowerCase())
        .toSet();
    final unvisitedFavs = <_UnvisitedFav>[];
    for (final e in raw.favouriteEntries) {
      if (!historyPlaceNames.contains(e.name.toLowerCase())) {
        unvisitedFavs.add(_UnvisitedFav(
          placeId:  e.placeId,
          name:     e.name,
          address:  e.address,
          photoUrl: e.photoUrl,
          rating:   e.rating,
        ));
      }
    }

    // ── Monthly Activity (full 12 months, sliced by filter in UI) ──
    final monthNames   = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final monthMapFull = <String, int>{};
    for (int i = 11; i >= 0; i--) {
      final m   = DateTime(now.year, now.month - i, 1);
      final key = '${monthNames[m.month - 1]} ${m.year}';
      monthMapFull[key] = 0;
    }
    for (final e in raw.historyEntries) {
      final diff = (now.year - e.visitedAt.year) * 12 + (now.month - e.visitedAt.month);
      if (diff >= 0 && diff < 12) {
        final key = '${monthNames[e.visitedAt.month - 1]} ${e.visitedAt.year}';
        monthMapFull[key] = (monthMapFull[key] ?? 0) + 1;
      }
    }

    // ── Total Travel Distance (FILTERED) ──
    // Uses filteredItineraries — only itineraries created within the selected period
    double totalDistanceKm = 0;
    for (final model in filteredItineraries) {
      for (final day in model.days) {
        final visitedPlaces = day.places
            .where((p) =>
                p.isVisited &&
                p.lat != null &&
                p.lng != null &&
                (p.visitedAt == null || p.visitedAt!.isAfter(cutoff)))
            .toList();
        for (int i = 0; i < visitedPlaces.length - 1; i++) {
          totalDistanceKm += _haversineKm(
            visitedPlaces[i].lat!,
            visitedPlaces[i].lng!,
            visitedPlaces[i + 1].lat!,
            visitedPlaces[i + 1].lng!,
          );
        }
      }
    }

    // ── Achievements (FILTERED) ──
    // All based on filteredHistory + filteredItineraries within selected period
    int foodVisits   = 0;
    int natureVisits = 0;
    int completedTrips = 0;

    for (final model in filteredItineraries) {
      // Count completed itineraries
      if (model.totalPlaces > 0 && model.totalVisited == model.totalPlaces) {
        completedTrips++;
      }
      // Count food & nature visits
      for (final day in model.days) {
        for (final place in day.places) {
          if (!place.isVisited) continue;
          if (place.visitedAt != null && place.visitedAt!.isBefore(cutoff)) continue;
          final cat = _mapTypeToCategory([place.primaryType ?? '']);
          if (cat == 'Food')   foodVisits++;
          if (cat == 'Nature') natureVisits++;
        }
      }
    }

    final filteredCities = citySet; // already computed above from filteredHistory

    final achievements = <_Achievement>[
      _Achievement(
        emoji:    '🗺️',
        title:    'First Step',
        desc:     'Complete your first itinerary',
        unlocked: completedTrips >= 1,
      ),
      _Achievement(
        emoji:    '📍',
        title:    'Explorer',
        desc:     'Visit 10 places',
        unlocked: placesVisited >= 10,
      ),
      _Achievement(
        emoji:    '🔥',
        title:    'Adventurer',
        desc:     'Visit 25 places',
        unlocked: placesVisited >= 25,
      ),
      _Achievement(
        emoji:    '🍜',
        title:    'Foodie',
        desc:     'Visit 5 food spots',
        unlocked: foodVisits >= 5,
      ),
      _Achievement(
        emoji:    '🌿',
        title:    'Nature Lover',
        desc:     'Visit 5 nature spots',
        unlocked: natureVisits >= 5,
      ),
      _Achievement(
        emoji:    '🏙️',
        title:    'City Hopper',
        desc:     'Explore 3 different cities',
        unlocked: filteredCities.length >= 3,
      ),
      _Achievement(
        emoji:    '✈️',
        title:    'Traveller',
        desc:     'Complete 3 itineraries',
        unlocked: completedTrips >= 3,
      ),
      _Achievement(
        emoji:    '🚀',
        title:    'Road Warrior',
        desc:     'Travel over 100 km',
        unlocked: totalDistanceKm >= 100,
      ),
    ];

    return _DashboardData(
      placesVisited:               placesVisited,
      citiesExplored:              citiesExplored,
      favPlaces:                   favPlaces,
      tripsTaken:                  tripsTaken,
      favCategoryDistribution:     favCatCount,
      visitedCategoryDistribution: visitedCatCount,
      incompleteTrips:             incompleteTrips,
      unvisitedFavourites:         unvisitedFavs,
      monthlyActivityFull:         monthMapFull,
      totalDistanceKm:             totalDistanceKm,
      achievements:                achievements,
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Travel Dashboard',
            style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.black54),
            onPressed: _loadRawData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF6366F1)))
          : _errorMsg != null || _rawData == null
              ? _buildError()
              : _buildBody(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text('Failed to load dashboard', style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _loadRawData, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final data = _computeData(_rawData!, _selectedMonths);

    return RefreshIndicator(
      color: const Color(0xFF6366F1),
      onRefresh: _loadRawData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Filter Bar ──
            _buildFilterBar(),
            const SizedBox(height: 20),

            // ── 1. Top Card (filtered) ──
            _buildTopCard(data),
            const SizedBox(height: 16),

            // ── 2. Travel Distance (filtered) ──
            _buildDistanceCard(data),
            const SizedBox(height: 24),

            // ── 3. Favourite Categories (filtered) ──
            _sectionHeader('Favourite Categories', 'What you saved • filtered'),
            _buildFavDonutChart(data),
            const SizedBox(height: 24),

            // ── 4. Places Explored (filtered) ──
            _sectionHeader('Places You\'ve Explored', 'By category • filtered'),
            _buildVisitedBarChart(data),
            const SizedBox(height: 24),

            // ── 5. Achievements (filtered) ──
            _sectionHeader('Achievements', 'Your travel milestones • filtered'),
            _buildAchievements(data),
            const SizedBox(height: 24),

            // ── 6. Incomplete Trips (ALL TIME) ──
            _sectionHeaderWithBadge('Continue Your Trips', 'Itineraries in progress', allTime: true),
            _buildIncompleteTrips(data),
            const SizedBox(height: 24),

            // ── 7. Unvisited Favourites (ALL TIME) ──
            _sectionHeaderWithBadge('Still on Your Wishlist', 'Saved but not yet visited', allTime: true),
            _buildUnvisitedFavourites(data),
            const SizedBox(height: 24),

            // ── 8. Monthly Activity (filtered) ──
            _buildMonthlyHeader(),
            _buildMonthlyChart(data),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Filter Bar
  // ─────────────────────────────────────────────

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 10, offset: const Offset(0, 4),
        )],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.tune_rounded, size: 16, color: Color(0xFF6366F1)),
            const SizedBox(width: 6),
            const Text('Time Range',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
            const Spacer(),
            Text('Showing past $_selectedMonths months',
                style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          ]),
          const SizedBox(height: 12),
          Row(
            children: [3, 6, 12].map((months) {
              final selected = _selectedMonths == months;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _selectedMonths = months),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF6366F1) : Colors.grey[100],
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected ? const Color(0xFF6366F1) : Colors.grey[300]!,
                      ),
                    ),
                    child: Text(
                      months == 3 ? '3 Months' : months == 6 ? '6 Months' : '12 Months',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : Colors.grey[600],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // 1. Top Card
  // ─────────────────────────────────────────────

  Widget _buildTopCard(_DashboardData data) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(
          color: Colors.indigo.withOpacity(0.3),
          blurRadius: 12, offset: const Offset(0, 6),
        )],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _topStatItem('Places\nVisited', '${data.placesVisited}', isMain: true),
          Container(width: 1, height: 40, color: Colors.white24),
          _topStatItem('Cities\nExplored', '${data.citiesExplored}'),
          _topStatItem('Favourites', '${data.favPlaces}'),
          _topStatItem('Trips\nTaken', '${data.tripsTaken}'),
        ],
      ),
    );
  }

  Widget _topStatItem(String label, String value, {bool isMain = false}) {
    return Column(
      crossAxisAlignment: isMain ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(
          color: Colors.white,
          fontSize: isMain ? 22 : 16,
          fontWeight: FontWeight.bold,
        )),
      ],
    );
  }

  // ─────────────────────────────────────────────
  // 2. Travel Distance Card (FILTERED)
  // ─────────────────────────────────────────────

  Widget _buildDistanceCard(_DashboardData data) {
    final km      = data.totalDistanceKm;
    final display = km >= 1000
        ? '${(km / 1000).toStringAsFixed(1)}K km'
        : '${km.toStringAsFixed(1)} km';

    String comparison;
    if (km >= 40075)     comparison = '🌍 You\'ve circled the Earth!';
    else if (km >= 1000) comparison = '🚗 A full road trip distance!';
    else if (km >= 500)  comparison = '🏃 Way more than a marathon!';
    else if (km >= 100)  comparison = '🛵 A solid weekend ride!';
    else if (km >= 10)   comparison = '🚶 Keep exploring!';
    else                 comparison = '👣 Every journey starts here';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 10, offset: const Offset(0, 4),
        )],
      ),
      child: Row(children: [
        Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
            color: const Color(0xFF6366F1).withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Center(child: Text('🗺️', style: TextStyle(fontSize: 28))),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total Travel Distance • past $_selectedMonths months',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Text(display,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.bold,
                      color: Color(0xFF6366F1))),
              const SizedBox(height: 4),
              Text(comparison,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            ],
          ),
        ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // 3. Favourite Category Donut
  // ─────────────────────────────────────────────

  Widget _buildFavDonutChart(_DashboardData data) {
    final dist = data.favCategoryDistribution;
    if (dist.isEmpty) {
      return _emptyState(
        icon: Icons.favorite_border_rounded,
        message: 'No favourites saved in the past $_selectedMonths months',
      );
    }
    final total = dist.values.fold(0.0, (a, b) => a + b);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardStyle(),
      child: Row(children: [
        SizedBox(
          height: 130, width: 130,
          child: Stack(children: [
            PieChart(PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 40,
              sections: dist.entries.map((e) {
                final color = _kCategoryColors[e.key] ?? const Color(0xFFBDC3C7);
                return PieChartSectionData(
                    color: color, value: e.value, radius: 16, showTitle: false);
              }).toList(),
            )),
            Center(
              child: Text('${dist.length}\nTypes',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold,
                      fontSize: 12, color: Colors.black87)),
            ),
          ]),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            children: dist.entries.map((e) {
              final color   = _kCategoryColors[e.key] ?? const Color(0xFFBDC3C7);
              final percent = total > 0
                  ? '${(e.value / total * 100).toStringAsFixed(0)}%' : '0%';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Container(width: 8, height: 8,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(e.key,
                      style: const TextStyle(fontSize: 12, color: Colors.black87))),
                  Text(percent,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              );
            }).toList(),
          ),
        ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // 4. Visited Category Bar
  // ─────────────────────────────────────────────

  Widget _buildVisitedBarChart(_DashboardData data) {
    final dist = data.visitedCategoryDistribution;
    if (dist.isEmpty) {
      return _emptyState(
        icon: Icons.explore_outlined,
        message: 'No places explored in the past $_selectedMonths months',
      );
    }
    final maxVal  = dist.values.fold(0, (a, b) => a > b ? a : b).toDouble();
    final entries = dist.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardStyle(),
      child: Column(
        children: entries.map((e) {
          final color = _kCategoryColors[e.key] ?? const Color(0xFFBDC3C7);
          final ratio = maxVal > 0 ? e.value / maxVal : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              SizedBox(width: 72,
                  child: Text(e.key,
                      style: const TextStyle(fontSize: 12, color: Colors.black87))),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: ratio, minHeight: 12,
                    backgroundColor: Colors.grey[100],
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(width: 24,
                  child: Text('${e.value}',
                      style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.bold, color: color))),
            ]),
          );
        }).toList(),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // 5. Achievements (FILTERED)
  // ─────────────────────────────────────────────

  Widget _buildAchievements(_DashboardData data) {
    final achievements = data.achievements;
    final unlocked     = achievements.where((a) => a.unlocked).length;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardStyle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Progress summary
          Row(children: [
            Text('$unlocked / ${achievements.length} unlocked',
                style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.w600, color: Colors.black87)),
            const Spacer(),
            Text('${achievements.isEmpty ? 0 : (unlocked / achievements.length * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.bold, color: Color(0xFF6366F1))),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: achievements.isEmpty ? 0 : unlocked / achievements.length,
              minHeight: 6,
              backgroundColor: Colors.grey[100],
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
            ),
          ),
          const SizedBox(height: 20),

          // Achievement grid
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.75,
            ),
            itemCount: achievements.length,
            itemBuilder: (_, i) {
              final a = achievements[i];
              return Tooltip(
                message: a.desc,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: a.unlocked
                            ? const Color(0xFF6366F1).withOpacity(0.12)
                            : Colors.grey[100],
                        border: Border.all(
                          color: a.unlocked
                              ? const Color(0xFF6366F1)
                              : Colors.grey[300]!,
                          width: a.unlocked ? 2 : 1,
                        ),
                      ),
                      child: Center(
                        child: a.unlocked
                            ? Text(a.emoji, style: const TextStyle(fontSize: 24))
                            : const Icon(Icons.lock_rounded,
                                size: 20, color: Colors.grey),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      a.title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: a.unlocked
                            ? const Color(0xFF6366F1)
                            : Colors.grey[400],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // 6. Incomplete Trips (ALL TIME) — tappable
  // ─────────────────────────────────────────────

  Widget _buildIncompleteTrips(_DashboardData data) {
    if (data.incompleteTrips.isEmpty) {
      return _emptyState(
        icon: Icons.check_circle_outline_rounded,
        message: 'All trips completed! Plan a new one 🎉',
        isPositive: true,
      );
    }
    return Column(
      children: data.incompleteTrips.take(3).map((trip) {
        return GestureDetector(
          onTap: () async {
            final saved = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                builder: (_) => ItineraryDetailPage(itinerary: trip.itinerary),
              ),
            );
            if (saved == true && mounted) _loadRawData();
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: _cardStyle(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(trip.title,
                        style: const TextStyle(fontSize: 14,
                            fontWeight: FontWeight.bold, color: Colors.black87)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${trip.visited}/${trip.total} places',
                        style: const TextStyle(fontSize: 11,
                            color: Color(0xFF6366F1), fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded,
                      size: 18, color: Color(0xFF6366F1)),
                ]),
                const SizedBox(height: 4),
                Text(trip.startDate,
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: trip.progress, minHeight: 8,
                    backgroundColor: Colors.grey[100],
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
                  ),
                ),
                const SizedBox(height: 6),
                Text('${(trip.progress * 100).toStringAsFixed(0)}% completed — tap to continue',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─────────────────────────────────────────────
  // 7. Unvisited Favourites (ALL TIME)
  // ─────────────────────────────────────────────

  Widget _buildUnvisitedFavourites(_DashboardData data) {
    if (data.unvisitedFavourites.isEmpty) {
      return _emptyState(
        icon: Icons.favorite_rounded,
        message: 'You\'ve visited all your saved places!',
        isPositive: true,
      );
    }
    return SizedBox(
      height: 160,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: data.unvisitedFavourites.length > 10
            ? 10 : data.unvisitedFavourites.length,
        itemBuilder: (context, index) {
          final fav = data.unvisitedFavourites[index];
          return Container(
            width: 140,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 8, offset: const Offset(0, 3),
              )],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(fit: StackFit.expand, children: [
                fav.photoUrl != null
                    ? Image.network(fav.photoUrl!, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _favPlaceholder(fav.name))
                    : _favPlaceholder(fav.name),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 10, left: 10, right: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(fav.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white,
                              fontSize: 12, fontWeight: FontWeight.bold)),
                      if (fav.rating != null) ...[
                        const SizedBox(height: 3),
                        Row(children: [
                          const Icon(Icons.star_rounded, color: Colors.amber, size: 11),
                          const SizedBox(width: 2),
                          Text(fav.rating!.toStringAsFixed(1),
                              style: const TextStyle(color: Colors.white70, fontSize: 10)),
                        ]),
                      ],
                    ],
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _favPlaceholder(String name) {
    return Container(
      color: const Color(0xFF6366F1).withOpacity(0.15),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: const TextStyle(fontSize: 32,
              fontWeight: FontWeight.bold, color: Color(0xFF6366F1)),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // 8. Monthly Activity
  // ─────────────────────────────────────────────

  Widget _buildMonthlyHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        const Text('Monthly Activity',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Text('Past $_selectedMonths months',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const Spacer(),
        Container(
          decoration: BoxDecoration(
              color: Colors.grey[100], borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _chartTypeBtn(
              icon: Icons.show_chart_rounded,
              active: _showLineChart,
              onTap: () => setState(() => _showLineChart = true),
            ),
            _chartTypeBtn(
              icon: Icons.bar_chart_rounded,
              active: !_showLineChart,
              onTap: () => setState(() => _showLineChart = false),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _chartTypeBtn({required IconData icon, required bool active, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF6366F1) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(icon, size: 18, color: active ? Colors.white : Colors.grey[500]),
      ),
    );
  }

  Widget _buildMonthlyChart(_DashboardData data) {
    final allEntries = data.monthlyActivityFull.entries.toList();
    final sliced     = allEntries.length > _selectedMonths
        ? allEntries.sublist(allEntries.length - _selectedMonths)
        : allEntries;
    final entries    = sliced.map((e) => MapEntry(e.key.split(' ')[0], e.value)).toList();

    if (entries.isEmpty || entries.every((e) => e.value == 0)) {
      return _emptyState(
        icon: Icons.bar_chart_rounded,
        message: 'No activity in the past $_selectedMonths months',
      );
    }

    final maxVal = entries.map((e) => e.value).reduce((a, b) => a > b ? a : b).toDouble();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _showLineChart ? _lineChart(entries, maxVal) : _barChart(entries, maxVal),
    );
  }

  Widget _lineChart(List<MapEntry<String, int>> entries, double maxVal) {
    final spots = List.generate(entries.length,
        (i) => FlSpot(i.toDouble(), entries[i].value.toDouble()));
    return Container(
      key: const ValueKey('line'),
      height: 200,
      padding: const EdgeInsets.fromLTRB(10, 20, 20, 10),
      decoration: _cardStyle(),
      child: LineChart(LineChartData(
        gridData: FlGridData(
          show: true, drawVerticalLine: false,
          horizontalInterval: maxVal > 0 ? (maxVal / 4).ceilToDouble() : 1,
          getDrawingHorizontalLine: (v) => FlLine(color: Colors.grey[100]!, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles:  AxisTitles(sideTitles: SideTitles(
            showTitles: true, reservedSize: 28,
            getTitlesWidget: (v, _) => Text('${v.toInt()}',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          )),
          bottomTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= entries.length) return const Text('');
              return Text(entries[i].key,
                  style: const TextStyle(fontSize: 10, color: Colors.grey));
            },
          )),
        ),
        borderData: FlBorderData(show: false),
        minY: 0, maxY: maxVal == 0 ? 5 : maxVal * 1.2,
        lineBarsData: [
          LineChartBarData(
            spots: spots, isCurved: true,
            color: const Color(0xFF6366F1), barWidth: 3,
            dotData: FlDotData(show: true,
              getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                radius: 4, color: Colors.white,
                strokeWidth: 2, strokeColor: const Color(0xFF6366F1),
              ),
            ),
            belowBarData: BarAreaData(
                show: true, color: const Color(0xFF6366F1).withOpacity(0.08)),
          ),
        ],
      )),
    );
  }

  Widget _barChart(List<MapEntry<String, int>> entries, double maxVal) {
    return Container(
      key: const ValueKey('bar'),
      height: 200,
      padding: const EdgeInsets.fromLTRB(10, 20, 20, 10),
      decoration: _cardStyle(),
      child: BarChart(BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxVal == 0 ? 5 : maxVal * 1.3,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, rod, __) => BarTooltipItem(
              '${entries[group.x.toInt()].key}\n',
              const TextStyle(color: Colors.white, fontSize: 10),
              children: [TextSpan(
                text: '${rod.toY.toInt()} visits',
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 12),
              )],
            ),
          ),
        ),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles:  AxisTitles(sideTitles: SideTitles(
            showTitles: true, reservedSize: 28,
            getTitlesWidget: (v, _) => Text('${v.toInt()}',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          )),
          bottomTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= entries.length) return const Text('');
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(entries[i].key,
                    style: const TextStyle(fontSize: 9, color: Colors.grey)),
              );
            },
          )),
        ),
        gridData: FlGridData(
          show: true, drawVerticalLine: false,
          getDrawingHorizontalLine: (v) =>
              FlLine(color: Colors.grey[100]!, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        barGroups: List.generate(entries.length, (i) => BarChartGroupData(
          x: i,
          barRods: [BarChartRodData(
            toY: entries[i].value.toDouble(),
            color: const Color(0xFF6366F1),
            width: _selectedMonths == 12 ? 10 : 16,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
            backDrawRodData: BackgroundBarChartRodData(
              show: true,
              toY: maxVal == 0 ? 5 : maxVal * 1.3,
              color: Colors.grey[50],
            ),
          )],
        )),
      )),
    );
  }

  // ─────────────────────────────────────────────
  // Shared helpers
  // ─────────────────────────────────────────────

  Widget _sectionHeader(String title, String sub) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Text(sub, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    );
  }

  Widget _sectionHeaderWithBadge(String title, String sub, {bool allTime = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Text(sub, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        if (allTime) ...[
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: const Text('All Time',
                style: TextStyle(fontSize: 10,
                    color: Colors.grey, fontWeight: FontWeight.w600)),
          ),
        ],
      ]),
    );
  }

  Widget _emptyState({required IconData icon, required String message, bool isPositive = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: _cardStyle(),
      child: Column(children: [
        Icon(icon, size: 40,
            color: isPositive ? const Color(0xFF2ECC71) : Colors.grey[300]),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13,
                color: isPositive ? const Color(0xFF2ECC71) : Colors.grey[500])),
      ]),
    );
  }

  BoxDecoration _cardStyle() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [BoxShadow(
        color: Colors.black.withOpacity(0.04),
        blurRadius: 10, offset: const Offset(0, 4),
      )],
    );
  }
}