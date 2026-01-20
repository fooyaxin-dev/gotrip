import 'dart:typed_data';
import 'package:flutter/material.dart';

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
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  bool _autoExpanded = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: CircleAvatar(
            backgroundColor: Colors.white.withOpacity(0.9),
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.black),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // ===== 顶部照片（45% 高度）=====
          SizedBox(
            height: screenHeight * 0.45,
            width: double.infinity,
            child: Image.memory(
              widget.imageBytes,
              fit: BoxFit.cover,
            ),
          ),

          // ===== Bottom Sheet =====
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.55,
            minChildSize: 0.55,
            maxChildSize: 0.95,
            builder: (context, scrollController) {
              return NotificationListener<DraggableScrollableNotification>(
                onNotification: (notification) {
                  // 吸顶逻辑（mobile 非常顺）
                  if (!_autoExpanded && notification.extent >= 0.60) {
                    _autoExpanded = true;
                    _sheetController.animateTo(
                      0.95,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                  }

                  if (notification.extent <= 0.55) {
                    _autoExpanded = false;
                  }
                  return true;
                },
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(30)),
                  ),
                  child: Column(
                    children: [
                      // 拖拽条
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 10),
                        width: 60,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),

                      // Tabs
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TabBar(
                          controller: _tabController,
                          labelColor: Colors.black,
                          unselectedLabelColor: Colors.grey,
                          indicatorColor: Colors.black,
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
                            // ================= Overview =================
                            SingleChildScrollView(
                              controller: scrollController,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 12),

                                  // 标题
                                  Text(
                                    widget.landmark,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),

                                  const SizedBox(height: 12),

                                  // JSON / description
                                  Text(
                                    widget.rawJson.isEmpty
                                        ? "No extra information"
                                        : widget.rawJson,
                                    style: const TextStyle(fontSize: 12),
                                  ),

                                  const SizedBox(height: 24),

                                  // ===== Cards（只在 detect 完后出现）=====
                                  Row(
                                    children: [
                                      Expanded(
                                        flex: 2,
                                        child: Container(
                                          height: 120,
                                          decoration: BoxDecoration(
                                            color: Colors.grey[200],
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                          child: const Center(child: Text("Card 1")),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        flex: 1,
                                        child: Container(
                                          height: 120,
                                          decoration: BoxDecoration(
                                            color: Colors.grey[200],
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                          child: const Center(child: Text("Card 2")),
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 30),
                                ],
                              ),
                            ),

                            // ================= Reviews =================
                            SingleChildScrollView(
                              controller: scrollController,
                              padding: const EdgeInsets.all(16),
                              child: const Center(
                                child: Text("Reviews content here"),
                              ),
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
}
