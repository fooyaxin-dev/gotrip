import 'package:flutter/material.dart';

class favouritePage extends StatefulWidget {
  const favouritePage({super.key});

  @override
  State<favouritePage> createState() => _favouritePageState();
}

class _favouritePageState extends State<favouritePage> {
  // Hardcode 数据，之后替换为 Database 资料
  final List<Map<String, String>> favorites = [
    {
      "name": "Moraine Lake",
      "location": "Alberta, Canada",
      "image": "assets/images/lake.jpg", // 确保路径正确
      "rating": "4.9"
    },
    {
      "name": "Niagara Falls",
      "location": "Ontario, Canada",
      "image": "assets/images/falls.jpg",
      "rating": "4.8"
    },
    {
      "name": "Baffin Island",
      "location": "Nunavut, Canada",
      "image": "assets/images/island.jpg",
      "rating": "4.7"
    },
    {
      "name": "Banff Park",
      "location": "Alberta, Canada",
      "image": "assets/images/park.jpg",
      "rating": "5.0"
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("My Favourites", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: GridView.builder(
          itemCount: favorites.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, // 一行显示两个
            crossAxisSpacing: 15, // 左右间距
            mainAxisSpacing: 15, // 上下间距
            childAspectRatio: 0.75, // 卡片长宽比
          ),
          itemBuilder: (context, index) {
            final item = favorites[index];
            return _buildFavoriteCard(item);
          },
        ),
      ),
    );
  }

  Widget _buildFavoriteCard(Map<String, String> item) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.15),
            spreadRadius: 2,
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 图片部分
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: Image.asset(
                    item['image']!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                  ),
                ),
                // 右上角的红色爱心
                Positioned(
                  top: 10,
                  right: 10,
                  child: CircleAvatar(
                    backgroundColor: Colors.white.withOpacity(0.8),
                    radius: 15,
                    child: const Icon(Icons.favorite, color: Colors.red, size: 18),
                  ),
                ),
              ],
            ),
          ),
          // 2. 文字描述部分
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Text(
                    item['name']!,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      const Icon(Icons.location_on, size: 14, color: Color(0xFF4DB6AC)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          item['location']!,
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Icon(Icons.star, size: 14, color: Colors.amber),
                      const SizedBox(width: 4),
                      Text(item['rating']!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}