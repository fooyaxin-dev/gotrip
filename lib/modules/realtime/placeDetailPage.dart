import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/placesAPI_service.dart';


class PlaceDetailPage extends StatefulWidget {
  final String placeId;
  final double? lat;
  final double? lng;

  const PlaceDetailPage({
    super.key, 
    required this.placeId,
    this.lat,
    this.lng,
  });

  @override
  State<PlaceDetailPage> createState() => _PlaceDetailPageState();
}



class _PlaceDetailPageState extends State<PlaceDetailPage> {
  Map<String, dynamic>? placeDetail;
  bool loading = true;
  String? error;
  int _currentPhotoIndex = 0; // 当前显示的照片索引
  

  late PageController _pageController;
  Timer? _autoPlayTimer;
  bool _isUserInteracting = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 1.0);
    _fetchPlaceDetails();
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }


  Future<void> _fetchPlaceDetails() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      // 调用新的 getPlaceDetails（按需从 Firebase 读，缓存不存在才 API）
      final data = await PlacesApiService.getPlaceDetails(widget.placeId);

      setState(() {
        placeDetail = data;
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }


  void _startAutoPlay(int total) {
    _autoPlayTimer?.cancel();

    if (total <= 1) return;

    _autoPlayTimer = Timer.periodic(
      const Duration(seconds: 4),
      (timer) {
        if (_isUserInteracting) return;

        int nextPage = _currentPhotoIndex + 1;
        if (nextPage >= total) nextPage = 0;

        _pageController.animateToPage(
          nextPage,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutCubic,
        );
      },
    );
  }




  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Place Details')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text('Error: $error'))
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    final name = placeDetail?['displayName']?['text'] ?? 'Unknown';
    final address = placeDetail?['formattedAddress'] ?? 'No address';
    final rating = placeDetail?['rating'];
    final phone = placeDetail?['internationalPhoneNumber'];
    final website = placeDetail?['websiteUri'];
    final isOpen = placeDetail?['regularOpeningHours']?['openNow'];
    final photos = placeDetail?['photos'] as List?;

    final geometry = placeDetail?['geometry'];
    final location = geometry?['location'];
    final double? lat = widget.lat;
    final double? lng = widget.lng;


    print('geometry = $geometry');
    print('lat = $lat, lng = $lng');

    // 构造所有图片 URL
    List<String> photoUrls = [];
    if (photos != null && photos.isNotEmpty) {
      for (var photo in photos) {
        final photoName = photo['name'];
        photoUrls.add(PlacesApiService.buildPhotoUrl(photoName, maxWidth: 800));
      }
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 顶部图片轮播
          _buildPhotoCarousel(photoUrls),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 2. 标题与评分
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (rating != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange[50],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.star, color: Colors.orange, size: 18),
                            const SizedBox(width: 4),
                            Text(
                              rating.toString(),
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                
                // 3. 营业状态标签
                if (isOpen != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isOpen ? Colors.green[50] : Colors.red[50],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isOpen ? "● 正在营业" : "○ 已打烊",
                      style: TextStyle(
                        color: isOpen ? Colors.green[700] : Colors.red[700],
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  
                const SizedBox(height: 20),
                const Divider(),
                
                // 4. 快速操作栏 (电话, 网站, 路线)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildActionButton(Icons.phone, "电话", phone != null),
                      _buildActionButton(Icons.public, "网站", website != null),
                      // 在 placeDetailPage.dart 中
                      _buildActionButton(
                        Icons.directions,
                        "路线",
                        widget.lat != null && widget.lng != null,
                        onTap: () {
                          if (widget.lat != null && widget.lng != null) {
                            // ✅ 直接返回导航所需的完整数据
                            Navigator.pop(context, {
                              'action': 'navigate', // 👈 标记这是导航请求
                              'lat': widget.lat,
                              'lng': widget.lng,
                              'name': placeDetail?['displayName']?['text'] ?? 'Unknown',
                              'id': widget.placeId,
                              'rating': placeDetail?['rating'],
                              'address': placeDetail?['formattedAddress'],
                              'photoUrl': placeDetail?['photos']?[0] != null 
                                  ? PlacesApiService.buildPhotoUrl(
                                      placeDetail!['photos'][0]['name'], 
                                      maxWidth: 400
                                    ) 
                                  : null,
                            });
                          }
                        },
                      ),
                      _buildActionButton(Icons.share, "分享", true),
                    ],
                  ),
                ),
                const Divider(),
                const SizedBox(height: 20),

                // 5. 详细信息卡片
                _buildInfoSection(Icons.location_on, "地址", address),
                // --- 新增：营业时间展开列表 ---
                if (placeDetail?['regularOpeningHours']?['weekdayDescriptions'] != null)
                  _buildOpeningHours(placeDetail!['regularOpeningHours']['weekdayDescriptions']),
                if (phone != null) _buildInfoSection(Icons.call, "联系电话", phone),
                if (website != null) _buildInfoSection(Icons.language, "官方网站", website),

                //6. 用户评价标题
                const Divider(),
                const SizedBox(height: 10),
                const Text(
                  "用户评价",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                // 6. 评价列表
                if (placeDetail?['reviews'] != null)
                  ...((placeDetail!['reviews'] as List).map((review) => _buildReviewItem(review)))
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text("暂无评价", style: TextStyle(color: Colors.grey)),
                  ),


              ],
            ),
          ),
        ],
      ),
    );
  }

  // 新增：图片轮播组件
  Widget _buildPhotoCarousel(List<String> photoUrls) {
    if (photoUrls.isEmpty) {
      return Container(
        height: 250,
        color: Colors.grey[200],
        child: const Icon(Icons.image, size: 50),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startAutoPlay(photoUrls.length);
    });

    return Stack(
      children: [
        SizedBox(
          height: 250,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) {
                _isUserInteracting = true;
              } else if (notification is ScrollEndNotification) {
                _isUserInteracting = false;
              }
              return false; // ⚠️ 一定要 return false
            },
            child: PageView.builder(
              controller: _pageController,
              itemCount: photoUrls.length,
              physics: const PageScrollPhysics(), // Snap + 惯性
              onPageChanged: (index) {
                setState(() {
                  _currentPhotoIndex = index;
                });
              },
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () {
                    _showFullScreenPhoto(context, photoUrls, index);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: NetworkImage(photoUrls[index]),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // 指示点
        if (photoUrls.length > 1)
          Positioned(
            bottom: 15,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(photoUrls.length, (index) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: _currentPhotoIndex == index ? 10 : 8,
                  height: _currentPhotoIndex == index ? 10 : 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _currentPhotoIndex == index
                        ? Colors.white
                        : Colors.white.withOpacity(0.4),
                  ),
                );
              }),
            ),
          ),

        // 计数器
        if (photoUrls.length > 1)
          Positioned(
            top: 15,
            right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                '${_currentPhotoIndex + 1}/${photoUrls.length}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }


  // 新增：全屏查看照片
  void _showFullScreenPhoto(BuildContext context, List<String> photoUrls, int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: PageView.builder(
            controller: PageController(initialPage: initialIndex),
            itemCount: photoUrls.length,
            itemBuilder: (context, index) {
              return InteractiveViewer(
                child: Center(
                  child: Image.network(
                    photoUrls[index],
                    fit: BoxFit.contain,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // 辅助方法：构建功能按钮
  Widget _buildActionButton(
    IconData icon,
    String label,
    bool isAvailable, {
    VoidCallback? onTap,
  }) {
    return Opacity(
      opacity: isAvailable ? 1.0 : 0.3,
      child: InkWell(
        onTap: isAvailable ? onTap : null,
        borderRadius: BorderRadius.circular(30),
        child: Column(
          children: [
            CircleAvatar(
              backgroundColor: Colors.blue[50],
              child: Icon(icon, color: Colors.blue[600]),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }


  // 辅助方法：构建信息行
  Widget _buildInfoSection(IconData icon, String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.grey[600], size: 20),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                const SizedBox(height: 4),
                Text(content, style: const TextStyle(fontSize: 15, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildOpeningHours(List<dynamic> weekdayDescriptions) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.access_time_filled, color: Colors.grey[600], size: 20),
          const SizedBox(width: 15),
          Expanded(
            child: Theme(
              // 去掉 ExpansionTile 默认的边框线
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: const Text(
                  "Opening Hours",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 10),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: weekdayDescriptions.map((desc) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      desc.toString(),
                      style: TextStyle(color: Colors.grey[700], fontSize: 14),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildReviewItem(Map<String, dynamic> review) {
    final authorName = review['authorAttribution']?['displayName'] ?? '匿名用户';
    final photoUrl = review['authorAttribution']?['photoUri'];
    final rating = review['rating'] ?? 0;
    final text = review['text']?['text'] ?? '';
    final timeDesc = review['relativePublishTimeDescription'] ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 用户头像
              CircleAvatar(
                radius: 20,
                backgroundColor: Colors.blue[100],
                backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
                child: photoUrl == null 
                    ? Text(authorName[0], style: const TextStyle(color: Colors.blue)) 
                    : null,
              ),
              const SizedBox(width: 12),
              // 名字和时间
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      authorName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    Text(
                      timeDesc,
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
              // 评分星星
              Row(
                children: List.generate(5, (index) {
                  return Icon(
                    Icons.star,
                    size: 14,
                    color: index < rating ? Colors.orange : Colors.grey[300],
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 评论内容
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.black87,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }


}