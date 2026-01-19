import 'package:flutter/material.dart';

class InteractionPage extends StatelessWidget {
  const InteractionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Interaction"),
        backgroundColor: const Color(0xFF6366F1),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ===== Post / Feed Card =====
          _buildPostCard(
            username: "Traveler01",
            content: "Just visited KLCC! Amazing view at night 🌃",
            time: "5 mins ago",
          ),

          _buildPostCard(
            username: "GoTrip User",
            content: "Anyone knows the best time to go Batu Caves?",
            time: "20 mins ago",
          ),

          _buildPostCard(
            username: "ExplorerMY",
            content: "Central Market is underrated 👍",
            time: "1 hour ago",
          ),
        ],
      ),
    );
  }

  // ===== 单个 Feed / Post UI =====
  Widget _buildPostCard({
    required String username,
    required String content,
    required String time,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 用户名 + 时间
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                username,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Text(
                time,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // 内容
          Text(
            content,
            style: const TextStyle(fontSize: 14),
          ),

          const SizedBox(height: 12),

          // 操作按钮（Like / Comment）
          const Row(
            children:[
              Icon(Icons.favorite_border_rounded, size: 20, color: Colors.grey),
              SizedBox(width: 16),
              Icon(Icons.chat_bubble_outline_rounded, size: 20, color: Colors.grey),
            ],
          ),
        ],
      ),
    );
  }
}
