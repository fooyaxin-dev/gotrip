import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart'; // 用于柱状图

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ========== 1️⃣ 统计卡片 ==========
          Row(
            children: [
              Expanded(child: _buildStatCard("Visited Places", "12", Icons.location_on_rounded, Colors.indigo)),
              const SizedBox(width: 15),
              Expanded(child: _buildStatCard("Total Visitors", "320", Icons.people_rounded, Colors.purple)),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(child: _buildStatCard("Saved Routes", "5", Icons.bookmark_rounded, Colors.green)),
              const SizedBox(width: 15),
              Expanded(child: _buildStatCard("Upcoming Trips", "3", Icons.map_rounded, Colors.orange)),
            ],
          ),

          const SizedBox(height: 25),

          // ========== 2️⃣ 热门景点 ==========
          const Text(
            "Top Landmarks",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
          ),
          const SizedBox(height: 12),
          Column(
            children: [
              _buildLandmarkCard("KLCC Park", "120 visits"),
              _buildLandmarkCard("Batu Caves", "98 visits"),
              _buildLandmarkCard("Central Market", "75 visits"),
            ],
          ),

          const SizedBox(height: 25),

          // ========== 3️⃣ 访问次数柱状图 ==========
          const Text(
            "Visits This Week",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: 150,
                barTouchData: BarTouchData(enabled: false),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (double value, TitleMeta meta) {
                        const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
                        return Text(days[value.toInt() % 7], style: const TextStyle(fontSize: 12));
                      },
                    ),
                  ),
                  leftTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                barGroups: [
                  BarChartGroupData(x: 0, barRods: [BarChartRodData(toY: 50, color: Colors.indigo)]),
                  BarChartGroupData(x: 1, barRods: [BarChartRodData(toY: 80, color: Colors.indigo)]),
                  BarChartGroupData(x: 2, barRods: [BarChartRodData(toY: 65, color: Colors.indigo)]),
                  BarChartGroupData(x: 3, barRods: [BarChartRodData(toY: 90, color: Colors.indigo)]),
                  BarChartGroupData(x: 4, barRods: [BarChartRodData(toY: 100, color: Colors.indigo)]),
                  BarChartGroupData(x: 5, barRods: [BarChartRodData(toY: 70, color: Colors.indigo)]),
                  BarChartGroupData(x: 6, barRods: [BarChartRodData(toY: 40, color: Colors.indigo)]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 25),
        ],
      ),
    );
  }

  // ----- 小组件：统计卡片 -----
  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
              Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  // ----- 小组件：热门景点卡片 -----
  Widget _buildLandmarkCard(String name, String visits) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
      ),
      child: Row(
        children: [
          const Icon(Icons.location_on_rounded, color: Colors.indigo, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold))),
          Text(visits, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
