import 'package:flutter/material.dart';
import '../../services/achievement_service.dart';
import '../../services/error_handler.dart';

class AchievementsPage extends StatefulWidget {
  const AchievementsPage({super.key});

  @override
  State<AchievementsPage> createState() => _AchievementsPageState();
}

class _AchievementsPageState extends State<AchievementsPage> {
  late Future<List<UnlockedBadge>> _future;

  // 🔧 改成跟 dashboard_page.dart / itineraryDetail.dart 一致的浅色风格
  static const _bgColor    = Color(0xFFF8F6FF);
  static const _cardColor  = Colors.white;
  static const _primary    = Color(0xFF7C4DFF);

  // 🔧 跟 achievement_service.dart 里 _kTierColors 用同一套配色，保持全项目统一
  static const _tierColors = {
    'bronze': Color(0xFFCD7F32),
    'silver': Color(0xFFA8A9AD),
    'gold':   Color(0xFFFFD700),
  };

  @override
  void initState() {
    super.initState();
    _future = AchievementService.instance.fetchAllUnlockedBadges();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = AchievementService.instance.fetchAllUnlockedBadges(forceRefresh: true);
    });
    await _future;
  }

  // year → month → badges, relies on fetchAllUnlockedBadges() already being sorted newest-first
  Map<String, Map<String, List<UnlockedBadge>>> _groupByYearMonth(List<UnlockedBadge> badges) {
    final result = <String, Map<String, List<UnlockedBadge>>>{};
    for (final b in badges) {
      final date  = b.tier.unlockedAt;
      final year  = date != null ? '${date.year}' : 'Unknown date';
      final month = date != null ? '${date.month}' : '';
      result.putIfAbsent(year, () => {});
      result[year]!.putIfAbsent(month, () => []);
      result[year]![month]!.add(b);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: FutureBuilder<List<UnlockedBadge>>(
          future: _future,
          builder: (context, snapshot) {
            final loading = snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData;
            final hasError = snapshot.hasError;
            final badges  = snapshot.data ?? [];
            final grouped = _groupByYearMonth(badges);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTopBar(context),
                _buildHeader(loading ? null : badges.length),
                const SizedBox(height: 8),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator(color: _primary))
                      : hasError
                          ? Center(
                              child: AppErrorStateView(
                                title: 'Unable to Load Badges',
                                message: ErrorHandler.userFriendlyMessage(
                                  snapshot.error,
                                  defaultMessage: 'Could not load your unlocked badges. Please try again.',
                                ),
                                onRetry: _refresh,
                              ),
                            )
                          : badges.isEmpty
                              ? _buildEmptyState()
                              : RefreshIndicator(
                                  onRefresh: _refresh,
                                  color: _primary,
                                  backgroundColor: _cardColor,
                                  child: ListView(
                                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                                    children: [
                                      for (final entry in grouped.entries)
                                        _buildYearSection(entry.key, entry.value),
                                    ],
                                  ),
                                ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── Top bar: back only ──
  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: Colors.black87, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  // ── Header: title + total count badge ──
  Widget _buildHeader(int? total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('My Badges',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Color(0xFF1A1A2E))),
          const Spacer(),
          Container(
            width: 66, height: 66,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFFFD54F), Color(0xFFFFA726)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(color: const Color(0xFFFFD54F).withOpacity(0.35), blurRadius: 16, offset: const Offset(0, 4)),
              ],
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(total != null ? '$total' : '—', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A2E))),
                  const Text('total', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF1A1A2E))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.emoji_events_outlined, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text('No badges unlocked yet', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
        ],
      ),
    );
  }

  // ── Year section ──
  Widget _buildYearSection(String year, Map<String, List<UnlockedBadge>> months) {
    final yearTotal = months.values.fold<int>(0, (sum, list) => sum + list.length);

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$year · $yearTotal total',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF1A1A2E))),
          for (final entry in months.entries) _buildMonthSection(entry.key, entry.value),
        ],
      ),
    );
  }

  // ── Month section ──
  Widget _buildMonthSection(String month, List<UnlockedBadge> badges) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (month.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 10),
              child: Row(
                children: [
                  Container(width: 4, height: 4, decoration: BoxDecoration(color: Colors.grey[400], shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text('Month $month', style: TextStyle(fontSize: 13, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          GridView.count(
  crossAxisCount: 3,
  shrinkWrap: true,
  physics: const NeverScrollableScrollPhysics(),
  crossAxisSpacing: 12,
  mainAxisSpacing: 14,
  childAspectRatio: 0.68, // 根据你的卡片宽高比调整
  children: badges.map(_buildBadgeTile).toList(),
),
        ],
      ),
    );
  }

  // ── Single hexagon badge tile ──
  Widget _buildBadgeTile(UnlockedBadge b) {
    final tier  = b.tier;
    final color = _tierColors[tier.level] ?? _primary;
    final dateStr = tier.unlockedAt != null
        ? '${tier.unlockedAt!.year}-${tier.unlockedAt!.month.toString().padLeft(2, '0')}-${tier.unlockedAt!.day.toString().padLeft(2, '0')}'
        : '';

    return SizedBox(
      width: 84,
      child: Column(
        children: [
          ClipPath(
            clipper: _HexagonClipper(),
            child: Container(
              width: 72, height: 80,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [color.withOpacity(0.9), color.withOpacity(0.5)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                boxShadow: [
                  // 🆕 浅色背景下需要一点阴影，不然徽章会跟背景融在一起、缺乏层次
                  BoxShadow(color: color.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 3)),
                ],
              ),
              child: Center(
                child: Text(tier.emoji, style: const TextStyle(fontSize: 30)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tier.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1A1A2E)),
          ),
          const SizedBox(height: 2),
          Text(
            tier.level.toUpperCase(),
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color),
          ),
          if (dateStr.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(dateStr, style: TextStyle(fontSize: 9, color: Colors.grey[400])),
          ],
        ],
      ),
    );
  }
}

// ── Hexagon clipper ──
class _HexagonClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(w * 0.5, 0)
      ..lineTo(w, h * 0.25)
      ..lineTo(w, h * 0.75)
      ..lineTo(w * 0.5, h)
      ..lineTo(0, h * 0.75)
      ..lineTo(0, h * 0.25)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}