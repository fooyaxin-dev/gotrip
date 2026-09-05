// ===== postDetailPage.dart =====
// 放在 lib/modules/interaction/ 目录下
//
// 改动说明（这一版针对"看起来一块一块很丑"的问题）：
// 1. 整篇帖子现在是一张连续的白色卡片（顶部圆角，贴着灰色背景浮起来），
//    不再是好几个各自独立、中间露出灰缝的 Container 拼接。
// 2. 媒体（单图/单视频/多图）统一用圆角，风格一致，靠卡片自身的
//    clipBehavior 裁剪，不用每个媒体单独处理圆角。
// 3. 用户信息 / 媒体 / 正文 / Like·Comment 全部在同一个卡片里，
//    section 之间用细 Divider 分隔，而不是整块整块地断开。
// 4. 依然保留 StreamBuilder 实时监听 doc —— 编辑保存后自动刷新。

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import '../../models/postModel.dart';
import '../../services/like_service.dart';
import '../../services/post_service.dart';
import '../../services/userPreference_service.dart';
import '../../services/sentiment_service.dart';
import '../../services/error_handler.dart';
import '../profile/profile.dart';
import 'editPost.dart';
import '../../modules/place/detectPlacePage.dart';
import 'postMedia.dart';


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

  bool? _optimisticLiked;
  int? _optimisticLikeCount;
  bool _likeRequestInFlight = false;

  static const double _mediaHeight = 300;
  static const Color _cardBg = Colors.white;
  static const Color _pageBg = Color(0xFFF3F4F6);

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

  Future<void> _handleLike(Post post, bool currentlyLiked, int currentCount) async {
    if (_likeRequestInFlight) return;

    _likeRequestInFlight = true;

    final newLiked = !currentlyLiked;
    final newCount = (currentlyLiked ? currentCount - 1 : currentCount + 1).clamp(0, 999999);

    setState(() {
      _optimisticLiked = newLiked;
      _optimisticLikeCount = newCount;
    });

    try {
      final bool serverLiked = await _likeService.toggleLike(post.id!);

      unawaited(_learnFromLike(post, serverLiked));

      if (!mounted) return;

      if (serverLiked != newLiked) {
        setState(() {
          _optimisticLiked = serverLiked;
        });
      }

      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          setState(() {
            _optimisticLiked = null;
            _optimisticLikeCount = null;
          });
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _optimisticLiked = currentlyLiked;
        _optimisticLikeCount = currentCount;
      });
      ErrorHandler.showError(context, error: e, message: 'Could not update like. Please try again.');
    } finally {
      _likeRequestInFlight = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _learnFromLike(Post post, bool isLiked) async {
    try {
      await UserPreferenceService.instance.updateFromLike(
        placeTypes: post.placeTypes,
        postTags: post.tags,
        postTopic: post.topic,
        isLiking: isLiked,
        sentimentLabel:
            post.sentimentLabel ?? SentimentLabel.neutral,
        sentimentMatchedTokens:
            post.sentimentMatchedTokens ?? 0,
      );
    } catch (e) {
      debugPrint(
        '⚠️ Like succeeded, but preference learning failed: $e',
      );
    }
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

  // ── Sentiment badge ──────────────────────────────────────────────────────
  // 跟 interactionPage.dart 用同一套配色，视觉保持一致。
  static const Map<SentimentLabel, Color> _sentimentColors = {
    SentimentLabel.positive: Color(0xFF2E7D32),
    SentimentLabel.neutral:  Color(0xFF757575),
    SentimentLabel.negative: Color(0xFFC62828),
  };

  // ── Rating badge ─────────────────────────────────────────────────────────
  // 只在 post.rating > 0 时才会被调用 —— 没打分的帖子不显示，
  // 跟下面 Content 区块里完整的 5 星展示保持一致的判断条件。
  Widget _buildRatingBadge(int rating) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.star_rounded, size: 12, color: Colors.orange),
        const SizedBox(width: 3),
        Text('$rating.0',
            style: const TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold, color: Colors.orange)),
      ]),
    );
  }


  Widget _buildSentimentBadge(SentimentLabel label) {
    final color = _sentimentColors[label]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label.emoji, style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 4),
        Text(label.displayLabel,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  // ── Location tap modal（跟 interactionPage.dart 保持一致）─────────────────

  void _onLocationTap(Post post) {
    if (post.locationLat != null && post.locationLng != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RealTimeDetectPage(
            landmarkLat: post.locationLat,
            landmarkLng: post.locationLng,
            onBack: () => Navigator.pop(context),
          ),
        ),
      );
      return;
    }

    if (post.city != null && post.city!.isNotEmpty) {
      Navigator.pop(context); // 详情页拿不到 feed 状态，只能退回上一页
    }
  }
 
 
  void _handleDelete(String postId) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete Post'),
      content: const Text(
        'Are you sure you want to delete this post?',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(dialogContext);

            try {
              await _postService.deletePost(postId);

              // Do NOT pop this page manually.
              //
              // The StreamBuilder listening to this post
              // will detect that the Firestore document
              // no longer exists and close PostDetailPage
              // exactly once.
            } catch (e) {
              if (!mounted) return;
              ErrorHandler.showError(context, error: e, message: 'Failed to delete post. Please try again.');
            }
          },
          child: const Text(
            'Delete',
            style: TextStyle(
              color: Colors.red,
            ),
          ),
        ),
      ],
    ),
  );
}

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('posts').doc(widget.post.id).snapshots(),
      builder: (context, snapshot) {
        Post post = widget.post;
        if (snapshot.hasData && snapshot.data!.exists) {
          post = Post.fromFirestore(snapshot.data!);
        } else if (snapshot.hasData && !snapshot.data!.exists) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context, true);
          });
        }
        return _buildScaffold(context, post);
      },
    );
  }

  Widget _buildScaffold(BuildContext context, Post post) {
    final isOwner = post.userId == _auth.currentUser?.uid;

    return Scaffold(
      backgroundColor: _pageBg,
      appBar: AppBar(
        backgroundColor: _pageBg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Post', style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          if (isOwner)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, color: Colors.black87),
              onSelected: (value) {
                if (value == 'edit') {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => EditPostPage(post: post)));
                }
                if (value == 'delete') _handleDelete(post.id!);
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
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        child: Container(
          decoration: BoxDecoration(
            color: _cardBg,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 16, offset: const Offset(0, 4)),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── User info ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: StreamBuilder<DocumentSnapshot>(
                stream: _firestore.collection('users').doc(post.userId).snapshots(),
                builder: (context, snapshot) {
                  String userName   = post.userName;
                  String? userPhoto = post.userPhoto;
                  if (snapshot.hasData && snapshot.data!.exists) {
                    final data = snapshot.data!.data() as Map<String, dynamic>;
                    userName  = data['username']        ?? userName;
                    userPhoto = data['profileImageUrl'] ?? userPhoto;
                  }
                  return Row(children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5)),
                      child: _buildUserAvatar(userName, userPhoto, post.userId, post.isAnonymous),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(post.isAnonymous ? 'Anonymous User' : userName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text("${_formatTime(post.createdAt)} · GoTrip",
                          style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                    ])),
                  ]);
                },
              ),
            ),

            // ── Media（贴着卡片边缘，靠外层圆角裁剪，不用自己单独处理）──
            if (post.images.isNotEmpty || post.videoPaths.isNotEmpty)
              _buildMediaSection(post),

            // ── Content ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

                // Location + Rating badge + Sentiment badge（地点 + 评分 + 大家对这里的感受）
                if ((post.city != null && post.city!.isNotEmpty) ||
                    (post.location != null && post.location!.isNotEmpty) ||
                    post.rating > 0 ||
                    post.hasSentimentResult)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(children: [
                      if ((post.city != null && post.city!.isNotEmpty) ||
                        (post.location != null && post.location!.isNotEmpty)) ...[
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _onLocationTap(post),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.location_on, size: 14, color: Color(0xFFD35D3E)),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                [
                                  if (post.city != null && post.city!.isNotEmpty) post.city!,
                                  if (post.location != null && post.location!.isNotEmpty && post.location != post.city) post.location!,
                                ].join(' · '),
                                style: const TextStyle(fontSize: 13, color: Color(0xFFD35D3E), fontWeight: FontWeight.w500),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ],
                      if (post.rating > 0) ...[
                        const SizedBox(width: 8),
                        _buildRatingBadge(post.rating),
                      ],
                      if (post.hasSentimentResult) ...[
                        const SizedBox(width: 8),
                        _buildSentimentBadge(post.sentimentLabel!),
                      ],
                    ]),
                  ),

                // Title
                Text(post.title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold, color: Colors.black87, height: 1.3)),
                const SizedBox(height: 10),

                // Content
                Text(post.content, style: TextStyle(fontSize: 15, color: Colors.grey[800], height: 1.6)),
                const SizedBox(height: 14),

                // Rating（正文下方完整的 5 星展示，跟顶部 badge 是不同层级的信息，保留不删）
                if (post.rating > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(children: [
                      ...List.generate(5, (index) => Icon(
                        index < post.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                        size: 20,
                        color: index < post.rating ? Colors.orange : Colors.grey[300],
                      )),
                      const SizedBox(width: 8),
                      Text('${post.rating}/5', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                    ]),
                  ),

                // Tags
                if (post.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Wrap(
                      spacing: 8, runSpacing: 8,
                      children: post.tags.map((tag) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                            color: const Color(0xFFD35D3E).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16)),
                        child: Text('#$tag', style: const TextStyle(color: Color(0xFFD35D3E), fontSize: 13, fontWeight: FontWeight.w500)),
                      )).toList(),
                    ),
                  ),
              ]),
            ),

            // ── 细分隔线，代替以前整块断开的白 Container ──
            Divider(height: 1, thickness: 1, color: Colors.grey[100]),

            // ── Like & Comment ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(children: [
                Expanded(
                  child: StreamBuilder<bool>(
                    stream: _likeService.likeStatusStream(post.id!),
                    initialData: false,
                    builder: (context, snapshot) {
                      final isLikedFromStream = snapshot.data ?? false;
                      final isLiked = _optimisticLiked ?? isLikedFromStream;
                      return StreamBuilder<int>(
                        stream: _likeService.likeCountStream(post.id!),
                        initialData: post.likes,
                        builder: (context, countSnapshot) {
                          final countFromStream = countSnapshot.data ?? post.likes;
                          final likeCount = _optimisticLikeCount ?? countFromStream;
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _likeRequestInFlight
                                ? null
                                : () => _handleLike(post, isLiked, likeCount),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(
                                    isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                                    key: ValueKey(isLiked),
                                    size: 20,
                                    color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  likeCount > 0 ? '$likeCount' : 'Like',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700],
                                    fontWeight: isLiked ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ]),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                
              ]),
            ),
          ]),
        ),
      ),
    );
  }



  // ── Media Section ──────────────────────────────────────────────────────────

  Widget _buildMediaSection(Post post) {
    final images = post.images;
    final videos = post.videoPaths;

    final List<(String path, bool isVideo)> allMedia = [
      ...images.map((p) => (p, false)),
      ...videos.map((p) => (p, true)),
    ];

    if (allMedia.length == 1) {
      return _buildSingleMedia(allMedia[0].$1, allMedia[0].$2);
    }

    return SizedBox(
      height: _mediaHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: allMedia.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (path, isVideo) = allMedia[index];
          return ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 240,
              height: _mediaHeight,
              child: isVideo
                  ? LocalVideoPlayer(path: path)
                  : buildPostImage(path, fit: BoxFit.cover),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSingleMedia(String path, bool isVideo) {
    return SizedBox(
      width: double.infinity,
      height: _mediaHeight,
      child: isVideo
          ? LocalVideoPlayer(path: path)
          : buildPostImage(path, width: double.infinity, height: _mediaHeight, fit: BoxFit.cover),
    );
  }
}
