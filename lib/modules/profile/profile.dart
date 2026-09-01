import 'dart:ui';
import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../models/userModel.dart';
import '../../models/postModel.dart';
import '../../services/user_service.dart';
import '../../services/post_service.dart';
import '../../services/history_service.dart';
import '../../services/achievement_service.dart';
import '../interaction/editPost.dart';
import 'editProfile.dart';
import '../../services/apps_Loading.dart';
import '../interaction/postMedia.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'journalBookPage.dart';
import 'achievementsPage.dart';
import '../../services/error_handler.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// LOCAL VIDEO PLAYER
// ════
class LocalVideoPlayer extends StatefulWidget {
  final String path;
  final bool autoPlay;

  const LocalVideoPlayer({
    super.key,
    required this.path,
    this.autoPlay = false,
  });

  @override
  State<LocalVideoPlayer> createState() => _LocalVideoPlayerState();
}

class _LocalVideoPlayerState extends State<LocalVideoPlayer> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.path.startsWith('http')
        ? VideoPlayerController.networkUrl(Uri.parse(widget.path))
        : VideoPlayerController.file(File(widget.path));
    _controller
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          if (widget.autoPlay) {
            _controller.play();
            _isPlaying = true;
          }
        }
      });
    _controller.addListener(() {
      if (mounted) setState(() => _isPlaying = _controller.value.isPlaying);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: TravelLoadingIndicator(),
        ),
      );
    }
    return GestureDetector(
      onTap: () {
        setState(() {
          if (_controller.value.isPlaying) {
            _controller.pause();
          } else {
            _controller.play();
          }
        });
      },
      child: Stack(fit: StackFit.expand, children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _controller.value.size.width,
            height: _controller.value.size.height,
            child: VideoPlayer(_controller),
          ),
        ),
        if (!_isPlaying)
          Container(
            color: Colors.black.withOpacity(0.3),
            child: const Center(
              child:
                  Icon(Icons.play_circle_fill, color: Colors.white70, size: 56),
            ),
          ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: VideoProgressIndicator(
            _controller,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: Color(0xFFD35D3E),
              bufferedColor: Colors.white38,
              backgroundColor: Colors.white12,
            ),
          ),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// BAR SWAP
// ═══════════════════════════════════════════════════════════════════════════════

class _BarSwap extends StatelessWidget {
  final Function(int)? onTabChanged;
  final int selectedIndex;

