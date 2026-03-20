// ===== interactionPage.dart =====

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'addPost.dart';
import 'postModel.dart';
import '../../services/post_service.dart';
import '../../services/like_service.dart';

class InteractionPage extends StatefulWidget {
  const InteractionPage({super.key});

  @override
  State<InteractionPage> createState() => _InteractionPageState();
}

class _InteractionPageState extends State<InteractionPage> {
  final PostService _postService = PostService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final LikeService _likeService = LikeService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // 搜索 & 城市过滤
  String? _selectedCity;             // null = 显示全部
  List<String> _availableCities = [];
  bool _loadingCities = true;
  final TextEditingController _searchController = TextEditingController();
  bool _showSuggestions = false;
  List<String> _filteredCities = [];

  @override
  void initState() {
    super.initState();
    _loadCities();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ─── 从 Firestore 读取所有出现过的城市 ────────────────────────────────────

  Future<void> _loadCities() async {
    try {
      final snapshot = await _firestore
          .collection('posts')
          .where('visibility', isEqualTo: '公开')
          .get();

      final citySet = <String>{};
      for (var doc in snapshot.docs) {
        final city = doc.data()['city'];
        if (city != null && city.toString().isNotEmpty) {
          citySet.add(city.toString());
        }
      }

      final sorted = citySet.toList()..sort();
      setState(() {
        _availableCities = sorted;
        _filteredCities = sorted;
        _loadingCities = false;
      });
    } catch (e) {
      setState(() => _loadingCities = false);
    }
  }

  // ─── 搜索逻辑 ──────────────────────────────────────────────────────────────

  void _onSearchChanged(String query) {
    setState(() {
      _showSuggestions = query.isNotEmpty;
      _filteredCities = _availableCities
          .where((c) => c.toLowerCase().contains(query.toLowerCase()))
          .toList();
    });
  }

  void _selectCity(String city) {
    setState(() {
      _selectedCity = city;
      _searchController.text = city;
      _showSuggestions = false;
    });
    FocusScope.of(context).unfocus();
  }

  void _clearCity() {
    setState(() {
      _selectedCity = null;
      _searchController.clear();
      _showSuggestions = false;
      _filteredCities = _availableCities;
    });
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
        setState(() => _showSuggestions = false);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8F9FA),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Followed",
                  style: TextStyle(color: Colors.grey, fontSize: 15)),
              const SizedBox(width: 20),
              Column(children: [
                const Text("Post",
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Container(
                    height: 3,
                    width: 20,
                    decoration: BoxDecoration(
                        color: Colors.orange,
                        borderRadius: BorderRadius.circular(2))),
              ]),
              const SizedBox(width: 20),
              const Text("Nearby",
                  style: TextStyle(color: Colors.grey, fontSize: 15)),
            ],
          ),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.add_circle_outline,
                  color: Colors.black, size: 28),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PostingPage())),
            ),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: _buildSearchBar(),
          ),
        ),
        body: Stack(
          children: [
            StreamBuilder<List<Post>>(
              stream: _selectedCity != null
                  ? _postService.getPostsByCity(_selectedCity!)
                  : _postService.getPublicPosts(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFFD35D3E)));
                }
                if (snapshot.hasError) {
                  return Center(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                        const Icon(Icons.error_outline,
                            size: 64, color: Colors.red),
                        const SizedBox(height: 16),
                        Text('加载失败: ${snapshot.error}',
                            style: const TextStyle(color: Colors.red)),
                        const SizedBox(height: 16),
                        ElevatedButton(
                            onPressed: () => setState(() {}),
                            child: const Text('重试')),
                      ]));
                }
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return _buildEmptyState();
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    await _loadCities();
                    setState(() {});
                  },
                  color: const Color(0xFFD35D3E),
                  child: ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: snapshot.data!.length,
                    padding: const EdgeInsets.only(top: 10, bottom: 90),
                    itemBuilder: (context, index) =>
                        _buildPostCard(snapshot.data![index]),
                  ),
                );
              },
            ),
            if (_showSuggestions)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildSuggestionDropdown(),
              ),
          ],
        ),
      ),
    );
  }

  // ─── 搜索栏 ────────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        onTap: () {
          setState(() {
            _filteredCities = _availableCities;
            _showSuggestions = _availableCities.isNotEmpty;
          });
        },
        decoration: InputDecoration(
          hintText: _loadingCities
              ? '正在加载...'
              : _selectedCity != null
                  ? _selectedCity!
                  : '搜索你想去的城市',
          hintStyle: TextStyle(
            color: _selectedCity != null ? Colors.black87 : Colors.grey[400],
            fontSize: 13,
          ),
          prefixIcon:
              const Icon(Icons.search, color: Color(0xFFD35D3E), size: 20),
          suffixIcon: _selectedCity != null || _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                  onPressed: _clearCity,
                )
              : null,
          filled: true,
          fillColor: Colors.grey[100],
          contentPadding:
              const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide:
                const BorderSide(color: Color(0xFFD35D3E), width: 1.5),
          ),
        ),
      ),
    );
  }

  // ─── 搜索建议下拉 ──────────────────────────────────────────────────────────

  Widget _buildSuggestionDropdown() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: _filteredCities.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Row(children: [
                Icon(Icons.search_off, color: Colors.grey),
                SizedBox(width: 12),
                Text('没有找到相关城市',
                    style: TextStyle(color: Colors.grey)),
              ]),
            )
          : ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount:
                  _filteredCities.length > 6 ? 6 : _filteredCities.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 48),
              itemBuilder: (context, index) {
                final city = _filteredCities[index];
                final isSelected = city == _selectedCity;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.location_city,
                    color: isSelected
                        ? const Color(0xFFD35D3E)
                        : Colors.grey[500],
                    size: 20,
                  ),
                  title: Text(
                    city,
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? const Color(0xFFD35D3E)
                          : Colors.black87,
                      fontSize: 14,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check,
                          color: Color(0xFFD35D3E), size: 16)
                      : null,
                  onTap: () => _selectCity(city),
                );
              },
            ),
    );
  }

  // ─── 空状态 ────────────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _selectedCity != null ? Icons.location_off : Icons.post_add,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _selectedCity != null ? '$_selectedCity 暂无帖子' : '还没有帖子',
            style: TextStyle(
                color: Colors.grey[600],
                fontSize: 18,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _selectedCity != null
                ? '成为第一个分享 $_selectedCity 旅行体验的人！'
                : '点击右上角 + 发布第一个帖子吧！',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const PostingPage())),
            icon: const Icon(Icons.add),
            label: const Text('发布帖子'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD35D3E),
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Post Card ─────────────────────────────────────────────────────────────

  Widget _buildPostCard(Post post) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0.5,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          _buildUserInfoWithStream(post),
          const SizedBox(height: 12),
          if ((post.city != null && post.city!.isNotEmpty) ||
              (post.location != null && post.location!.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const Icon(Icons.location_on,
                    size: 13, color: Color(0xFFD35D3E)),
                const SizedBox(width: 3),
                Text(
                  [
                    if (post.city != null && post.city!.isNotEmpty)
                      post.city!,
                    if (post.location != null &&
                        post.location!.isNotEmpty &&
                        post.location != post.city)
                      post.location!,
                  ].join(' · '),
                  style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFD35D3E),
                      fontWeight: FontWeight.w500),
                ),
              ]),
            ),
          Text(post.title,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87)),
          const SizedBox(height: 8),
          Text(post.content,
              style: TextStyle(
                  fontSize: 14, color: Colors.grey[800], height: 1.4),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          _buildImageGrid(post.images),
          if (post.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: post.tags
                  .map((tag) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                            color:
                                const Color(0xFFD35D3E).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16)),
                        child: Text('#$tag',
                            style: const TextStyle(
                                color: Color(0xFFD35D3E),
                                fontSize: 12,
                                fontWeight: FontWeight.w500)),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1, thickness: 0.5),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildSocialBtn(
                  Icons.share_outlined,
                  post.shares > 0 ? '${post.shares}' : '转发',
                  () => _handleShare(post),
                  false),
              _buildSocialBtn(
                  Icons.chat_bubble_outline,
                  post.comments > 0 ? '${post.comments}' : '评论',
                  () => _handleComment(post),
                  false),
              StreamBuilder<bool>(
                stream: _likeService.likeStatusStream(post.id!),
                initialData: false,
                builder: (context, snapshot) =>
                    _buildLikeButton(post, snapshot.data ?? false),
              ),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _buildUserInfoWithStream(Post post) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('users').doc(post.userId).snapshots(),
      builder: (context, snapshot) {
        String userName = post.userName;
        String? userPhoto = post.userPhoto;
        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>;
          userName = data['username'] ?? userName;
          userPhoto = data['profileImageUrl'] ?? userPhoto;
        }
        return Row(children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.orange.withOpacity(0.5), width: 1.5)),
            child: _buildUserAvatar(
                userName, userPhoto, post.userId, post.isAnonymous),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(post.isAnonymous ? '匿名用户' : userName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 2),
                Text("${_formatTime(post.createdAt)} · GoTrip 极速版",
                    style:
                        TextStyle(color: Colors.grey[500], fontSize: 11)),
              ])),
          PopupMenuButton(
            icon: Icon(Icons.more_horiz, color: Colors.grey[600]),
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'report',
                  child: Row(children: [
                    Icon(Icons.flag_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('举报')
                  ]))
            ],
          ),
        ]);
      },
    );
  }

  Widget _buildImageGrid(List<String> images) {
    if (images.isEmpty) return const SizedBox.shrink();
    if (images.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(File(images[0]),
            width: double.infinity,
            height: 250,
            fit: BoxFit.cover,
            errorBuilder: (c, e, s) => Container(
                height: 250,
                color: Colors.grey[300],
                child: const Center(
                    child: Icon(Icons.broken_image,
                        size: 50, color: Colors.grey)))),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: images.length == 2 ? 2 : 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8),
      itemCount: images.length > 9 ? 9 : images.length,
      itemBuilder: (context, index) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(fit: StackFit.expand, children: [
          Image.file(File(images[index]),
              fit: BoxFit.cover,
              errorBuilder: (c, e, s) => Container(
                  color: Colors.grey[300],
                  child:
                      const Icon(Icons.broken_image, color: Colors.grey))),
          if (images.length > 9 && index == 8)
            Container(
                color: Colors.black.withOpacity(0.6),
                child: Center(
                    child: Text('+${images.length - 9}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold)))),
        ]),
      ),
    );
  }

  Widget _buildLikeButton(Post post, bool isLiked) {
    return StreamBuilder<int>(
      stream: _likeService.likeCountStream(post.id!),
      initialData: post.likes,
      builder: (context, snapshot) {
        int likeCount = snapshot.data ?? post.likes;
        return InkWell(
          onTap: () => _handleLike(post),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Icon(isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                  size: 20,
                  color:
                      isLiked ? const Color(0xFFD35D3E) : Colors.grey[700]),
              const SizedBox(width: 6),
              Text(likeCount > 0 ? '$likeCount' : '赞',
                  style: TextStyle(
                      color: isLiked
                          ? const Color(0xFFD35D3E)
                          : Colors.grey[700],
                      fontSize: 13,
                      fontWeight: isLiked
                          ? FontWeight.bold
                          : FontWeight.normal)),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildSocialBtn(
      IconData icon, String label, VoidCallback onTap, bool isActive) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Icon(icon, size: 20, color: Colors.grey[700]),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(color: Colors.grey[700], fontSize: 13)),
        ]),
      ),
    );
  }

  void _handleLike(Post post) async {
    try {
      bool isLiked = await _likeService.toggleLike(post.id!);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isLiked ? '已点赞' : '已取消点赞'),
          duration: const Duration(milliseconds: 500),
          backgroundColor:
              isLiked ? const Color(0xFFD35D3E) : Colors.grey));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('操作失败: $e')));
    }
  }

  void _handleComment(Post post) => ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('评论功能开发中...')));

  void _handleShare(Post post) async {
    try {
      await _postService.incrementShareCount(post.id!);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已转发'),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFFD35D3E)));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('转发失败: $e')));
    }
  }

  Widget _buildUserAvatar(String userName, String? userPhoto,
      String userId, bool isAnonymous) {
    if (isAnonymous)
      return CircleAvatar(
          radius: 20,
          backgroundColor: _getUserColor(userId),
          child: const Icon(Icons.person_outline,
              color: Colors.white, size: 22));
    if (userPhoto != null && userPhoto.isNotEmpty) {
      if (userPhoto.startsWith('data:image')) {
        try {
          Uint8List bytes = base64Decode(userPhoto.split(',')[1]);
          return CircleAvatar(
              radius: 20,
              backgroundImage: MemoryImage(bytes),
              backgroundColor: Colors.transparent);
        } catch (_) {}
      } else if (userPhoto.startsWith('http')) {
        return CircleAvatar(
            radius: 20,
            backgroundImage: NetworkImage(userPhoto),
            backgroundColor: Colors.transparent);
      }
    }
    return CircleAvatar(
        radius: 20,
        backgroundColor: _getUserColor(userId),
        child: Text(
            userName.isNotEmpty ? userName[0].toUpperCase() : '?',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold)));
  }

  String _formatTime(DateTime? dateTime) {
    if (dateTime == null) return '刚刚';
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} mins ago';
    if (diff.inHours < 24)
      return '${diff.inHours} hour${diff.inHours > 1 ? 's' : ''} ago';
    if (diff.inDays < 7)
      return '${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago';
    return '${dateTime.month}月${dateTime.day}日';
  }

  Color _getUserColor(String userId) {
    final colors = [
      Colors.blueAccent,
      Colors.greenAccent,
      Colors.purpleAccent,
      Colors.orangeAccent,
      Colors.pinkAccent,
      Colors.tealAccent,
      Colors.indigoAccent,
      Colors.cyanAccent
    ];
    return colors[userId.hashCode.abs() % colors.length];
  }
}