// ===== postDetailPage.dart =====
// 放在 lib/modules/interaction/ 目录下

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import '../../models/postModel.dart';
import '../../services/like_service.dart';
import '../../services/post_service.dart';
import '../../services/userPreference_service.dart';
import '../profile/profile.dart';
import 'editPost.dart';

class PostDetailPage extends StatefulWidget {
  final Post post;
  const PostDetailPage({super.key, required this.post});

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  final LikeService _likeService = LikeService();
  final PostService _postService = PostService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  late Post _post;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
  }

  bool get _isOwner => _post.userId == _auth.currentUser?.uid;

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _formatTime(DateTime? dateTime) {
    if (dateTime == null) return 'Just now';
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} mins ago';
    if (diff.inHours < 24) return '${diff.inHours} hour${diff.inHours > 1 ? 's' : ''} ago';
    if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago';
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
  }

  Color _getUserColor(String userId) {
    final colors = [Colors.blueAccent, Colors.greenAccent, Colors.purpleAccent, Colors.orangeAccent, Colors.pinkAccent, Colors.tealAccent, Colors.indigoAccent, Colors.cyanAccent];
    return colors[userId.hashCode.abs() % colors.length];
  }

  Widget _buildUserAvatar(String userName, String? userPhoto, String userId, bool isAnonymous) {
    if (isAnonymous) return CircleAvatar(radius: 20, backgroundColor: _getUserColor(userId), child: const Icon(Icons.person_outline, color: Colors.white, size: 22));
    if (userPhoto != null && userPhoto.isNotEmpty) {
      if (userPhoto.startsWith('data:image')) {
        try {
          Uint8List bytes = base64Decode(userPhoto.split(',')[1]);
          return CircleAvatar(radius: 20, backgroundImage: MemoryImage(bytes), backgroundColor: Colors.transparent);
        } catch (_) {}
      } else if (userPhoto.startsWith('http')) {
        return CircleAvatar(radius: 20, backgroundImage: NetworkImage(userPhoto), backgroundColor: Colors.transparent);
      }
    }
    return CircleAvatar(radius: 20, backgroundColor: _getUserColor(userId),
        child: Text(userName.isNotEmpty ? userName[0].toUpperCase() : '?',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)));
  }

  void _handleDelete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Post'),
        content: const Text('Are you sure you want to delete this post?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _postService.deletePost(_post.id!);
                if (mounted) Navigator.pop(context); // 返回上一页
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Post', style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          if (_isOwner)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, color: Colors.black87),
              onSelected: (value) {
                if (value == 'edit') {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => EditPostPage(post: _post)));
                }
                if (value == 'delete') _handleDelete();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit_outlined, size: 20), SizedBox(width: 12), Text('Edit')])),
                const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 20, color: Colors.red), SizedBox(width: 12), Text('Delete', style: TextStyle(color: Colors.red))])),
              ],
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── User info ──
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: StreamBuilder<DocumentSnapshot>(
              stream: _firestore.collection('users').doc(_post.userId).snapshots(),
              builder: (context, snapshot) {
                String userName   = _post.userName;
                String? userPhoto = _post.userPhoto;
                if (snapshot.hasData && snapshot.data!.exists) {
                  final data = snapshot.data!.data() as Map<String, dynamic>;
                  userName  = data['username']        ?? userName;
                  userPhoto = data['profileImageUrl'] ?? userPhoto;
                }
                return Row(children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5)),
                    child: _buildUserAvatar(userName, userPhoto, _post.userId, _post.isAnonymous),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_post.isAnonymous ? 'Anonymous User' : userName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text("${_formatTime(_post.createdAt)} · GoTrip",
                        style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                  ])),
                ]);
              },
            ),
          ),

          // ── Media ──
          if (_post.images.isNotEmpty || _post.videoPaths.isNotEmpty)
            _buildMediaSection(),

          // ── Content ──
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // Location
              if ((_post.city != null && _post.city!.isNotEmpty) ||
                  (_post.location != null && _post.location!.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(children: [
                    const Icon(Icons.location_on, size: 14, color: Color(0xFFD35D3E)),
                    const SizedBox(width: 4),
                    Text(
                      [
                        if (_post.city != null && _post.city!.isNotEmpty) _post.city!,
                        if (_post.location != null && _post.location!.isNotEmpty && _post.location != _post.city) _post.location!,
                      ].join(' · '),
                      style: const TextStyle(fontSize: 13, color: Color(0xFFD35D3E), fontWeight: FontWeight.w500),
                    ),
                  ]),
                ),

              // Title
              Text(_post.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87, height: 1.3)),
              const SizedBox(height: 12),

              // Content — 完整显示，不截断
              Text(_post.content, style: TextStyle(fontSize: 15, color: Colors.grey[800], height: 1.6)),
              const SizedBox(height: 16),

              // Rating
              if (_post.rating > 0)
                Row(children: [
                  ...List.generate(5, (index) => Icon(
                    index < _post.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 20,
                    color: index < _post.rating ? Colors.orange : Colors.grey[300],
                  )),
                  const SizedBox(width: 8),
                  Text('${_post.rating}/5', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                ]),

              if (_post.rating > 0) const SizedBox(height: 16),

              // Tags
              if (_post.tags.isNotEmpty) ...[
                Wrap(
                  spacing: 8, runSpacing: 8,
                  children: _post.tags.map((tag) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: const Color(0xFFD35D3E).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16)),
                    child: Text('#$tag', style: const TextStyle(color: Color(0xFFD35D3E), fontSize: 13, fontWeight: FontWeight.w500)),
                  )).toList(),
                ),
                const SizedBox(height: 16),
              ],
            ]),
          ),

          const SizedBox(height: 8),

          // ── Like & Comment ──
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              // Like button
              StreamBuilder<bool>(
                stream: _likeService.likeStatusStream(_post.id!),
                initialData: false,
                builder: (context, snapshot) {
                  final isLiked = snapshot.data ?? false;
                  return StreamBuilder<int>(
                    stream: _likeService.likeCountStream(_post.id!),
                    initialData: _post.likes,
                    builder: (context, countSnapshot) {
                      final likeCount = countSnapshot.data ?? _post.likes;
                      return GestureDetector(
                        onTap: () async {
                          final liked = await _likeService.toggleLike(_post.id!);
                          UserPreferenceService.instance.updateFromLike(
                            postTags: _post.tags,
                            postTopic: _post.topic,
                            isLiking: liked,
                          );
                        },
                        child: Row(children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                              key: ValueKey(isLiked),
                              size: 24,
                              color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            likeCount > 0 ? '$likeCount' : 'Like',
                            style: TextStyle(
                              fontSize: 15,
                              color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700],
                              fontWeight: isLiked ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ]),
                      );
                    },
                  );
                },
              ),

              const SizedBox(width: 24),

              // Comment button
              GestureDetector(
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Comment feature under development...'))),
                child: Row(children: [
                  Icon(Icons.chat_bubble_outline, size: 24, color: Colors.grey[700]),
                  const SizedBox(width: 8),
                  Text(
                    _post.comments > 0 ? '${_post.comments}' : 'Comment',
                    style: TextStyle(fontSize: 15, color: Colors.grey[700]),
                  ),
                ]),
              ),
            ]),
          ),

          const SizedBox(height: 32),
        ]),
      ),
    );
  }

  // ── Media Section ──────────────────────────────────────────────────────────

  Widget _buildMediaSection() {
    final images = _post.images;
    final videos = _post.videoPaths;

    final List<(String path, bool isVideo)> allMedia = [
      ...images.map((p) => (p, false)),
      ...videos.map((p) => (p, true)),
    ];

    if (allMedia.length == 1) {
      return _buildSingleMedia(allMedia[0].$1, allMedia[0].$2);
    }

    // Multiple media — horizontal scrollable
    return SizedBox(
      height: 280,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: allMedia.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final (path, isVideo) = allMedia[index];
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 260,
              child: isVideo
                  ? LocalVideoPlayer(path: path)
                  : Image.file(File(path), fit: BoxFit.cover,
                      errorBuilder: (c, e, s) => Container(color: Colors.grey[300], child: const Icon(Icons.broken_image, color: Colors.grey, size: 40))),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSingleMedia(String path, bool isVideo) {
    return isVideo
        ? SizedBox(height: 300, child: LocalVideoPlayer(path: path))
        : Image.file(
            File(path),
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (c, e, s) => Container(
              height: 200, color: Colors.grey[300],
              child: const Icon(Icons.broken_image, color: Colors.grey, size: 40),
            ),
          );
  }
}