  const _BarSwap({super.key, this.onTabChanged, this.selectedIndex = 0});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final tabWidth = (width - 90) / 2;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Container(
        height: 55,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              alignment: selectedIndex == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: Container(
                margin: const EdgeInsets.all(7.5),
                height: 50,
                width: tabWidth,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => onTabChanged?.call(0),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      alignment: Alignment.center,
                      child: Text(
                        'Post',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: selectedIndex == 0
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: selectedIndex == 0
                              ? Colors.black
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => onTabChanged?.call(1),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      alignment: Alignment.center,
                      child: Text(
                        'History',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: selectedIndex == 1
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: selectedIndex == 1
                              ? Colors.black
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// POST WIDGET
// ═══════════════════════════════════════════════════════════════════════════════

class _PostWidget extends StatefulWidget {
  const _PostWidget({super.key});

  @override
  State<_PostWidget> createState() => _PostWidgetState();
}

class _PostWidgetState extends State<_PostWidget> {
  final PostService _postService = PostService();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final Set<String> _locallyDeletedPostIds = <String>{};

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
          return const Center(child: TravelLoadingIndicator());
        }
        if (snapshot.hasError) {
          return AppErrorStateView(
            title: 'Failed to load posts',
            message: ErrorHandler.userFriendlyMessage(snapshot.error),
            onRetry: () => setState(() {}),
          );
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

        final allPosts = snapshot.data!
            .where(
              (post) =>
                  post.id == null || !_locallyDeletedPostIds.contains(post.id),
            )
            .toList();

// 如果删除的是最后一个 post，立即显示 empty state
        if (allPosts.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.post_add,
                  size: 60,
                  color: Colors.grey[400],
                ),
                const SizedBox(height: 12),
                Text(
                  'No posts yet!',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          );
        }

        final mediaPosts = allPosts
            .where(
              (post) => post.images.isNotEmpty || post.videoPaths.isNotEmpty,
            )
            .toList();

        final textPosts = allPosts
            .where(
              (post) => post.images.isEmpty && post.videoPaths.isEmpty,
            )
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mediaPosts.isNotEmpty) ...[
              _buildSectionHeader(
                  icon: Icons.photo_library_outlined,
                  label: 'Photos & Videos',
                  count: mediaPosts.length),
              GridView.custom(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                childrenDelegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final post = mediaPosts[index];
                    return _buildMediaCard(post,
                        key: ValueKey(post.id ?? post.hashCode));
                  },
                  childCount: mediaPosts.length,
                  findChildIndexCallback: (Key key) {
                    final valueKey = key as ValueKey;
                    final index = mediaPosts.indexWhere(
                      (p) => (p.id ?? p.hashCode) == valueKey.value,
                    );
                    return index == -1 ? null : index;
                  },
                ),
              ),
            ],
            if (textPosts.isNotEmpty) ...[
              _buildSectionHeader(
                  icon: Icons.text_fields,
                  label: 'Text Posts',
                  count: textPosts.length),
              ListView.custom(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                childrenDelegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final post = textPosts[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildTextCard(post,
                          key: ValueKey(post.id ?? post.hashCode)),
                    );
                  },
                  childCount: textPosts.length,
                  findChildIndexCallback: (Key key) {
                    final valueKey = key as ValueKey;
                    final index = textPosts.indexWhere(
                      (p) => (p.id ?? p.hashCode) == valueKey.value,
                    );
                    return index == -1 ? null : index;
                  },
                ),
              ),
            ],
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  Widget _buildSectionHeader(
      {required IconData icon, required String label, required int count}) {
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

  Widget _buildMediaCard(Post post, {Key? key}) {
    final bool hasImage = post.images.isNotEmpty;
    final bool hasVideo = post.videoPaths.isNotEmpty;
    final int totalMedia = post.images.length + post.videoPaths.length;

    return GestureDetector(
      key: key,
      onTap: () => _showPostDetail(post),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(fit: StackFit.expand, children: [
          if (hasImage)
            buildPostImage(post.images.first,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _greyPlaceholder())
          else
            LocalVideoPlayer(path: post.videoPaths.first),
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
                  colors: [Colors.transparent, Colors.black.withOpacity(0.72)],
                ),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(post.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.favorite, color: Colors.white, size: 11),
                      const SizedBox(width: 3),
                      Text('${post.likes}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10)),
                      const SizedBox(width: 10),
                      const Icon(Icons.comment, color: Colors.white, size: 11),
                    ]),
                  ]),
            ),
          ),
          if (post.visibility != 'public')
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: post.visibility == 'private'
                      ? Colors.red.withOpacity(0.8)
                      : Colors.orange.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(post.visibility == 'private' ? Icons.lock : Icons.people,
                      color: Colors.white, size: 11),
                  const SizedBox(width: 3),
                  Text(post.visibility,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
          if (totalMedia > 1)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(hasVideo ? Icons.video_collection : Icons.collections,
                      color: Colors.white, size: 11),
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

  Widget _buildTextCard(Post post, {Key? key}) {
    return GestureDetector(
      key: key,
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
                offset: const Offset(0, 2))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(post.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold))),
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
          Text(post.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: Colors.grey[600], height: 1.5)),
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
                                fontSize: 10, color: Color(0xFFD35D3E))),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.favorite_border, size: 13, color: Colors.grey[500]),
            const SizedBox(width: 3),
            Text('${post.likes}',
                style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            const SizedBox(width: 10),
            Icon(Icons.chat_bubble_outline, size: 13, color: Colors.grey[500]),
            const Spacer(),
            Text(_formatDate(post.createdAt),
                style: TextStyle(fontSize: 11, color: Colors.grey[400])),
          ]),
        ]),
      ),
    );
  }

  Widget _greyPlaceholder() => Container(
        color: Colors.grey[300],
        child: const Icon(Icons.broken_image, color: Colors.grey, size: 40),
      );

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  void _showPostDetail(Post post) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.82,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
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
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, index) => ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: buildPostImage(post.images[index],
                                width: 220, fit: BoxFit.cover),
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
                                child: LocalVideoPlayer(
                                    path: post.videoPaths[index])),
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
                    Row(children: [
                      _buildStatItem(Icons.favorite, '${post.likes}', 'Likes'),
                      const SizedBox(width: 24),
                    ]),
                  ]),
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
                    offset: const Offset(0, -4))
              ],
            ),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context); // 先关掉 bottom sheet
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => EditPostPage(post: post),
                      ),
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

  Widget _buildStatItem(IconData icon, String count, String label) {
    return Column(children: [
      Row(children: [
        Icon(icon, size: 18, color: Colors.grey[700]),
        const SizedBox(width: 4),
        Text(count,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ]),
      Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 11)),
    ]);
  }

  Future<void> _confirmDelete(
    BuildContext sheetContext,
    Post post,
  ) async {
    final shouldDelete = await showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete Post'),
          content: const Text(
            'Are you sure you want to delete this post?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) return;
    if (!mounted) return;

    final postId = post.id;

    if (postId == null || postId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to delete this post'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    Navigator.of(context).pop();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _locallyDeletedPostIds.add(postId);
      });

      // 🆕 跟 UI 消失同时弹出提示，不等后台请求结果
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Post deleted successfully'),
          backgroundColor: Colors.green,
        ),
      );
    });

    try {
      await _postService.deletePost(postId);
      // 🆕 成功了就不用再弹一次提示了，上面已经弹过
    } catch (e) {
      if (!mounted) return;

      // 删除失败，把 post 恢复显示，并用另一条提示告知失败
      setState(() {
        _locallyDeletedPostIds.remove(postId);
      });

      ErrorHandler.showError(context,
          error: e, message: 'Failed to delete post. Please try again.');
    }
  }
} // 关闭 _PostWidgetState class

