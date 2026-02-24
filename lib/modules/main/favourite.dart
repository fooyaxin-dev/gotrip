import 'package:flutter/material.dart';
import '../../services/favourite_service.dart';
import '../realtime/favouriteButton.dart';
import '../realtime/placeDetailPage.dart';

class FavouritePage extends StatefulWidget {
  const FavouritePage({super.key});

  @override
  State<FavouritePage> createState() => _FavouritePageState();
}

class _FavouritePageState extends State<FavouritePage> with TickerProviderStateMixin {
  late TabController _tabController;
  String _selectedType = 'All';

  static const List<String> _tabs = ['All', 'Nature', 'Park', 'Water', 'Food', 'Other'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) return;
      setState(() {
        _selectedType = _tabs[_tabController.index];
      });
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _getPlaceCategory(Map<String, dynamic> place) {
    final types = (place['types'] as List?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
    if (types.any((t) => t.contains('park') || t.contains('garden'))) return 'Park';
    if (types.any((t) => t.contains('water') || t.contains('lake') || t.contains('beach') || t.contains('river'))) return 'Water';
    if (types.any((t) => t.contains('forest') || t.contains('nature') || t.contains('mountain'))) return 'Nature';
    if (types.any((t) => t.contains('restaurant') || t.contains('food') || t.contains('cafe') || t.contains('bar'))) return 'Food';
    return 'Other';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: FavouriteService.getFavouritesStream(),
        builder: (context, snapshot) {
          final allFavourites = snapshot.data ?? [];

          final filtered = _selectedType == 'All'
              ? allFavourites
              : allFavourites.where((p) => _getPlaceCategory(p) == _selectedType).toList();

          return CustomScrollView(
            slivers: [
              // 沉浸式大标题
              SliverAppBar(
                expandedHeight: 120.0,
                floating: false,
                pinned: true,
                elevation: 0,
                backgroundColor: Colors.white,
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsetsDirectional.only(start: 20, bottom: 16),
                  title: const Text(
                    "My Favourites",
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 24),
                  ),
                ),
                actions: [
                  IconButton(onPressed: () {}, icon: const Icon(Icons.search, color: Colors.black)),
                ],
              ),

              // 分类 Tab
              SliverToBoxAdapter(
                child: Container(
                  color: Colors.white,
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    indicatorColor: const Color(0xFF6366F1),
                    labelColor: const Color(0xFF6366F1),
                    unselectedLabelColor: Colors.grey,
                    indicatorSize: TabBarIndicatorSize.label,
                    tabs: _tabs.map((t) => Tab(text: t)).toList(),
                  ),
                ),
              ),

              // 加载中
              if (snapshot.connectionState == ConnectionState.waiting)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )

              // 空状态
              else if (filtered.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.favorite_border, size: 72, color: Colors.grey[300]),
                        const SizedBox(height: 16),
                        Text(
                          _selectedType == 'All' ? '还没有收藏' : '此分类暂无收藏',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey[500]),
                        ),
                        const SizedBox(height: 8),
                        Text('浏览地点时点击 ❤️ 即可收藏',
                            style: TextStyle(fontSize: 14, color: Colors.grey[400])),
                      ],
                    ),
                  ),
                )

              // 网格
              else
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.7,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _buildModernCard(context, filtered[index]),
                      childCount: filtered.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildModernCard(BuildContext context, Map<String, dynamic> place) {
    final String placeId = place['placeId'] ?? '';
    final String name = place['name'] ?? 'Unknown';
    final String address = place['address'] ?? '';
    final double? rating = (place['rating'] as num?)?.toDouble();
    final String? photoUrl = place['photoUrl'];
    final double? lat = (place['lat'] as num?)?.toDouble();
    final double? lng = (place['lng'] as num?)?.toDouble();

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PlaceDetailPage(placeId: placeId, lat: lat, lng: lng),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 5)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              // 背景大图
              Positioned.fill(
                child: photoUrl != null
                    ? Image.network(
                        photoUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: Colors.grey[200],
                          child: Icon(Icons.image, size: 40, color: Colors.grey[400]),
                        ),
                      )
                    : Container(
                        color: Colors.grey[200],
                        child: Icon(Icons.image, size: 40, color: Colors.grey[400]),
                      ),
              ),

              // 渐变蒙层
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
                    ),
                  ),
                ),
              ),

              // 评分标签（左上角，Glassmorphism）
              if (rating != null)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),

              // ❤️ 收藏按钮（右上角）— 点击可取消收藏，卡片会从列表消失
              Positioned(
                top: 4,
                right: 4,
                child: FavouriteButton(
                  placeId: placeId,
                  name: name,
                  address: address,
                  rating: rating,
                  photoUrl: photoUrl,
                  lat: lat,
                  lng: lng,
                  showBackground: false,
                  iconSize: 22,
                  activeColor: Colors.red,
                  inactiveColor: Colors.white70,
                ),
              ),

              // 文字信息（底部）
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.location_on, color: Colors.white70, size: 12),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            address,
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}