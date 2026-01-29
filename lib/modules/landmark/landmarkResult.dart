import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart'; // 新增
import 'package:gotrip/modules/guide/guidePage.dart';
import 'wikipedia.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import '../main/location_service.dart';   

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
                                                          builder: (_) => RealTimeGuidePage(
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
      return const Text(
        'No landmark detected in this image.',
        style: TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          wikiTitle,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        if (wikiImage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                wikiImage,
                height: 200,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ),
        Text(
          wikiExtract,
          textAlign: TextAlign.justify,
          style: TextStyle(
            fontSize: 15,
            color: Colors.grey[800],
            height: 1.6,
            backgroundColor: Colors.yellowAccent.withAlpha(30),
          ),
        ),
        const SizedBox(height: 12),
        if (wikiUrl.isNotEmpty)
          InkWell(
            onTap: () => _launchWiki(wikiUrl),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Read full story on Wikipedia",
                    style: TextStyle(color: Colors.blue[700], fontWeight: FontWeight.bold, fontSize: 13)),
                Icon(Icons.chevron_right, size: 16, color: Colors.blue[700]),
              ],
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
    double? height,   // 新增可选高度
  }) {
    return Container(
      height: height,  // ⚡ 使用传入高度
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.5),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween, // 让内容撑满高度
        children: [
          Icon(icon, size: 22, color: Colors.black87),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: -0.5),
              ),
            ],
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