// ═══════════════════════════════════════════════════════════════════════════════
// HISTORY WIDGET
// ═══════════════════════════════════════════════════════════════════════════════

const _kAccents = [
  [Color(0xFF5E35B1), Color(0xFF9C27B0)],
  [Color(0xFF00796B), Color(0xFF26C6DA)],
  [Color(0xFFE65100), Color(0xFFFFA726)],
  [Color(0xFF1565C0), Color(0xFF42A5F5)],
  [Color(0xFF880E4F), Color(0xFFEC407A)],
];

class _HistoryWidget extends StatefulWidget {
  const _HistoryWidget({super.key});

  @override
  State<_HistoryWidget> createState() => _HistoryWidgetState();
}

class _HistoryWidgetState extends State<_HistoryWidget> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TripHistory>>(
      stream: HistoryService.instance.streamGrouped(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 240,
            child: Center(child: TravelLoadingIndicator()),
          );
        }
        final trips = snap.data ?? [];
        if (trips.isEmpty) return _buildEmptyState();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('My Trips',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1A2E),
                          letterSpacing: -0.5)),
                  Row(
                    children: [
                      Text('${trips.length} trip${trips.length > 1 ? "s" : ""}',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[400],
                              fontWeight: FontWeight.w500)),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: trips.isEmpty
                            ? null
                            : () => _openJournalBook(
                                context, trips, trips.first,
                                isOverall: true),
                        child: Row(
                          children: [
                            Icon(Icons.menu_book_rounded,
                                size: 14, color: Color(0xFFD35D3E)),
                            const SizedBox(width: 3),
                            Text('View All',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFD35D3E))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 240,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: trips.length,
                itemBuilder: (_, i) => _TripCard(
                  trip: trips[i],
                  index: i,
                  onTap: () => _openJournalBook(context, [trips[i]], trips[i],
                      isOverall: false),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _openJournalBook(
      BuildContext context, List<TripHistory> trips, TripHistory tapped,
      {required bool isOverall}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => JournalBookPage(
          trips: trips,
          initialItineraryId: tapped.itineraryId,
          isOverall: isOverall,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration:
                BoxDecoration(color: Colors.grey[100], shape: BoxShape.circle),
            child: Icon(Icons.flight_takeoff_rounded,
                size: 32, color: Colors.grey[350]),
          ),
          const SizedBox(height: 14),
          Text('No adventures yet',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[500])),
          const SizedBox(height: 4),
          Text('Your travel stories will live here',
              style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ]),
      ),
    );
  }

  void _openTripDetail(BuildContext context, TripHistory trip) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => _TripDetailPopup(trip: trip),
    );
  }
}

