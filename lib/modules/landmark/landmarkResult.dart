import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart'; // 新增
import 'package:gotrip/modules/realtime/detectPlacePage.dart';
import '../../services/wikipedia_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import '../../services/location_service.dart';   

class ResultPage extends StatefulWidget {
  final Uint8List imageBytes;
  final String landmark;
  final String rawJson;

  const ResultPage({
    super.key,
    required this.imageBytes,
    required this.landmark,
    required this.rawJson,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final DraggableScrollableController _sheetController = DraggableScrollableController();

  // Wikipedia 信息
  String wikiTitle = '';
  String wikiExtract = '';
  String wikiImage = '';
  String wikiUrl = '';
  bool wikiLoading = true;

  bool _autoExpanded = false;


  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _fetchWikipediaInfo();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _fetchWikipediaInfo() async {
    try {
      final landmarkName = widget.landmark.split(' (Confidence')[0];
      final wikiResult = await WikipediaService.fetchLandmarkHistory(landmarkName);

      setState(() {
        wikiTitle = wikiResult['title'] ?? landmarkName;
        wikiExtract = wikiResult['summary'] ?? 'No historical info available';
        wikiImage = wikiResult['thumbnail'] ?? '';
        wikiUrl = wikiResult['wikiUrl'] ?? '';
        if (wikiUrl.isEmpty) {
          wikiUrl = 'https://en.wikipedia.org/wiki/${landmarkName.replaceAll(' ', '_')}';
        }
        wikiLoading = false;
      });
    } catch (e) {
      setState(() {
        wikiExtract = 'Failed to load historical information.';
        wikiLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    // ✅ 获取全局实时位置（假设你的 LocationService 提供最新 lat/lng）
    final userLat = LocationService.instance.currentLat;
    final userLng = LocationService.instance.currentLng;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12, top: 8),
          child: CircleAvatar(
            backgroundColor: Colors.white.withAlpha(200),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.black, size: 18),
              onPressed: () => Navigator.pop(context, true), // 👈 关键
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          SizedBox(
            height: screenHeight * 0.45,
            width: double.infinity,
            child: Image.memory(
              
              widget.imageBytes,
              fit: BoxFit.cover,
            ),

          ),
          // 在 Image.memory 下面添加
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.3), Colors.transparent],
                ),
              ),
            ),
          ),

          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.55,
            minChildSize: 0.55,
            maxChildSize: 0.95,
            builder: (context, scrollController) {
              return NotificationListener<DraggableScrollableNotification>(
                onNotification: (notification) {
                  if (!_autoExpanded && notification.extent >= 0.60) {
                    _autoExpanded = true;
                    _sheetController.animateTo(0.95,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut);
                  }
                  if (notification.extent <= 0.55) _autoExpanded = false;
                  return true;
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ],
                  ),
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 12),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TabBar(
                          controller: _tabController,
                          labelColor: Colors.black,
                          unselectedLabelColor: Colors.grey[400],
                          indicatorColor: Colors.black,
                          indicatorWeight: 3,
                          indicatorSize: TabBarIndicatorSize.label,
                          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          tabs: const [
                            Tab(text: "Overview"),
                            Tab(text: "Reviews"),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            SingleChildScrollView(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (widget.landmark == 'No landmark detected')
                                    const Center(
                                      child: Padding(
                                        padding: EdgeInsets.only(top: 50),
                                        child: Text(
                                          'No landmark detected in this image.',
                                          style: TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
                                        ),
                                      ),
                                    )
                                  else ...[
                                    wikiLoading
                                        ? const Center(
                                            child: Padding(
                                              padding: EdgeInsets.only(top: 50),
                                              child: CircularProgressIndicator(color: Colors.black),
                                            ),
                                          )
                                        : _buildProSummaryContent(),
                                    const SizedBox(height: 24),

                                    // ================= Cards =================
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 120,
                                          child: _buildInfoCard(
                                            label: "Weather",
                                            value: "28°C Sunny",
                                            icon: Icons.wb_sunny_rounded,
                                            color: const Color(0xFFFFF3E0),
                                            height: 120,
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: LocationService.instance.currentPosition == null
                                              ? const Center(child: CircularProgressIndicator())
                                              : GestureDetector(
                                                  onTap: () {
                                                    final pos = LocationService.instance.currentPosition;
                                                    if (pos != null) {
                                                      Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (_) => RealTimeDetectPage(
                                                            landmarkLat: pos.latitude,
                                                            landmarkLng: pos.longitude,
                                                          ),
                                                        ),
                                                      );
                                                    }
                                                  },
                                                  child: Container(
                                                    height: 120,
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(20),
                                                    ),
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(20),
                                                      child: Stack(
                                                        children: [
                                                          Image.network(
                                                            'https://maps.googleapis.com/maps/api/staticmap?center=${LocationService.instance.currentPosition!.latitude},${LocationService.instance.currentPosition!.longitude}&zoom=15&size=600x300&markers=color:red%7Clabel:U%7C${LocationService.instance.currentPosition!.latitude},${LocationService.instance.currentPosition!.longitude}&key=AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc',
                                                            fit: BoxFit.cover,
                                                            width: double.infinity,
                                                            height: double.infinity,
                                                          ),
                                                          Positioned(
                                                            top: 10,
                                                            right: 10,
                                                            child: Container(
                                                              decoration: BoxDecoration(
                                                                color: Colors.black.withOpacity(0.5),
                                                                borderRadius: BorderRadius.circular(8),
                                                              ),
                                                              child: IconButton(
                                                                icon: const Icon(Icons.open_in_new, color: Colors.white, size: 20),
                                                                onPressed: () {
                                                                  final pos = LocationService.instance.currentPosition;
                                                                  if (pos != null) {
                                                                    final mapUrl =
                                                                        'https://www.google.com/maps/search/?api=1&query=${pos.latitude},${pos.longitude}';
                                                                    launchUrl(Uri.parse(mapUrl), mode: LaunchMode.externalApplication);
                                                                  }
                                                                },
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            SingleChildScrollView(
                              controller: scrollController,
                              padding: const EdgeInsets.all(20),
                              child: const Center(child: Text("Reviews content here")),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ======================== UI Components ========================
Widget _buildProSummaryContent() {
    if (widget.landmark == 'No landmark detected') {
      return const Center(
        child: Text('No landmark detected.', style: TextStyle(color: Colors.grey)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 标题与置顶标签
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                wikiTitle,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "Landmark",
                style: TextStyle(color: Colors.blue[700], fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 2. 维基百科封面图 (带精致投影)
        if (wikiImage.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                )
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.network(
                wikiImage,
                height: 220,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ),

        // 3. 摘要文字 (去掉黄色背景，改用左边框装饰)
        Container(
          padding: const EdgeInsets.only(left: 16),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: Colors.grey[300]!, width: 3)),
          ),
          child: Text(
            wikiExtract,
            textAlign: TextAlign.justify,
            style: TextStyle(
              fontSize: 15,
              color: Colors.grey[800],
              height: 1.7,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 4. 阅读全文按钮 (更精致的 TextButton 风格)
        if (wikiUrl.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _launchWiki(wikiUrl),
              icon: const Icon(Icons.auto_stories, size: 18),
              label: const Text("Read More on Wikipedia"),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blue[800],
                textStyle: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
      ],
    );
  }

 Widget _buildInfoCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    double? height,
  }) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(20), // 增加内边距
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(24), // 增加圆角
        gradient: LinearGradient( // 增加微弱渐变
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, color.withOpacity(0.8)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: Colors.black87),
          ),
          const Spacer(),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: -0.5),
          ),
        ],
      ),
    );
  }

  Future<void> _launchWiki(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        // fallback 到默认浏览器
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Cannot open URL")),
      );
    }
  }

}