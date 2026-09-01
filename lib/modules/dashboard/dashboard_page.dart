import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/itineraryModel.dart';
import '../../services/achievement_service.dart';
import '../itinerary/itineraryDetail.dart';
import '../itinerary/itineraryPage.dart';
import '../profile/profile.dart';
import '../../services/apps_Loading.dart';
import '../../services/userActivity_service.dart';
import '../../services/category_mapper.dart';
import '../main/favourite.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data Models
// ─────────────────────────────────────────────────────────────────────────────

// ── 新增:all-time 缓存,只在 raw data 变化时重算 ──
class _AllTimeCache {
  final List<_VisitEvent> dedupedEvents;
  final Map<String, int> monthlyActivityFull;
  final List<AchievementGroup> achievements;

  const _AllTimeCache({
    required this.dedupedEvents,
    required this.monthlyActivityFull,
    required this.achievements,
  });
}


class _DashboardData {
  final int placesVisited;
  final int citiesExplored;
  final int favPlaces;
  final int tripsTaken;
  final Map<String, int> visitedCategoryDistribution; // FILTERED — by visitedAt
  final List<_IncompleteTrip> incompleteTrips;         // ALL TIME
  final Map<String, int> monthlyActivityFull;
  final double totalDistanceKm;                         // FILTERED — by visitedAt
  final List<AchievementGroup> achievements;           // ALL TIME — never affected by filter