class _TripCard extends StatelessWidget {
  final TripHistory trip;
  final int index;
  final VoidCallback onTap;

  const _TripCard(
      {required this.trip, required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = _kAccents[index % _kAccents.length];
    final hasPhoto = trip.coverPhoto != null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 175,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: (hasPhoto ? Colors.black : accent[0]).withOpacity(0.22),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(fit: StackFit.expand, children: [
            if (hasPhoto)
              CachedNetworkImage(
                imageUrl: trip.coverPhoto!,
                fit: BoxFit.cover,
                memCacheWidth: 400,
                errorWidget: (_, __, ___) => _gradientBg(accent),
              )
            else
              _gradientBg(accent),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.08),
                    Colors.black.withOpacity(0.75)
                  ],
                  stops: const [0.35, 0.6, 1.0],
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.93),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(DateFormat('dd MMM').format(trip.latestVisit),
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A2E),
                        letterSpacing: 0.2)),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(trip.itineraryTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                              letterSpacing: -0.2)),
                      const SizedBox(height: 8),
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: const Color(0xFF4DB6AC).withOpacity(0.85),
                              borderRadius: BorderRadius.circular(20)),
                          child: Row(children: [
                            const Icon(Icons.location_on_rounded,
                                size: 9, color: Colors.white),
                            const SizedBox(width: 3),
                            Text(
                                '${trip.places.length} place${trip.places.length > 1 ? "s" : ""}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700)),
                          ]),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              shape: BoxShape.circle),
                          child: const Icon(Icons.arrow_forward_rounded,
                              size: 11, color: Colors.white),
                        ),
                      ]),
                    ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _gradientBg(List<Color> colors) => Container(
        decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight)),
        child: Center(
            child: Icon(Icons.map_rounded,
                size: 52, color: Colors.white.withOpacity(0.15))),
      );
}

class _TripDetailPopup extends StatelessWidget {
  final TripHistory trip;
  const _TripDetailPopup({required this.trip});

