import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // 添加这行
import 'dart:io';
import 'addPost.dart';
import 'postModel.dart';
import '../../services/post_service.dart';

class InteractionPage extends StatefulWidget {
  const InteractionPage({super.key});

  @override
  State<InteractionPage> createState() => _InteractionPageState();
}

class _InteractionPageState extends State<InteractionPage> {
  final PostService _postService = PostService();
  final FirebaseAuth _auth = FirebaseAuth.instance; // 添加这行

  @override
  Widget build(BuildContext context) {
    // 获取当前用户
    User? currentUser = _auth.currentUser;
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Followed", style: TextStyle(color: Colors.grey, fontSize: 15)),
            const SizedBox(width: 20),
            Column(
              children: [
                const Text("Post", style: TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Container(height: 3, width: 20, decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(2))),
              ],
            ),
            const SizedBox(width: 20),
            const Text("Nearby", style: TextStyle(color: Colors.grey, fontSize: 15)),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.black, size: 28),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const PostingPage()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<Post>>(
        // 从数据库实时读取帖子
        stream: _postService.getPublicPosts(),
        builder: (context, snapshot) {
          // 加载中
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(
                color: Color(0xFFD35D3E),
              ),
            );
          }

          // 错误处理
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(
                    '加载失败: ${snapshot.error}',
                    style: const TextStyle(color: Colors.red),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {}); // 重新加载
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }

          // 没有数据
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.post_add, size: 80, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    '还没有帖子',
                    style: TextStyle(color: Colors.grey[600], fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击右上角 + 发布第一个帖子吧!',
                    style: TextStyle(color: Colors.grey[500], fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const PostingPage()),
                      );
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('发布帖子'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD35D3E),
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                    ),
                  ),
                ],
              ),
            );
          }

          // 显示帖子列表
          List<Post> posts = snapshot.data!;

          return RefreshIndicator(
            onRefresh: () async {
              setState(() {}); // 刷新数据
            },
            color: const Color(0xFFD35D3E),
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              itemCount: posts.length,
              padding: const EdgeInsets.symmetric(vertical: 10),
              itemBuilder: (context, index) {
                return _buildPostCard(posts[index]);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildPostCard(Post post) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 用户信息
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5),
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: _getUserColor(post.userId),
                  child: post.isAnonymous
                      ? const Icon(Icons.person_outline, color: Colors.white, size: 22)
                      : Text(
                          post.userId.substring(0, 1).toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.isAnonymous ? '匿名用户' : _formatUsername(post.userId),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${_formatTime(post.createdAt)} · GoTrip 极速版",
                      style: TextStyle(color: Colors.grey[500], fontSize: 11),
                    ),
                  ],
                ),
              ),
              PopupMenuButton(
                icon: const Icon(Icons.more_horiz, color: Colors.grey),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'share',
                    child: Row(
                      children: [
                        Icon(Icons.share, size: 20),
                        SizedBox(width: 8),
                        Text('分享'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'report',
                    child: Row(
                      children: [
                        Icon(Icons.flag, size: 20),
                        SizedBox(width: 8),
                        Text('举报'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 标题 (如果有)
          if (post.title.isNotEmpty) ...[
            Text(
              post.title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Color(0xFF222222),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // 内容
          Text(
            post.content,
            style: const TextStyle(fontSize: 15, color: Color(0xFF333333), height: 1.5),
          ),
          const SizedBox(height: 12),

          // 图片展示
          if (post.images.isNotEmpty) _buildImageGrid(post.images),

          // 标签
          if (post.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: post.tags.map((tag) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    tag,
                    style: const TextStyle(
                      color: Color(0xFFD35D3E),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],

          // 地点
          if (post.location != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.location_on, size: 16, color: Color(0xFFD35D3E)),
                const SizedBox(width: 4),
                Text(
                  post.location!,
                  style: const TextStyle(color: Color(0xFF666666), fontSize: 13),
                ),
              ],
            ),
          ],

          const SizedBox(height: 16),
          const Divider(height: 1, thickness: 0.5),
          const SizedBox(height: 12),

          // 互动按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildSocialBtn(
                Icons.share_outlined,
                post.shares > 0 ? '${post.shares}' : '转发',
                () => _handleShare(post),
              ),
              _buildSocialBtn(
                Icons.chat_bubble_outline,
                post.comments > 0 ? '${post.comments}' : '评论',
                () => _handleComment(post),
              ),
              _buildSocialBtn(
                Icons.thumb_up_outlined,
                post.likes > 0 ? '${post.likes}' : '赞',
                () => _handleLike(post),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 构建图片网格
  Widget _buildImageGrid(List<String> images) {
    int imageCount = images.length;

    // 单张图片 - 大图显示
    if (imageCount == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(images[0]),
          width: double.infinity,
          height: 250,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              height: 250,
              color: Colors.grey[300],
              child: const Center(
                child: Icon(Icons.broken_image, size: 50, color: Colors.grey),
              ),
            );
          },
        ),
      );
    }

    // 2-4张图片 - 网格显示
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: imageCount == 2 ? 2 : 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: imageCount > 9 ? 9 : imageCount,
      itemBuilder: (context, index) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(images[index]),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.broken_image, color: Colors.grey),
                  );
                },
              ),
              // 如果有超过9张图,在第9张上显示 +N
              if (imageCount > 9 && index == 8)
                Container(
                  color: Colors.black.withOpacity(0.6),
                  child: Center(
                    child: Text(
                      '+${imageCount - 9}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSocialBtn(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.grey[700]),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: Colors.grey[700], fontSize: 13)),
          ],
        ),
      ),
    );
  }

  // 处理点赞
  void _handleLike(Post post) async {
    try {
      await _postService.toggleLike(post.id!, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已点赞'),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFFD35D3E),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('点赞失败: $e')),
      );
    }
  }

  // 处理评论
  void _handleComment(Post post) {
    // TODO: 跳转到评论页面
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('评论功能开发中...')),
    );
  }

  // 处理转发
  void _handleShare(Post post) async {
    try {
      await _postService.incrementShareCount(post.id!);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已转发'),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFFD35D3E),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('转发失败: $e')),
      );
    }
  }

  // 格式化时间
  String _formatTime(DateTime? dateTime) {
    if (dateTime == null) return '刚刚';

    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return '刚刚';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} mins ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    } else {
      return '${dateTime.month}月${dateTime.day}日';
    }
  }

  // 格式化用户名
  String _formatUsername(String userId) {
    // 如果是 user_123 这种格式,转换成更友好的显示
    if (userId.startsWith('user_')) {
      return 'User${userId.substring(5)}';
    }
    return userId;
  }

  // 根据用户ID生成颜色
  Color _getUserColor(String userId) {
    final colors = [
      Colors.blueAccent,
      Colors.greenAccent,
      Colors.purpleAccent,
      Colors.orangeAccent,
      Colors.pinkAccent,
      Colors.tealAccent,
      Colors.indigoAccent,
      Colors.cyanAccent,
    ];

    int index = userId.hashCode % colors.length;
    return colors[index.abs()];
  }
}