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
  final LikeService _likeService = LikeService(); // 添加点赞服务
  final FirebaseFirestore _firestore = FirebaseFirestore.instance; 

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

  // ===== 构建帖子卡片 =====
  Widget _buildPostCard(Post post) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ✅ 改用 StreamBuilder 实时读取用户信息
            _buildUserInfoWithStream(post),
            
            const SizedBox(height: 12),

            // 标题
            Text(
              post.title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),

            // 内容
            Text(
              post.content,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[800],
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),

            // 图片
            _buildImageGrid(post.images),

            // 标签
            if (post.tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: post.tags.map((tag) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD35D3E).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '#$tag',
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
                  false,
                ),
                _buildSocialBtn(
                  Icons.chat_bubble_outline,
                  post.comments > 0 ? '${post.comments}' : '评论',
                  () => _handleComment(post),
                  false,
                ),
                StreamBuilder<bool>(
                  stream: _likeService.likeStatusStream(post.id!),
                  initialData: false,
                  builder: (context, snapshot) {
                    bool isLiked = snapshot.data ?? false;
                    return _buildLikeButton(post, isLiked);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ✅ 新增: 实时读取用户信息
  Widget _buildUserInfoWithStream(Post post) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('users').doc(post.userId).snapshots(),
      builder: (context, snapshot) {
        // 默认值 (从帖子中获取)
        String userName = post.userName;
        String? userPhoto = post.userPhoto;

        // 如果能读取到最新数据,使用最新的
        if (snapshot.hasData && snapshot.data!.exists) {
          Map<String, dynamic> userData = snapshot.data!.data() as Map<String, dynamic>;
          userName = userData['username'] ?? userName;
          userPhoto = userData['profileImageUrl'] ?? userPhoto;
        }

        return Row(
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5),
              ),
              child: _buildUserAvatar(userName, userPhoto, post.userId, post.isAnonymous),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    post.isAnonymous ? '匿名用户' : userName,
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
              icon: Icon(Icons.more_horiz, color: Colors.grey[600]),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('举报'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
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

  // 构建点赞按钮 (特殊处理,支持高亮)
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                  size: 20,
                  color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700],
                ),
                const SizedBox(width: 6),
                Text(
                  likeCount > 0 ? '$likeCount' : '赞',
                  style: TextStyle(
                    color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700],
                    fontSize: 13,
                    fontWeight: isLiked ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSocialBtn(IconData icon, String label, VoidCallback onTap, bool isActive) {
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
      bool isLiked = await _likeService.toggleLike(post.id!);
      
      // 显示反馈
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isLiked ? '已点赞' : '已取消点赞'),
          duration: const Duration(milliseconds: 500),
          backgroundColor: isLiked ? const Color(0xFFD35D3E) : Colors.grey,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败: $e')),
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

  // 构建用户头像 (支持 Base64 和 URL)
  Widget _buildUserAvatar(String userName, String? userPhoto, String userId, bool isAnonymous) {
      if (isAnonymous) {
        return CircleAvatar(
          radius: 20,
          backgroundColor: _getUserColor(userId),
          child: const Icon(Icons.person_outline, color: Colors.white, size: 22),
        );
      }

      if (userPhoto != null && userPhoto.isNotEmpty) {
        if (userPhoto.startsWith('data:image')) {
          try {
            String base64String = userPhoto.split(',')[1];
            Uint8List bytes = base64Decode(base64String);
            return CircleAvatar(
              radius: 20,
              backgroundImage: MemoryImage(bytes),
              backgroundColor: Colors.transparent,
            );
          } catch (e) {
            print('Base64 解码失败: $e');
          }
        } else if (userPhoto.startsWith('http')) {
          return CircleAvatar(
            radius: 20,
            backgroundImage: NetworkImage(userPhoto),
            backgroundColor: Colors.transparent,
          );
        }
      }

      return CircleAvatar(
        radius: 20,
        backgroundColor: _getUserColor(userId),
        child: Text(
          userName.isNotEmpty ? userName.substring(0, 1).toUpperCase() : '?',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
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