  @override
  Widget build(BuildContext context) {
    final places = [...trip.places]
      ..sort((a, b) => a.visitedAt.compareTo(b.visitedAt));

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(32))),
        child: Column(children: [
          const SizedBox(height: 12),
          Center(
              child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(2)))),
          if (trip.coverPhoto != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  height: 120,
                  width: double.infinity,
                  child: CachedNetworkImage(
                    imageUrl: trip.coverPhoto!,
                    fit: BoxFit.cover,
                    memCacheWidth: 500,
                    errorWidget: (_, __, ___) => const SizedBox(),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
            child: Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(trip.itineraryTitle,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF1A1A2E),
                            letterSpacing: -0.4)),
                    const SizedBox(height: 3),
                    Text(
                        '${trip.places.length} location${trip.places.length > 1 ? "s" : ""} visited',
                        style:
                            TextStyle(fontSize: 13, color: Colors.grey[500])),
                  ])),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                    color: const Color(0xFF4DB6AC).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12)),
                child: Text(DateFormat('MMM yyyy').format(trip.latestVisit),
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF4DB6AC),
                        fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
          Divider(
              color: Colors.grey[100], height: 1, indent: 24, endIndent: 24),
          Expanded(
            child: ListView.builder(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              itemCount: places.length,
              itemBuilder: (_, i) {
                final item = places[i];
                final isLast = i == places.length - 1;
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(children: [
                        Container(
                          width: 14,
                          height: 14,
                          decoration: const BoxDecoration(
                              shape: BoxShape.circle, color: Color(0xFF4DB6AC)),
                          child: const Center(
                              child: Icon(Icons.check_rounded,
                                  size: 8, color: Colors.white)),
                        ),
                        if (!isLast)
                          Container(
                              width: 2, height: 88, color: Colors.grey[100]),
                      ]),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    DateFormat('hh:mm a')
                                        .format(item.visitedAt),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF4DB6AC),
                                        letterSpacing: 0.3)),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8F9FA),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                        color: Colors.grey[100]!, width: 1),
                                  ),
                                  child: Row(children: [
                                    Expanded(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                          Text(item.placeName,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                  color: Color(0xFF1A1A2E))),
                                          const SizedBox(height: 3),
                                          Text(item.address,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.grey[500])),
                                        ])),
                                    if (item.photoUrl != null) ...[
                                      const SizedBox(width: 10),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: CachedNetworkImage(
                                          imageUrl: item.photoUrl!,
                                          width: 48,
                                          height: 48,
                                          fit: BoxFit.cover,
                                          memCacheWidth: 120,
                                          memCacheHeight: 120,
                                          errorWidget: (_, __, ___) =>
                                              const SizedBox(),
                                        ),
                                      ),
                                    ],
                                  ]),
                                ),
                              ]),
                        ),
                      ),
                    ]);
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROFILE PAGE
// ═══════════════════════════════════════════════════════════════════════════════

class ProfilePage extends StatefulWidget {
  final int initialTab;
  const ProfilePage({super.key, this.initialTab = 0});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final UserService _userService = UserService();
  StreamSubscription<UserProfile?>? _profileSub;

  UserProfile? _profile;
  bool _profileLoading = true;
  String? _profileError;
  ImageProvider? _bgImageProvider;
  ImageProvider? _avatarImageProvider;
  int _visualLoadGeneration = 0;

  bool _showZoom = false;
  int _currentIndex = 0;
  List<AchievementTier> _badges = [];