  const _DashboardData({
    required this.placesVisited,
    required this.citiesExplored,
    required this.favPlaces,
    required this.tripsTaken,
    required this.visitedCategoryDistribution,
    required this.incompleteTrips,
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
//
// Each visited place is flattened into a single "visit event" with its own
// visitedAt timestamp + lat/lng + category. This lets every filtered metric
// (distance, achievements, category bar, top card) use the SAME ground truth
// — the actual moment the user visited that place — instead of mixing in
// itinerary-level createdAt, which can be misleading.
// ─────────────────────────────────────────────────────────────────────────────

class _VisitEvent {
  final DateTime visitedAt;
  final String address;
  final String? placeId;
  final String placeName;
  final String primaryType;
  final double? lat;
  final double? lng;
  final String itineraryId; // '' if from plain history (no itinerary)

  const _VisitEvent({
    required this.visitedAt,
    required this.address,
    required this.placeId,
    required this.placeName,
    required this.primaryType,
    required this.lat,
    required this.lng,
    required this.itineraryId,
  });
}

class _RawData {
  final List<_VisitEvent> visitEvents; // unified — from history + itineraries
  final List<({DateTime savedAt, String placeId, String name, String address, List<String> types, String? photoUrl, double? rating})> favouriteEntries;
  final List<ItineraryModel> itineraryModels;

  const _RawData({
    required this.visitEvents,
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

    static const List<int> _kFilterMonths = [3, 6, 12];

  _RawData? _rawData;
  _AllTimeCache? _allTimeCache;                 // 新增
  final Map<int, _DashboardData> _filteredCache = {}; // 新增
  bool _isLoading = true;
  bool _isRefreshing = false;
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

    
  Future<void> _loadRawData({
    bool forceRefresh = false,
  }) async {
    if (!mounted) return;

    setState(() {
      if (_rawData == null) {
        _isLoading = true;
      } else {
        _isRefreshing = true;
      }
      _errorMsg = null;
    });

    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _rawData = null;
        _allTimeCache = null;
        _filteredCache.clear();
      });

      return;
    }

    try {
      final activity =
          await UserActivityDataService.instance.getAll(
        forceRefresh: forceRefresh,
      );

      // Page may have been closed while loading.
      if (!mounted) return;

      // Account may have changed while the request was running.
      if (FirebaseAuth.instance.currentUser?.uid != uid) {
        if (mounted) {
          setState(() => _isLoading = false);
        }
        return;
      }

      final historySnap = activity.history;
      final favouritesSnap = activity.favourites;
      final itinerariesSnap = activity.itineraries;

  
      // ── Favourites（ActivityDoc 用法：doc.data 不是 doc.data()）──
      final favouriteEntries = <({DateTime savedAt, String placeId, String name, String address, List<String> types, String? photoUrl, double? rating})>[];
      for (final doc in favouritesSnap) {
        final data    = doc.data;
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
  
      final typeByPlaceId = <String, List<String>>{};
      for (final f in favouriteEntries) {
        typeByPlaceId[f.placeId] = f.types;
      }
  
      // ── Itineraries（同样用 doc.data / doc.id，ItineraryModel.fromMap 用法不变）──
      final itineraryModels = itinerariesSnap
          .map((doc) => ItineraryModel.fromMap(doc.id, doc.data))
          .toList();
  
      // ── 构建统一的 visit events ──
      final visitEvents = <_VisitEvent>[];
  
      // 1) 来自 plain history collection
      for (final doc in historySnap) {
        final data      = doc.data;
        final timestamp = data['visitedAt'] as Timestamp?;
        if (timestamp == null) continue;
        final placeId = data['placeId'] as String?;
        final types    = placeId != null ? (typeByPlaceId[placeId] ?? []) : <String>[];
  
        // ★ 改动：优先用 history 自己存的 primaryType（我们之前已经
        // 确认它有存），没有的话才退回用 favourites 的 types 猜分类
        final storedPrimaryType = data['primaryType'] as String?;
        final category = storedPrimaryType != null && storedPrimaryType.isNotEmpty
            ? CategoryMapper.toDisplayCategory(storedPrimaryType)
            : CategoryMapper.toDisplayCategory(
                types.isNotEmpty ? types.first : '');
  
        visitEvents.add(_VisitEvent(
          visitedAt:   timestamp.toDate(),
          address:     data['address']   as String? ?? '',
          placeId:     placeId,
          placeName:   data['placeName'] as String? ?? '',
          primaryType: category,
          // ★ 改动：history 现在存了坐标，不用再是 null
          lat:         (data['lat'] as num?)?.toDouble(),
          lng:         (data['lng'] as num?)?.toDouble(),
          itineraryId: data['itineraryId'] as String? ?? '',
        ));
      }
  
      // 2) 来自 itinerary 里已打卡的地点
      for (final model in itineraryModels) {
        for (final day in model.days) {
          for (final place in day.places) {
            if (!place.isVisited || place.visitedAt == null) continue;
            visitEvents.add(_VisitEvent(
              visitedAt:   place.visitedAt!,
              address:     place.address,
              placeId:     place.placeId,
              placeName:   place.name,
              primaryType: CategoryMapper.toDisplayCategory(place.primaryType ?? ''),
              lat:         place.lat,
              lng:         place.lng,
              itineraryId: model.id,
            ));
          }
        }
      }
  
          if (!mounted) return;

    // Final session check immediately before committing UI state.
    if (FirebaseAuth.instance.currentUser?.uid != uid) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
        });
      }
      return;
    }

    setState(() {
      _rawData = _RawData(
        visitEvents: visitEvents,
        favouriteEntries: favouriteEntries,
        itineraryModels: itineraryModels,
      );

      _allTimeCache = _buildAllTimeCache(_rawData!);

      _filteredCache.clear();
      _prewarmFilteredCache();

      _isLoading = false;
      _isRefreshing = false;
    });
  } catch (e) {
    if (!mounted) return;

    // Don't show an error from an operation belonging to an old account.
    if (FirebaseAuth.instance.currentUser?.uid != uid) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
        });
      }
      return;
    }

    setState(() {
      _isLoading = false;
      _isRefreshing = false;
      _errorMsg = e.toString();
    });
  }
}
  
  // ─────────────────────────────────────────────
  // Compute in-memory — no extra Firestore calls
  //
  // ALL filtered metrics now use the SAME source of truth:
  // raw.visitEvents filtered by visitedAt >= cutoff.
  // ─────────────────────────────────────────────

  _AllTimeCache _buildAllTimeCache(_RawData raw) {
    // ── 去重(原来在 _computeData 顶部) ──
    final seenKeys = <String>{};
    final dedupedEvents = <_VisitEvent>[];
    for (final e in raw.visitEvents) {
      final dayKey = '${e.visitedAt.year}-${e.visitedAt.month}-${e.visitedAt.day}';
      final key = e.placeId != null && e.placeId!.isNotEmpty
          ? '${e.placeId}_$dayKey'
          : '${e.placeName}_$dayKey';
      if (seenKeys.contains(key)) continue;
      seenKeys.add(key);
      dedupedEvents.add(e);
    }

    // ── Monthly Activity(全 12 个月,不受 filter 影响) ──
    final now = DateTime.now();
    final monthNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final monthMapFull = <String, int>{};
    for (int i = 11; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i, 1);
      monthMapFull['${monthNames[m.month - 1]} ${m.year}'] = 0;
    }
    for (final e in dedupedEvents) {
      final diff = (now.year - e.visitedAt.year) * 12 + (now.month - e.visitedAt.month);
      if (diff >= 0 && diff < 12) {
        final key = '${monthNames[e.visitedAt.month - 1]} ${e.visitedAt.year}';
        monthMapFull[key] = (monthMapFull[key] ?? 0) + 1;
      }
    }

    // ── Achievements(all time,原来每次 filter 切换都重算,现在只算一次) ──
    final allTimeCitySet = <String>{};
    for (final e in dedupedEvents) {
      final city = _extractCity(e.address);
      if (city.isNotEmpty) allTimeCitySet.add(city);
    }
    final allTimeFoodVisits       = dedupedEvents.where((e) => e.primaryType == 'Food').length;
    final allTimeNatureVisits     = dedupedEvents.where((e) => e.primaryType == 'Nature').length;
    final allTimeAttractionVisits = dedupedEvents.where((e) => e.primaryType == 'Attraction').length;

    int allTimeCompletedTrips = 0;
    for (final model in raw.itineraryModels) {
      if (model.totalPlaces > 0 && model.totalVisited == model.totalPlaces) {
        allTimeCompletedTrips++;
      }
    }

    final byItineraryAllTime = <String, List<_VisitEvent>>{};
    for (final e in dedupedEvents) {
      if (e.itineraryId.isEmpty || e.lat == null || e.lng == null) continue;
      byItineraryAllTime.putIfAbsent(e.itineraryId, () => []).add(e);
    }
    double allTimeDistanceKm = 0;
    for (final group in byItineraryAllTime.values) {
      group.sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
      for (int i = 0; i < group.length - 1; i++) {
        allTimeDistanceKm += _haversineKm(
          group[i].lat!, group[i].lng!,
          group[i + 1].lat!, group[i + 1].lng!,
        );
      }
    }

    final achievements = AchievementService.instance.buildGroups(AchievementStats(
      placesVisited:    dedupedEvents.length,
      citiesExplored:   allTimeCitySet.length,
      tripsCompleted:   allTimeCompletedTrips,
      foodVisits:       allTimeFoodVisits,
      natureVisits:     allTimeNatureVisits,
      attractionVisits: allTimeAttractionVisits,
      totalDistanceKm:  allTimeDistanceKm,
    ));

    return _AllTimeCache(
      dedupedEvents: dedupedEvents,
      monthlyActivityFull: monthMapFull,
      achievements: achievements,
    );
  }
  
  // ─────────────────────────────────────────────
  // 预热 filter 缓存 —— raw data / all-time cache 刚建好时,
  // 一次性把 3 / 6 / 12 个月三个档位都算好存起来。
  // 这样用户切 filter chip 的时候,包括第一次点某个档位,
  // 都是直接读缓存,不会有现算的那一下卡顿。
  //
  // 三次 _computeData 加起来的耗时跟切换时分次算是一样的,
  // 只是提前在 loading 状态里做掉,不会挡住用户交互。
  // ─────────────────────────────────────────────
  void _prewarmFilteredCache() {
    for (final months in _kFilterMonths) {
      _filteredCache[months] = _computeData(_rawData!, _allTimeCache!, months);
    }
  }
  
  
  // ─────────────────────────────────────────────
  // Filter 相关的计算 —— 复用 _AllTimeCache 里已经算好的
  // dedupedEvents / monthlyActivityFull / achievements,
  // 这里只处理跟 _selectedMonths 有关的部分。
  // ─────────────────────────────────────────────

  _DashboardData _computeData(_RawData raw, _AllTimeCache cache, int months) {
    final now    = DateTime.now();
    final cutoff = DateTime(now.year, now.month - months + 1, 1);

    final dedupedEvents = cache.dedupedEvents; // 直接复用,不再重新去重

    // ── Filtered visit events (by visitedAt) — single source of truth ──
    final filteredEvents = dedupedEvents
        .where((e) => e.visitedAt.isAfter(cutoff))
        .toList();

    // ── Filtered favourites (by savedAt) — only used for Top Card count ──
    final filteredFavourites = raw.favouriteEntries
        .where((e) => e.savedAt.isAfter(cutoff))
        .toList();

    // ── Top Card ──
    final placesVisited = filteredEvents.length;

    final citySet = <String>{};
    for (final e in filteredEvents) {
      final city = _extractCity(e.address);
      if (city.isNotEmpty) citySet.add(city);
    }
    final citiesExplored = citySet.length;
    final favPlaces      = filteredFavourites.length;

    // "Active" trips: itineraries with at least one visit inside the filter
    // window. Uses the same visitedAt-based truth as every other filtered
    // metric — NOT itinerary.createdAt — so it lines up with Places Visited.
    final activeItineraryIds = filteredEvents
        .where((e) => e.itineraryId.isNotEmpty)
        .map((e) => e.itineraryId)
        .toSet();
    final tripsTaken = activeItineraryIds.length;

    // ── Visited Category Bar (filtered, replaces the old Donut too) ──
    final visitedCatCount = <String, int>{};
    for (final e in filteredEvents) {
      visitedCatCount[e.primaryType] = (visitedCatCount[e.primaryType] ?? 0) + 1;
    }

    // ── Incomplete Trips (ALL TIME — status-based, not time-based) ──
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

    // ── Total Travel Distance (FILTERED — shown on the Distance Card) ──
    // Group filtered events by itineraryId, sort each group chronologically,
    // and sum the haversine distance between consecutive stops.
    final byItineraryFiltered = <String, List<_VisitEvent>>{};
    for (final e in filteredEvents) {
      if (e.itineraryId.isEmpty || e.lat == null || e.lng == null) continue;
      byItineraryFiltered.putIfAbsent(e.itineraryId, () => []).add(e);
    }

    double totalDistanceKm = 0;
    for (final group in byItineraryFiltered.values) {
      group.sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
      for (int i = 0; i < group.length - 1; i++) {
        totalDistanceKm += _haversineKm(
          group[i].lat!, group[i].lng!,
          group[i + 1].lat!, group[i + 1].lng!,
        );
      }
    }

    return _DashboardData(
      placesVisited:               placesVisited,
      citiesExplored:              citiesExplored,
      favPlaces:                   favPlaces,
      tripsTaken:                  tripsTaken,
      visitedCategoryDistribution: visitedCatCount,
      incompleteTrips:             incompleteTrips,
      monthlyActivityFull:         cache.monthlyActivityFull, // 复用缓存,不重算
      totalDistanceKm:             totalDistanceKm,
      achievements:                cache.achievements,        // 复用缓存,不重算
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
            icon: _isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF6366F1),
                    ),
                  )
                : const Icon(Icons.refresh_rounded, color: Colors.black54),
            onPressed: _isRefreshing ? null : () => _loadRawData(forceRefresh: true),
          ),
        ],
      ),
      body: (_isLoading && _rawData == null)
          ? const Center(child: TravelLoadingIndicator())
          : _errorMsg != null && _rawData == null
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
          ElevatedButton(onPressed: () => _loadRawData(forceRefresh: true), child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildBody() {
      final data = _filteredCache.putIfAbsent(
      _selectedMonths,
      () => _computeData(_rawData!, _allTimeCache!, _selectedMonths),
    );

    return RefreshIndicator(
      color: const Color(0xFF6366F1),
      onRefresh: () => _loadRawData(
        forceRefresh: true,
      ),
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

            // ── 3. Places Explored — single category section (filtered) ──
            _sectionHeader('Places You\'ve Explored', 'By category • filtered'),
            _buildVisitedBarChart(data),
            const SizedBox(height: 24),

            // ── 4. Achievements (filtered) ──
            _sectionHeader('Achievements', 'Your travel milestones • filtered'),
            _buildAchievements(data),
            const SizedBox(height: 24),

            // ── 5. Incomplete Trips (ALL TIME) ──
            _sectionHeaderWithBadge('Continue Journey', '', allTime: true),
            _buildIncompleteTrips(data),
            const SizedBox(height: 24),

            // ── 6. Monthly Activity (filtered) ──
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
            Flexible(
              child: Text('Showing past $_selectedMonths months',
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ),
          ]),
          const SizedBox(height: 12),
          Row(
            children: _kFilterMonths.map((months) {
              final selected = _selectedMonths == months;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedMonths = months),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? const Color(0xFF6366F1) : Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected ? const Color(0xFF6366F1) : Colors.grey[300]!,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          months == 3 ? '3 Months' : months == 6 ? '6 Months' : '12 Months',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: selected ? Colors.white : Colors.grey[600],
                          ),
                        ),
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
          // Places Visited → Profile History tab
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const ProfilePage(initialTab: 1),
              )),
              child: _topStatItem('Places\nVisited', '${data.placesVisited}', isMain: true),
            ),
          ),
          Container(width: 1, height: 40, color: Colors.white24),
          // Cities Explored → Profile History tab
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const ProfilePage(initialTab: 1),
              )),
              child: _topStatItem('Cities\nExplored', '${data.citiesExplored}'),
            ),
          ),
          // Favourites → Profile Post tab
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const FavouritePage(),
                ),
              ),
              child: _topStatItem(
                'Favourites',
                '${data.favPlaces}',
              ),
            ),
          ),
          // Trips Taken → Itinerary page
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const ItineraryPage(),
              )),
              child: _topStatItem('Trips\nTaken', '${data.tripsTaken}'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topStatItem(String label, String value, {bool isMain = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isMain ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(label,
            textAlign: isMain ? TextAlign.left : TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 4),
        Text(value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
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
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Text(display,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.bold,
                      color: Color(0xFF6366F1))),
              const SizedBox(height: 4),
              Text(comparison,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            ],
          ),
        ),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  // 3. Visited Category Bar (the single remaining category section)
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
                      overflow: TextOverflow.ellipsis,
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
              SizedBox(width: 28,
                  child: Text('${e.value}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.bold, color: color))),
            ]),
          );
        }).toList(),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // 4. Achievements — tiered (ALL TIME)
  // ─────────────────────────────────────────────

  static const _kTierColors = {
    'bronze': Color(0xFFCD7F32),
    'silver': Color(0xFFA8A9AD),
    'gold':   Color(0xFFFFD700),
  };

  Widget _buildAchievements(_DashboardData data) {
    final groups  = data.achievements;
    // Count total tiers unlocked across all groups
    final totalTiers    = groups.length * 3;
    final unlockedTiers = groups.fold<int>(
        0, (sum, g) => sum + g.tiers.where((t) => t.unlocked).length);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardStyle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Overall progress ──
          Row(children: [
            Flexible(
              child: Text('$unlockedTiers / $totalTiers tiers unlocked',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600, color: Colors.black87)),
            ),
            const Spacer(),
            Text('${totalTiers == 0 ? 0 : (unlockedTiers / totalTiers * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.bold, color: Color(0xFF6366F1))),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: totalTiers == 0 ? 0 : unlockedTiers / totalTiers,
              minHeight: 6,
              backgroundColor: Colors.grey[100],
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
            ),
          ),
          const SizedBox(height: 20),

          // ── Achievement group list ──
          ...groups.map((group) => _buildAchievementGroupRow(group)),
        ],
      ),
    );
  }

  Widget _buildAchievementGroupRow(AchievementGroup group) {
    final highest = group.highestUnlocked;
    final next    = group.nextTier;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Group title + highest badge ──
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            // Badge circle — shows highest unlocked or locked
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: highest != null
                    ? (_kTierColors[highest.level] ?? const Color(0xFF6366F1)).withOpacity(0.12)
                    : Colors.grey[100],
                border: Border.all(
                  color: highest != null
                      ? (_kTierColors[highest.level] ?? const Color(0xFF6366F1))
                      : Colors.grey[300]!,
                  width: highest != null ? 2 : 1,
                ),
              ),
              child: Center(
                child: highest != null
                    ? Text(highest.emoji, style: const TextStyle(fontSize: 20))
                    : Text(group.baseEmoji,
                        style: TextStyle(fontSize: 20, color: Colors.grey[400])),
              ),
            ),
            const SizedBox(width: 12),

            // Title + current tier label + next tier hint
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(group.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13,
                              fontWeight: FontWeight.bold, color: Colors.black87)),
                    ),
                    if (highest != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: (_kTierColors[highest.level] ?? const Color(0xFF6366F1)).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(highest.level.toUpperCase(),
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: _kTierColors[highest.level] ?? const Color(0xFF6366F1),
                            )),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  if (next != null)
                    Text(
                      '${next.remaining} more to ${next.label}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    )
                  else
                    Text('All tiers unlocked! 🎉',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: Colors.green[600])),
                ],
              ),
            ),

            // Tier dots (bronze / silver / gold)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: group.tiers.map((t) {
                final color = _kTierColors[t.level] ?? Colors.grey;
                return Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: t.unlocked ? color : Colors.grey[200],
                      border: Border.all(
                        color: t.unlocked ? color : Colors.grey[300]!,
                        width: 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ]),

          // ── Progress bar towards next tier ──
          if (next != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const SizedBox(width: 56), // align with text above
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: next.progress,
                    minHeight: 5,
                    backgroundColor: Colors.grey[100],
                    valueColor: AlwaysStoppedAnimation<Color>(
                        _kTierColors[next.level] ?? const Color(0xFF6366F1)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${next.currentValue}/${next.threshold}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // 5. Incomplete Trips (ALL TIME) — tappable
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
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14,
                            fontWeight: FontWeight.bold, color: Colors.black87)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${trip.visited}/${trip.total} places',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11,
                            color: Color(0xFF6366F1), fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded,
                      size: 18, color: Color(0xFF6366F1)),
                ]),
                const SizedBox(height: 4),
                Text(trip.startDate,
                    overflow: TextOverflow.ellipsis,
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
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─────────────────────────────────────────────
  // 6. Monthly Activity
  // ─────────────────────────────────────────────

  Widget _buildMonthlyHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        const Text('Monthly Activity',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Flexible(
          child: Text('Past $_selectedMonths months',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
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
        Text(title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(sub,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
      ]),
    );
  }

  Widget _sectionHeaderWithBadge(String title, String sub, {bool allTime = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Flexible(
          child: Text(title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(sub,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
        if (allTime) ...[
          const SizedBox(width: 8),
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
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
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