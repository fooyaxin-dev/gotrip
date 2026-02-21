import 'package:flutter/material.dart';

class FavouritePage extends StatefulWidget {
  const FavouritePage({super.key});

  @override
  State<FavouritePage> createState() => _FavouritePageState();
}

class _FavouritePageState extends State<FavouritePage> with TickerProviderStateMixin {
  late TabController _tabController;

  final List<Map<String, String>> favorites = [
    {"name": "Moraine Lake", "location": "Alberta, Canada", "image": "https://picsum.photos/400/600?random=1", "rating": "4.9", "type": "Nature"},
    {"name": "Niagara Falls", "location": "Ontario, Canada", "image": "https://picsum.photos/400/400?random=2", "rating": "4.8", "type": "Water"},
    {"name": "Baffin Island", "location": "Nunavut, Canada", "image": "https://picsum.photos/400/500?random=3", "rating": "4.7", "type": "Nature"},
    {"name": "Banff Park", "location": "Alberta, Canada", "image": "https://picsum.photos/400/700?random=4", "rating": "5.0", "type": "Park"},
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      body: CustomScrollView(
        slivers: [
          // 漂亮的沉浸式大标题
          SliverAppBar(
            expandedHeight: 120.0,
            floating: false,
            pinned: true,
            elevation: 0,
            backgroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsetsDirectional.only(start: 20, bottom: 16),
              title: const Text("My Favourites", 
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 24)),
            ),
            actions: [
              IconButton(onPressed: () {}, icon: const Icon(Icons.search, color: Colors.black)),
            ],
          ),

          // 分类选择器
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
                tabs: const [
                  Tab(text: "All"),
                  Tab(text: "Nature"),
                  Tab(text: "Park"),
                  Tab(text: "Water"),
                ],
              ),
            ),
          ),

          // 网格列表
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
                (context, index) {
                  return _buildModernCard(favorites[index]);
                },
                childCount: favorites.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModernCard(Map<String, String> item) {
    return Container(
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
              child: Image.network(
                item['image']!,
                fit: BoxFit.cover,
              ),
            ),
            // 渐变蒙层，防止文字看不清
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
            // 评分标签 (Glassmorphism)
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
                    Text(item['rating']!, 
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                ),
              ),
            ),
            // 收藏按钮
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.favorite, color: Colors.red),
                onPressed: () {},
              ),
            ),
            // 文字信息区
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item['name']!, 
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.location_on, color: Colors.white70, size: 12),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(item['location']!, 
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}