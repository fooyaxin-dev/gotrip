import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class PlaceDetailPage extends StatefulWidget {
  final String placeId;

  const PlaceDetailPage({super.key, required this.placeId});

  @override
  State<PlaceDetailPage> createState() => _PlaceDetailPageState();
}

class _PlaceDetailPageState extends State<PlaceDetailPage> {
  Map<String, dynamic>? placeDetail;
  bool loading = true;
  String? error;

  // TODO: 换成你自己的 API KEY
  static const String apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';

  @override
  void initState() {
    super.initState();
    _fetchPlaceDetails();
  }

  Future<void> _fetchPlaceDetails() async {
    try {
      final url = Uri.parse(
        'https://places.googleapis.com/v1/places/${widget.placeId}',
      );

      final response = await http.get(
        url,
        headers: {
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
              'displayName,formattedAddress,rating,photos,regularOpeningHours,websiteUri,internationalPhoneNumber,reviews',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data = json.decode(response.body);

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

    // 构造图片 URL (如果存在)
    String? photoUrl;
    if (photos != null && photos.isNotEmpty) {
      final photoName = photos[0]['name'];
      photoUrl = 'https://places.googleapis.com/v1/$photoName/media?key=$apiKey&maxWidthPx=800';
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 顶部大图封面
          Stack(
            children: [
              Container(
                height: 250,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  image: photoUrl != null
                      ? DecorationImage(image: NetworkImage(photoUrl), fit: BoxFit.cover)
                      : null,
                ),
                child: photoUrl == null ? const Icon(Icons.image, size: 50, color: Colors.grey) : null,
              ),
              // 顶部渐变遮罩，让返回键更清晰
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black.withOpacity(0.3), Colors.transparent, Colors.transparent],
                    ),
                  ),
                ),
              ),
            ],
          ),

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
                      _buildActionButton(Icons.directions, "路线", true),
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

  // 辅助方法：构建功能按钮
  Widget _buildActionButton(IconData icon, String label, bool isAvailable) {
    return Opacity(
      opacity: isAvailable ? 1.0 : 0.3,
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
