import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      appBar: AppBar(
        title: const Text(
          "Travel Dashboard",
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        actions: [
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.notifications_none, color: Colors.black),
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Greeting
            // const Text(
            //   "Hi, Traveller 👋",
            //   style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            // ),
            // const SizedBox(height: 4),
            const Text(
              "Here's your exploration summary",
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),

            // 1. Top Stats Card
            _buildTopGradientCard(),

            const SizedBox(height: 24),
            _sectionHeader("Top 5 Recognised Landmarks", "Based on all users"),
            // 2. Donut Chart + Landmark List
            _buildTopLandmarksSection(),

            const SizedBox(height: 24),
            _sectionHeader("My Exploration Stats", "Personal data"),
            // 3. Horizontal Scrollable Stat Cards
            _buildScrollableStats(),

            const SizedBox(height: 24),
            _sectionHeader("Recognition Trend", "This week"),
            // 4. Line Chart
            _buildTrendChart(),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // --- 1. Top Gradient Card ---
  Widget _buildTopGradientCard() {
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
        boxShadow: [
          BoxShadow(
            color: Colors.indigo.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _topStatItem("Total Scans", "128", isMain: true),
          Container(width: 1, height: 40, color: Colors.white24),
          _topStatItem("Places\nVisited", "34"),
          _topStatItem("Guides\nUsed", "21"),
          _topStatItem("Countries", "3"),
        ],
      ),
    );
  }

  Widget _topStatItem(String label, String value, {bool isMain = false}) {
    return Column(
      crossAxisAlignment:
          isMain ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: Colors.white,
            fontSize: isMain ? 22 : 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  // --- 2. Donut Chart + Landmark List ---
  Widget _buildTopLandmarksSection() {
    final landmarks = [
      {"name": "KLCC Twin Towers", "percent": "35%", "color": const Color(0xFF6366F1), "value": 35.0},
      {"name": "Batu Caves", "percent": "25%", "color": const Color(0xFF2DD4BF), "value": 25.0},
      {"name": "Petronas Gallery", "percent": "18%", "color": const Color(0xFFF59E0B), "value": 18.0},
      {"name": "Central Market", "percent": "12%", "color": const Color(0xFFEC4899), "value": 12.0},
      {"name": "Others", "percent": "10%", "color": Colors.grey[300]!, "value": 10.0},
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardStyle(),
      child: Row(
        children: [
          // Donut Chart
          SizedBox(
            height: 120,
            width: 120,
            child: Stack(
              children: [
                PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 38,
                    sections: landmarks.map((l) {
                      return PieChartSectionData(
                        color: l["color"] as Color,
                        value: l["value"] as double,
                        radius: 14,
                        showTitle: false,
                      );
                    }).toList(),
                  ),
                ),
                const Center(
                  child: Text(
                    "Top 5",
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          // Landmark List
          Expanded(
            child: Column(
              children: landmarks.map((l) {
                return _landmarkRankRow(
                  l["name"] as String,
                  l["percent"] as String,
                  l["color"] as Color,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _landmarkRankRow(String name, String percent, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name,
                style: const TextStyle(fontSize: 12, color: Colors.black87)),
          ),
          Text(percent,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // --- 3. Horizontal Scrollable Stat Cards ---
  Widget _buildScrollableStats() {
    final stats = [
      {
        "label": "Landmarks\nScanned",
        "value": "128",
        "icon": Icons.document_scanner_outlined,
        "color": const Color(0xFF6366F1),
        "bg": const Color(0xFFEEF0FE),
      },
      {
        "label": "Places\nSaved",
        "value": "47",
        "icon": Icons.bookmark_outline,
        "color": const Color(0xFF2DD4BF),
        "bg": const Color(0xFFE6FAF8),
      },
      {
        "label": "Smart Guides\nUsed",
        "value": "21",
        "icon": Icons.near_me_outlined,
        "color": const Color(0xFFF59E0B),
        "bg": const Color(0xFFFEF8EC),
      },
      {
        "label": "Avg. Distance\nper Trip",
        "value": "1.2 km",
        "icon": Icons.route_outlined,
        "color": const Color(0xFFEC4899),
        "bg": const Color(0xFFFDE9F3),
      },
      {
        "label": "Countries\nExplored",
        "value": "3",
        "icon": Icons.public_outlined,
        "color": const Color(0xFF10B981),
        "bg": const Color(0xFFE7FAF3),
      },
    ];

    return SizedBox(
      height: 130,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: stats.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final s = stats[index];
          return Container(
            width: 120,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: s["bg"] as Color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    s["icon"] as IconData,
                    color: s["color"] as Color,
                    size: 20,
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s["value"] as String,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: s["color"] as Color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s["label"] as String,
                      style: const TextStyle(
                          fontSize: 10, color: Colors.grey, height: 1.3),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // --- 4. Recognition Trend Line Chart ---
  Widget _buildTrendChart() {
    return Container(
      height: 200,
      padding: const EdgeInsets.only(top: 24, right: 20, left: 10, bottom: 10),
      decoration: _cardStyle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Legend
          Row(
            children: [
              _legendDot(const Color(0xFF6366F1), "This Week"),
              const SizedBox(width: 16),
              _legendDot(Colors.grey, "Last Week"),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
                        if (value.toInt() < days.length) {
                          return Text(days[value.toInt()],
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.grey));
                        }
                        return const Text("");
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  // This week
                  LineChartBarData(
                    spots: const [
                      FlSpot(0, 5),
                      FlSpot(1, 12),
                      FlSpot(2, 8),
                      FlSpot(3, 18),
                      FlSpot(4, 14),
                      FlSpot(5, 22),
                      FlSpot(6, 19),
                    ],
                    isCurved: true,
                    color: const Color(0xFF6366F1),
                    barWidth: 3,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: const Color(0xFF6366F1).withOpacity(0.08),
                    ),
                  ),
                  // Last week
                  LineChartBarData(
                    spots: const [
                      FlSpot(0, 3),
                      FlSpot(1, 7),
                      FlSpot(2, 10),
                      FlSpot(3, 9),
                      FlSpot(4, 11),
                      FlSpot(5, 15),
                      FlSpot(6, 13),
                    ],
                    isCurved: true,
                    color: Colors.grey[300]!,
                    barWidth: 2,
                    dashArray: [5, 5],
                    dotData: const FlDotData(show: false),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  // --- Helpers ---
  Widget _sectionHeader(String title, String sub) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Text(sub,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  BoxDecoration _cardStyle() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 10,
          offset: const Offset(0, 4),
        )
      ],
    );
  }
}