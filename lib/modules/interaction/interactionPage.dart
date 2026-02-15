import 'package:flutter/material.dart';
import 'addPost.dart';

// 模拟的发布页面
class AddPostPage extends StatelessWidget {
  const AddPostPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("发布动态")),
      body: const Center(child: Text("在这里编辑你的动态")),
    );
  }
}

class InteractionPage extends StatelessWidget {
  const InteractionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA), // 更高级的浅灰色
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        // --- 优化后的头部 ---
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Followed", style: TextStyle(color: Colors.grey, fontSize: 15)),
            const SizedBox(width: 20),
            Column(
              children: [
                const Text("Post", style: TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Container(height: 3, width: 20, decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(2))),
              ],
            ),
            const SizedBox(width: 20),
            const Text("Nearby", style: TextStyle(color: Colors.grey, fontSize: 15)),
          ],
        ),
        centerTitle: true,
        // --- 右上角新增发布按钮 ---
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.black, size: 28),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const PostingPage()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(), // 增加果冻回弹效果
        children: [
          const SizedBox(height: 10),
          _buildPostCard(
            username: "Traveler01",
            content: "Just visited KLCC! Amazing view at night 🌃 #KualaLumpur",
            time: "5 mins ago",
            avatarColor: Colors.blueAccent,
          ),
          _buildPostCard(
            username: "GoTrip User",
            content: "Anyone knows the best time to go Batu Caves? 🐒 想避开人潮，求建议！",
            time: "20 mins ago",
            avatarColor: Colors.greenAccent,
          ),
          _buildPostCard(
            username: "ExplorerMY",
            content: "Central Market is underrated 👍 这里的文创产品很有特色。",
            time: "1 hour ago",
            avatarColor: Colors.purpleAccent,
          ),
        ],
      ),
    );
  }

  Widget _buildPostCard({
    required String username,
    required String content,
    required String time,
    required Color avatarColor,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15), // 圆角卡片更有亲和力
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5),
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: avatarColor,
                  child: const Icon(Icons.person, color: Colors.white, size: 22),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      username,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "$time · GoTrip 极速版",
                      style: TextStyle(color: Colors.grey[500], fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.more_horiz, color: Colors.grey),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(fontSize: 15, color: Color(0xFF333333), height: 1.5),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, thickness: 0.5),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildSocialBtn(Icons.share_outlined, "转发"),
              _buildSocialBtn(Icons.chat_bubble_outline, "12"),
              _buildSocialBtn(Icons.thumb_up_outlined, "赞"),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSocialBtn(IconData icon, String label) {
    return InkWell(
      onTap: () {},
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[700]),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: Colors.grey[700], fontSize: 13)),
        ],
      ),
    );
  }
}