  static const List<Widget> _tabs = [_PostWidget(), _HistoryWidget()];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab;
    _listenProfile();
    _loadBadges();
  }

  void _listenProfile() {
    _profileSub?.cancel();
    _profileSub = _userService.getCurrentUserProfileStream().listen(
      (profile) async {
        final gen = ++_visualLoadGeneration;
        final targetProfile = profile ??
            UserProfile(
              uid: _userService.currentUserId ?? '',
              username:
                  FirebaseAuth.instance.currentUser?.displayName ?? 'User',
              bio: 'Hello! I\'m new here 👋',
              profileImageUrl:
                  FirebaseAuth.instance.currentUser?.photoURL ?? '',
              backgroundImageUrl: '',
            );

        final bgFuture = _prepareImageProvider(
          targetProfile.backgroundImageUrl,
          'assets/images/longbg1.jpg',
        );
        final avatarFuture = _prepareImageProvider(
          targetProfile.profileImageUrl,
          'assets/images/profile.jpg',
        );

        final results = await Future.wait([bgFuture, avatarFuture]);

        if (!mounted || gen != _visualLoadGeneration) return;

        setState(() {
          _profile = targetProfile;
          _bgImageProvider = results[0];
          _avatarImageProvider = results[1];
          _profileLoading = false;
          _profileError = null;
        });
      },
      onError: (e) {
        debugPrint('Profile stream error: $e');
        if (mounted) {
          setState(() {
            _profileLoading = false;
            _profileError = 'Failed to load profile. Please try again.';
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _visualLoadGeneration++;
    _profileSub?.cancel();
    super.dispose();
  }

  Future<void> _loadBadges() async {
    final badges = await AchievementService.instance.fetchUnlockedBadges();
    if (mounted) setState(() => _badges = badges);
  }

  Future<ImageProvider> _prepareImageProvider(
    String imageUrl,
    String defaultAsset,
  ) async {
    ImageProvider provider;
    bool isNetwork = false;

    if (imageUrl.isEmpty) {
      provider = AssetImage(defaultAsset);
    } else if (imageUrl.startsWith('data:image')) {
      try {
        final parts = imageUrl.split(',');
        if (parts.length < 2) {
          provider = AssetImage(defaultAsset);
        } else {
          final bytes = base64Decode(parts[1]);
          provider = MemoryImage(bytes);
        }
      } catch (_) {
        provider = AssetImage(defaultAsset);
      }
    } else if (imageUrl.startsWith('http://') ||
        imageUrl.startsWith('https://')) {
      provider = CachedNetworkImageProvider(imageUrl);
      isNetwork = true;
    } else {
      provider = AssetImage(defaultAsset);
    }

    try {
      if (mounted) {
        if (isNetwork) {
          await precacheImage(provider, context)
              .timeout(const Duration(seconds: 3));
        } else {
          await precacheImage(provider, context);
        }
      }
      return provider;
    } catch (_) {
      final fallback = AssetImage(defaultAsset);
      if (mounted) {
        try {
          await precacheImage(fallback, context);
        } catch (_) {}
      }
      return fallback;
    }
  }

  ImageProvider _getImageProvider(String imageUrl, String defaultAsset) {
    if (imageUrl.isEmpty) return AssetImage(defaultAsset);

    if (imageUrl.startsWith('data:image')) {
      try {
        final parts = imageUrl.split(',');
        if (parts.length < 2) {
          return AssetImage(defaultAsset); // 🆕 格式不对，直接 fallback
        }
        final bytes = base64Decode(parts[1]);
        return MemoryImage(bytes);
      } catch (e) {
        // 🆕 base64 解析失败，不要让整个页面崩溃，退回默认头像
        return AssetImage(defaultAsset);
      }
    }

    if (imageUrl.startsWith('http://') || imageUrl.startsWith('https://')) {
      return CachedNetworkImageProvider(imageUrl);
    }
    return AssetImage(defaultAsset);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return SafeArea(
      child: Scaffold(
        body: _showZoom ? _buildZoomView(height) : _buildProfileView(height),
      ),
    );
  }

  Widget _buildProfileView(double height) {
    if (_profileLoading && _profile == null) {
      return const Center(child: TravelLoadingIndicator());
    }

    if (_profileError != null && _profile == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            Text(_profileError!,
                style: TextStyle(color: Colors.grey[600], fontSize: 14)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                setState(() => _profileLoading = true);
                _listenProfile();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final userProfile = _profile;
    if (userProfile == null) {
      return const Center(child: Text('Profile unavailable'));
    }

    return Stack(children: [
      Container(
        height: 200,
        width: double.infinity,
        decoration: BoxDecoration(
          image: DecorationImage(
            image: _bgImageProvider ??
                _getImageProvider(
                    userProfile.backgroundImageUrl, 'assets/images/longbg1.jpg'),
            fit: BoxFit.cover,
          ),
        ),
      ),
      Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.transparent, Colors.white],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0, .2],
          ),
        ),
      ),
      Center(
        child: SingleChildScrollView(
          padding:
              const EdgeInsets.only(bottom: kBottomNavigationBarHeight + 16),
          child: Column(children: [
            SizedBox(height: height * 0.13),
            _buildProfileInfo(height),
            SizedBox(height: height * 0.03),
            _BarSwap(
              key: const ValueKey('barswap'),
              selectedIndex: _currentIndex,
              onTabChanged: (index) => setState(() => _currentIndex = index),
            ),
            SizedBox(height: height * 0.02),
            IndexedStack(index: _currentIndex, children: _tabs),
          ]),
        ),
      ),
    ]);
  }

  Widget _buildZoomView(double height) {
    final userProfile = _profile;
    if (userProfile == null) {
      // 理论上点头像时 _profile 早已有值；保险起见给个可点击返回的占位
      return InkWell(
        onTap: () => setState(() => _showZoom = false),
        child: const SizedBox.expand(),
      );
    }

    return InkWell(
      onTap: () => setState(() => _showZoom = false),
      child: Stack(children: [
        Container(
          height: 200,
          width: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(
              image: _avatarImageProvider ??
                  _getImageProvider(
                      userProfile.profileImageUrl, 'assets/images/profile.jpg'),
              fit: BoxFit.cover,
            ),
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, Colors.white],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, .2],
            ),
          ),
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            height: height,
            color: Colors.white.withOpacity(0.3),
            child: Center(
              child: CircleAvatar(
                radius: 120,
                backgroundImage: _avatarImageProvider ??
                    _getImageProvider(
                        userProfile.profileImageUrl, 'assets/images/profile.jpg'),
                onBackgroundImageError: (exception, stackTrace) {
                  // 🆕 静默处理，避免未捕获异常
                },
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildProfileInfo(double height) {
    final userProfile = _profile;

    if (userProfile == null) {
      return SizedBox(
          height: 200, child: Center(child: TravelLoadingIndicator()));
    }

    return Column(children: [
      CircleAvatar(
        backgroundColor: Colors.indigoAccent,
        radius: 47,
        child: CircleAvatar(
          backgroundColor: Colors.white,
          radius: 45,
          child: InkWell(
            onTap: () => setState(() => _showZoom = true),
            child: CircleAvatar(
              radius: 43,
              backgroundImage: _avatarImageProvider ??
                  _getImageProvider(
                      userProfile.profileImageUrl, 'assets/images/profile.jpg'),
              onBackgroundImageError: (exception, stackTrace) {
                // 🆕 静默处理，避免未捕获异常
              },
            ),
          ),
        ),
      ),
      SizedBox(height: height * 0.02),
      Text(
        userProfile.username.isNotEmpty
            ? '@${userProfile.username}'
            : '@username',
        style: const TextStyle(fontSize: 16, color: Colors.grey),
      ),

      // ── Badge row (like Weibo level badges) ──
      if (_badges.isNotEmpty) ...[
        const SizedBox(height: 8),
        _buildBadgeRow(),
      ],

      Padding(
        padding: const EdgeInsets.only(left: 30, right: 30, top: 10),
        child: Text(
          userProfile.bio.isNotEmpty ? userProfile.bio : 'Bio',
          style: TextStyle(fontSize: 15, color: Colors.grey.shade400),
          textAlign: TextAlign.center,
        ),
      ),
      SizedBox(height: height * 0.02),
      ElevatedButton.icon(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => EditProfilePage(userProfile: userProfile)),
        ),
        icon: const Icon(Icons.edit, size: 18),
        label: const Text('Edit Profile'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.indigoAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      SizedBox(height: height * 0.02),
      // ── Stats: Post + Favourite only (Route removed) ──
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _statColumn('Post', '${userProfile.postCount}'),
          _statColumn('Favourite', '${userProfile.favouriteCount}'),
        ],
      ),
    ]);
  }

  // ── Badge row — compact Weibo-style display ──────────────────────────────
  static const _tierColors = {
    'bronze': Color(0xFFCD7F32),
    'silver': Color(0xFFA8A9AD),
    'gold': Color(0xFFFFD700),
  };

  Widget _buildBadgeRow() {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AchievementsPage()),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: _badges.map((tier) {
          final color = _tierColors[tier.level] ?? const Color(0xFF6366F1);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withOpacity(0.4), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tier.emoji, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 3),
                Text(
                  tier.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // Bottom sheet showing all badges on tap
  void _showBadgeSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('My Badges',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                '${_badges.length} badge${_badges.length == 1 ? '' : 's'} earned',
                style: TextStyle(fontSize: 13, color: Colors.grey[500])),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _badges.map((tier) {
                final color =
                    _tierColors[tier.level] ?? const Color(0xFF6366F1);
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: color.withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(tier.emoji, style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(tier.label,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.bold)),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: color.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(tier.level.toUpperCase(),
                                  style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                      color: color)),
                            ),
                          ]),
                          Text(tier.desc,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[600])),
                        ],
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _statColumn(String label, String value) {
    return Column(children: [
      Text(label, style: const TextStyle(fontSize: 15, color: Colors.grey)),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(value,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87)),
      ),
    ]);
  }
}
