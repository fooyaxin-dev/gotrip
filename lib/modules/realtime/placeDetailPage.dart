import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/placesAPI_service.dart';
import 'favouriteButton.dart'; // 👈 新增导入

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
  int _currentPhotoIndex = 0;

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
    final rating = (placeDetail?['rating'] as num?)?.toDouble();
    final phone = placeDetail?['internationalPhoneNumber'];
    final website = placeDetail?['websiteUri'];
    final isOpen = placeDetail?['regularOpeningHours']?['openNow'];
    final photos = placeDetail?['photos'] as List?;

    // 获取第一张图片 URL（用于存收藏）
    String? firstPhotoUrl;
    if (photos != null && photos.isNotEmpty) {
      firstPhotoUrl = PlacesApiService.buildPhotoUrl(
        photos[0]['name'],
        maxWidth: 400,
      );
    }

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
                // 2. 标题与收藏按钮 + 评分
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Row(
                      children: [
                        // ✅ 替换旧的 _toggleFavourite，改用 FavouriteButton
                        FavouriteButton(
                          placeId: widget.placeId,
                          name: name,
                          address: address,
                          rating: rating,
                          photoUrl: firstPhotoUrl,
                          lat: widget.lat,
                          lng: widget.lng,
                          iconSize: 26,
                          activeColor: Colors.red,
                          inactiveColor: Colors.grey,
                          showBackground: false, // DetailPage 用普通 IconButton 模式
                        ),
                        if (rating != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange[50],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.star,
                                    color: Colors.orange, size: 18),
                                const SizedBox(width: 4),
                                Text(
                                  rating.toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.orange),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // 3. 营业状态标签
                if (isOpen != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
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

                // 4. 快速操作栏
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildActionButton(Icons.phone, "电话", phone != null),
                      _buildActionButton(Icons.public, "网站", website != null),
                      _buildActionButton(
                        Icons.directions,
                        "路线",
                        widget.lat != null && widget.lng != null,
                        onTap: () {
                          if (widget.lat != null && widget.lng != null) {
                            Navigator.pop(context, {
                              'action': 'navigate',
                              'lat': widget.lat,
                              'lng': widget.lng,
                              'name': name,
                              'id': widget.placeId,
                              'rating': rating,
                              'address': address,
                              'photoUrl': firstPhotoUrl,
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

                // 5. 详细信息
                _buildInfoSection(Icons.location_on, "地址", address),
                if (placeDetail?['regularOpeningHours']
                        ?['weekdayDescriptions'] !=
                    null)
                  _buildOpeningHours(placeDetail!['regularOpeningHours']
                      ['weekdayDescriptions']),
                if (phone != null)
                  _buildInfoSection(Icons.call, "联系电话", phone),
                if (website != null)
                  _buildInfoSection(Icons.language, "官方网站", website),

                // 6. 用户评价
                const Divider(),
                const SizedBox(height: 10),
                const Text(
                  "用户评价",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                if (placeDetail?['reviews'] != null)
                  ...((placeDetail!['reviews'] as List)
                      .map((review) => _buildReviewItem(review)))
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text("暂无评价",
                        style: TextStyle(color: Colors.grey)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              itemCount: photoUrls.length,
              physics: const PageScrollPhysics(),
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

        if (photoUrls.length > 1)
          Positioned(
            top: 15,
            right: 15,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                '${_currentPhotoIndex + 1}/${photoUrls.length}',
                style:
                    const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  void _showFullScreenPhoto(
      BuildContext context, List<String> photoUrls, int initialIndex) {
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
            Text(label,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

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
                Text(title,
                    style:
                        TextStyle(color: Colors.grey[500], fontSize: 12)),
                const SizedBox(height: 4),
                Text(content,
                    style:
                        const TextStyle(fontSize: 15, height: 1.4)),
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
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
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
                      style:
                          TextStyle(color: Colors.grey[700], fontSize: 14),
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
    final authorName =
        review['authorAttribution']?['displayName'] ?? '匿名用户';
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
              CircleAvatar(
                radius: 20,
                backgroundColor: Colors.blue[100],
                backgroundImage:
                    photoUrl != null ? NetworkImage(photoUrl) : null,
                child: photoUrl == null
                    ? Text(authorName[0],
                        style: const TextStyle(color: Colors.blue))
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      authorName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    Text(
                      timeDesc,
                      style: TextStyle(
                          color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
              Row(
                children: List.generate(5, (index) {
                  return Icon(
                    Icons.star,
                    size: 14,
                    color: index < rating
                        ? Colors.orange
                        : Colors.grey[300],
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
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