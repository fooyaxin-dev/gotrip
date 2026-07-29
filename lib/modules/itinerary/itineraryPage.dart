// pages/itinerary/itinerary_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/itineraryModel.dart';
import '../../services/itinerary_service.dart';
import '../../services/userPreference_service.dart';
import '../itinerary/itineraryGeneratePage.dart';
import 'itineraryDetail.dart';
import '../../services/apps_Loading.dart';

class ItineraryPage extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onPlanTrip;
  const ItineraryPage({super.key, this.onBack, this.onPlanTrip});

  @override
  State<ItineraryPage> createState() => _ItineraryPageState();
}

class _ItineraryPageState extends State<ItineraryPage>
    with TickerProviderStateMixin {
  List<ItineraryModel> _itineraries = [];
  bool _loading = true;
  late final TabController _outerTabController; // Ongoing / Completed
  late final TabController _innerTabController; // (inside Ongoing) Ongoing / Planned

  @override
  void initState() {
    super.initState();
    _outerTabController = TabController(length: 2, vsync: this);
    _innerTabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _outerTabController.dispose();
    _innerTabController.dispose();
    super.dispose();
  }

  String? _firstPhotoUrl(ItineraryModel item) {
    for (final day in item.days) {
      for (final place in day.places) {
        if (place.photoUrl != null && place.photoUrl!.isNotEmpty) {
          return place.photoUrl;
        }
      }
    }
    return null;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await ItineraryService.instance.fetchAll();
    if (!mounted) return;
    setState(() { _itineraries = list; _loading = false; });
    _precacheAllPhotos(list); // ← 新增:数据到手就开始预热,不等 tab 切换
  }

  void _precacheAllPhotos(List<ItineraryModel> list) {
    for (final item in list) {
      final url = _firstPhotoUrl(item);
      if (url == null) continue;
      // fire-and-forget:不 await,失败也不影响主流程,
      // 图片加载失败的兜底交给 CachedNetworkImage 自己的 errorWidget
      precacheImage(CachedNetworkImageProvider(url), context)
          .catchError((_) {});
    }
  }

  Future<void> _delete(ItineraryModel item) async {
    final success = await ItineraryService.instance.delete(item.id);

    if (!mounted) return;

    if (success) {
      setState(() => _itineraries.remove(item));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Itinerary deleted'),
            behavior: SnackBarBehavior.floating),
      );
    } else {
      // ★ 兜底：万一真的被删到已完成的行程（比如未来某个入口漏了UI check），
      // 至少用户能看到明确反馈，而不是静默失败
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Completed itineraries cannot be deleted'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  // Build

  @override
  Widget build(BuildContext context) {
    final planned   = _itineraries.where((i) => !i.isStarted).toList();
    final ongoing   = _itineraries.where((i) => i.isStarted && !i.isCompleted).toList();
    final completed = _itineraries.where((i) => i.isCompleted).toList();
    

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
        bottom: _loading
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: _buildOuterTabBar(ongoing.length + planned.length, completed.length),
              ),
      ),
      body: _loading
          ? const Center(child: TravelLoadingIndicator())
          : _itineraries.isEmpty
              ? _buildEmpty()
              : TabBarView(
                  controller: _outerTabController,
                  children: [
                    _buildOngoingOuterTab(ongoing, planned),
                    _buildFlatTab(completed, 'No completed trips yet'),
                  ],
                ),
    );
  }

  Widget _buildOuterTabBar(int ongoingTotalCount, int completedCount) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: TabBar(
        controller: _outerTabController,
        indicator: BoxDecoration(
          color: const Color(0xFF7C4DFF),
          borderRadius: BorderRadius.circular(14),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: const Color(0xFF7C4DFF),
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        tabs: [
          Tab(text: 'Ongoing ($ongoingTotalCount)'),
          Tab(text: 'Completed ($completedCount)'),
        ],
      ),
    );
  }

  // Nested tab: the "Ongoing" outer tab contains its own small tab bar
  // with 2 sub-tabs — Ongoing / Planned.
  Widget _buildOngoingOuterTab(List<ItineraryModel> ongoing, List<ItineraryModel> planned) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: TabBar(
            controller: _innerTabController,
            indicatorColor: const Color(0xFF7C4DFF),
            indicatorWeight: 3,
            labelColor: const Color(0xFF7C4DFF),
            unselectedLabelColor: Colors.grey[500],
            labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            tabs: [
              Tab(text: 'Ongoing (${ongoing.length})'),
              Tab(text: 'Planned (${planned.length})'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _innerTabController,
            children: [
              _buildFlatTab(ongoing, 'No ongoing trips'),
              _buildFlatTab(planned, 'No planned trips yet'),
            ],
          ),
        ),
      ],
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

  Widget _emptyTabMessage(String text) {
    return Center(
      child: Text(text, style: TextStyle(fontSize: 14, color: Colors.grey[500])),
    );
  }

  // Shared flat list builder — used by all 3 tabs (Planned / Ongoing / Completed)
  Widget _buildFlatTab(List<ItineraryModel> items, String emptyMessage) {
    if (items.isEmpty) {
      return _emptyTabMessage(emptyMessage);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: items.map(_buildCard).toList(),
    );
  }

  Widget _buildCard(ItineraryModel item) {

    final totalPlaces = item.days.fold<int>(
        0, (sum, d) => sum + d.places.length);

    final firstPhoto = _firstPhotoUrl(item);

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
          // ★ 已完成的行程边框稍微加一点绿色识别，跟进行中区分开
          border: item.isCompleted
              ? Border.all(color: const Color(0xFF2ECC71).withOpacity(0.3), width: 1)
              : item.isStarted
                  ? Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.3), width: 1)
                  : null,

          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06),
              blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // Photo banner
            Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20)),
                  child: SizedBox(
                    height: 140,
                    width: double.infinity,
                    child: firstPhoto != null
                      ? CachedNetworkImage(
                          imageUrl: firstPhoto,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _bannerPlaceholder(),
                        )
                      : _bannerPlaceholder(),
                  ),
                ),
              ],
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
                      // ★ 核心逻辑：已开始/已完成 → 锁定徽章（不可点）；未开始 → 删除按钮
                      if (item.isStarted)
                        Tooltip(
                          message: item.isCompleted
                              ? 'Completed trips are kept as your travel record'
                              : 'Trips you\'ve started are kept as your travel record',
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.lock_outline_rounded,
                                size: 16, color: Colors.grey[500]),
                          ),
                        )
                      else
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