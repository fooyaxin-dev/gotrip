import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text("Dashboard"),
        backgroundColor: const Color(0xFF6366F1),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle("Overview"),
            _statGrid(),

            const SizedBox(height: 30),

            _sectionTitle("Top Landmarks"),
            _landmarkCard("KLCC Park", 120),
            _landmarkCard("Batu Caves", 98),
            _landmarkCard("Central Market", 75),

            const SizedBox(height: 30),

            _sectionTitle("Weekly Visits"),
            _chartCard(),
          ],
        ),
      ),
    );
  }

  // ================= Sections =================

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _statGrid() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _statCard("Visited Places", "12", Icons.place)),
            const SizedBox(width: 12),
            Expanded(child: _statCard("Total Visits", "320", Icons.people)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _statCard("Saved Routes", "5", Icons.bookmark)),
            const SizedBox(width: 12),
            Expanded(child: _statCard("Upcoming Trips", "3", Icons.map)),
          ],
        ),
      ],
    );
  }

  Widget _statCard(String title, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF6366F1)),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text(title,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _landmarkCard(String name, int visits) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          const Icon(Icons.location_on, color: Color(0xFF6366F1)),
          const SizedBox(width: 12),
          Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text("$visits visits", style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _chartCard() {
    return Container(
      height: 220,
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: BarChart(
        BarChartData(
          maxY: 120,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
                  return Text(days[value.toInt()]);
                },
              ),
            ),
          ),
          barGroups: List.generate(7, (index) {
            final values = [50, 80, 65, 90, 110, 70, 40];
            return BarChartGroupData(
              x: index,
              barRods: [
                BarChartRodData(
                  toY: values[index].toDouble(),
                  width: 14,
                  color: const Color(0xFF6366F1),
                  borderRadius: BorderRadius.circular(6),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 12,
        ),
      ],
    );
  }
}
