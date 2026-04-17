import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';
import '../../models/postModel.dart';
import '../../services/post_service.dart';
import 'videoPlayer.dart';

class postWidget extends StatefulWidget {
  const postWidget({super.key});

  @override
  State<postWidget> createState() => _postWidgetState();
}

class _postWidgetState extends State<postWidget> {
  final PostService _postService = PostService();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // =====================================================
  // Build
  // =====================================================
  @override
  Widget build(BuildContext context) {
    final String? currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return const SizedBox(
        height: 300,
        child: Center(child: Text('Please log in first')),
      );
    }

    return StreamBuilder<List<Post>>(
      stream: _postService.getUserPosts(currentUserId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFD35D3E)),
          );
        }
        if (snapshot.hasError) {
          return Center(child: Text('Load failed: ${snapshot.error}'));
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.post_add, size: 60, color: Colors.grey[400]),
                const SizedBox(height: 12),
                Text('No posts yet!',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14)),
              ],
            ),
          );
        }

        // ── 按类型分组 ──
        final allPosts = snapshot.data!;
        final mediaPosts =
            allPosts.where((p) => p.images.isNotEmpty || p.videoPaths.isNotEmpty).toList();
        final textPosts =
            allPosts.where((p) => p.images.isEmpty && p.videoPaths.isEmpty).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
         
            if (mediaPosts.isNotEmpty) ...[
              _buildSectionHeader(
                icon: Icons.photo_library_outlined,
                label: 'Photos & Videos',
                count: mediaPosts.length,
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: mediaPosts.length,
                itemBuilder: (context, index) =>
                    _buildMediaCard(mediaPosts[index]),
              ),
            ],

            // ── 纯文字帖子列表 ──
            if (textPosts.isNotEmpty) ...[
              _buildSectionHeader(
                icon: Icons.text_fields,
                label: 'Text Posts',
                count: textPosts.length,
              ),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: textPosts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) =>
                    _buildTextCard(textPosts[index]),
              ),
            ],

            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  // =====================================================
  // Section header
  // =====================================================
  Widget _buildSectionHeader({
    required IconData icon,
    required String label,
    required int count,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      child: Row(children: [
        Icon(icon, size: 16, color: const Color(0xFFD35D3E)),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.black54)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFD35D3E).withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('$count',
              style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFFD35D3E),
                  fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }

  // Media card (图片 / 视频)
  Widget _buildMediaCard(Post post) {
 
    final bool hasImage = post.images.isNotEmpty;
    final bool hasVideo = post.videoPaths.isNotEmpty;
    final int totalMedia = post.images.length + post.videoPaths.length;

    return GestureDetector(
      onTap: () => _showPostDetail(post),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(fit: StackFit.expand, children: [
          // ── 封面 ──
          if (hasImage)
            Image.file(
              File(post.images.first),
              fit: BoxFit.cover,
              errorBuilder: (c, e, s) => _greyPlaceholder(),
            )
          else
              LocalVideoPlayer(path: post.videoPaths.first), 

          // ── 底部渐变 + 标题 ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.72),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    post.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.favorite,
                        color: Colors.white, size: 11),
                    const SizedBox(width: 3),
                    Text('${post.likes}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10)),
                    const SizedBox(width: 10),
                    const Icon(Icons.comment,
                        color: Colors.white, size: 11),
                    const SizedBox(width: 3),
                    Text('${post.comments}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10)),
                  ]),
                ],
              ),
            ),
          ),

  
          if (post.visibility != 'public')
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: post.visibility == 'private'
                      ? Colors.red.withOpacity(0.8)
                      : Colors.orange.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    post.visibility == 'private'
                        ? Icons.lock
                        : Icons.people,
                    color: Colors.white,
                    size: 11,
                  ),
                  const SizedBox(width: 3),
                  Text(post.visibility,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
            ),

          // ── 多媒体数量角标 ──
          if (totalMedia > 1)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    hasVideo
                        ? Icons.video_collection
                        : Icons.collections,
                    color: Colors.white,
                    size: 11,
                  ),
                  const SizedBox(width: 3),
                  Text('$totalMedia',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }


  // Text card (纯文字帖子)
  Widget _buildTextCard(Post post) {
    return GestureDetector(
      onTap: () => _showPostDetail(post),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
    
            Row(children: [
              Expanded(
                child: Text(
                  post.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                post.visibility == 'public'
                    ? Icons.public
                    : post.visibility == 'friends'
                        ? Icons.people
                        : Icons.lock,
                size: 14,
                color: Colors.grey[400],
              ),
            ]),

            const SizedBox(height: 6),

    
            Text(
              post.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  height: 1.5),
            ),

            if (post.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: post.tags
                    .take(3)
                    .map((tag) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD35D3E).withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('#$tag',
                              style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFFD35D3E))),
                        ))
                    .toList(),
              ),
            ],

            const SizedBox(height: 10),

            Row(children: [
              Icon(Icons.favorite_border,
                  size: 13, color: Colors.grey[500]),
              const SizedBox(width: 3),
              Text('${post.likes}',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey[500])),
              const SizedBox(width: 10),
              Icon(Icons.chat_bubble_outline,
                  size: 13, color: Colors.grey[500]),
              const SizedBox(width: 3),
              Text('${post.comments}',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey[500])),
              const Spacer(),
              Text(
                _formatDate(post.createdAt),
                style:
                    TextStyle(fontSize: 11, color: Colors.grey[400]),
              ),
            ]),
          ],
        ),
      ),
    );
  }


  // Placeholder widgets
  Widget _greyPlaceholder() => Container(
        color: Colors.grey[300],
        child: const Icon(Icons.broken_image,
            color: Colors.grey, size: 40),
      );

  Widget _videoThumbPlaceholder() => Container(
        color: Colors.grey[850],
        child: const Center(
          child: Icon(Icons.play_circle_fill,
              color: Colors.white70, size: 44),
        ),
      );

  // Post detail bottom sheet
  void _showPostDetail(Post post) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.82,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
          // 拖动条
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2)),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
         
                  Text(post.title,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),

        
                  Row(children: [
                    Icon(
                      post.visibility == 'public'
                          ? Icons.public
                          : post.visibility == 'friends'
                              ? Icons.people
                              : Icons.lock,
                      size: 15,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    Text(post.visibility,
                        style: TextStyle(color: Colors.grey[600])),
                    const SizedBox(width: 16),
                    Text(_formatDate(post.createdAt),
                        style: TextStyle(color: Colors.grey[600])),
                    if (post.city != null && post.city!.isNotEmpty) ...[
                      const SizedBox(width: 16),
                      const Icon(Icons.location_on,
                          size: 15, color: Color(0xFFD35D3E)),
                      const SizedBox(width: 2),
                      Text(post.city!,
                          style: const TextStyle(
                              color: Color(0xFFD35D3E), fontSize: 13)),
                    ],
                  ]),

                  const SizedBox(height: 20),

                  if (post.images.isNotEmpty)
                    SizedBox(
                      height: 260,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: post.images.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: 8),
                        itemBuilder: (context, index) => ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(post.images[index]),
                            width: 220,
                            fit: BoxFit.cover,
                            errorBuilder: (c, e, s) => Container(
                                width: 220,
                                color: Colors.grey[300],
                                child: const Icon(Icons.broken_image,
                                    color: Colors.grey)),
                          ),
                        ),
                      ),
                    ),

                  if (post.videoPaths.isNotEmpty) ...[
                    if (post.images.isNotEmpty) const SizedBox(height: 10),
                    SizedBox(
                      height: 220,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: post.videoPaths.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) => ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: 280,
                            height: 220,
                            child: LocalVideoPlayer(path: post.videoPaths[index]), // 改这里
                          ),
                        ),
                      ),
                    ),
                  ],

                  if (post.images.isNotEmpty || post.videoPaths.isNotEmpty)
                    const SizedBox(height: 20),

                  Text(post.content,
                      style: const TextStyle(fontSize: 15, height: 1.6)),

                  if (post.tags.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: post.tags
                          .map((tag) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFD35D3E)
                                      .withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text('#$tag',
                                    style: const TextStyle(
                                        color: Color(0xFFD35D3E),
                                        fontSize: 12)),
                              ))
                          .toList(),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // ── 统计 ──
                  Row(children: [
                    _buildStatItem(
                        Icons.favorite, '${post.likes}', 'Likes'),
                    const SizedBox(width: 24),
                    _buildStatItem(
                        Icons.comment, '${post.comments}', 'Comments'),
                    const SizedBox(width: 24),
                    _buildStatItem(
                        Icons.share, '${post.shares}', 'Shares'),
                  ]),
                ],
              ),
            ),
          ),

          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -4)),
              ],
            ),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Edit feature under development...')),
                    );
                  },
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _confirmDelete(context, post),
                  icon: const Icon(Icons.delete, size: 18),
                  label: const Text('Delete'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }


  // Helpers
  Widget _buildStatItem(IconData icon, String count, String label) {
    return Column(children: [
      Row(children: [
        Icon(icon, size: 18, color: Colors.grey[700]),
        const SizedBox(width: 4),
        Text(count,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold)),
      ]),
      Text(label,
          style: TextStyle(color: Colors.grey[600], fontSize: 11)),
    ]);
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  void _confirmDelete(BuildContext context, Post post) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Post'),
        content: const Text('Are you sure you want to delete this post?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              try {
                await _postService.deletePost(post.id!);
                Navigator.pop(context); // 关闭 dialog
                Navigator.pop(context); // 关闭 detail sheet
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Post deleted successfully'),
                        backgroundColor: Colors.green),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to delete: $e')),
                  );
                }
              }
            },
            child: const Text('Delete',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}