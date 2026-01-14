import 'package:flutter/material.dart';
import '../dashboard/dashboard_page.dart'; // 引入 Dashboard

class InteractionPage extends StatefulWidget {
  const InteractionPage({super.key});

  @override
  State<InteractionPage> createState() => _InteractionPageState();
}

class _InteractionPageState extends State<InteractionPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this); // 2 个 tab：Interaction / Dashboard
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Interaction"),
        backgroundColor: const Color(0xFF6366F1),
        bottom: TabBar(
        controller: _tabController,
        tabs: const [
          Tab(
            icon: Icon(Icons.forum_rounded),
            text: "Chat / Feed",
          ),
          Tab(
            icon: Icon(Icons.insights_rounded),
            text: "Dashboard",
          ),
        ],
      ),

      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          Center(child: Text("这里是互动内容，比如 feed / chat / posts")),
          DashboardPage(), // 直接嵌入 Dashboard 页面
        ],
      ),
    );
  }
}
