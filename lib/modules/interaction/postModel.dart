import 'package:cloud_firestore/cloud_firestore.dart';

/// 帖子数据模型 - 本地存储版本
class Post {
  final String? id;
  final String title;
  final String content;
  final List<String> images; // 本地文件路径列表
  final int rating;
  final bool isAnonymous;
  final bool allowComments;
  final bool allowShare;
  final String? location;
  final List<String> tags;
  final List<String> mentionedFriends;
  final String? topic;
  final String visibility;
  final DateTime? createdAt;
  final String userId;
  final int likes;
  final int comments;
  final int shares;

  Post({
    this.id,
    required this.title,
    required this.content,
    required this.images,
    this.rating = 0,
    this.isAnonymous = false,
    this.allowComments = true,
    this.allowShare = true,
    this.location,
    this.tags = const [],
    this.mentionedFriends = const [],
    this.topic,
    this.visibility = '公开',
    this.createdAt,
    required this.userId,
    this.likes = 0,
    this.comments = 0,
    this.shares = 0,
  });

  /// 从 Firestore 文档创建 Post 对象
  factory Post.fromFirestore(DocumentSnapshot doc) {
    Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
    
    return Post(
      id: doc.id,
      title: data['title'] ?? '',
      content: data['content'] ?? '',
      images: List<String>.from(data['imagePaths'] ?? data['images'] ?? []),
      rating: data['rating'] ?? 0,
      isAnonymous: data['isAnonymous'] ?? false,
      allowComments: data['allowComments'] ?? true,
      allowShare: data['allowShare'] ?? true,
      location: data['location'],
      tags: List<String>.from(data['tags'] ?? []),
      mentionedFriends: List<String>.from(data['mentionedFriends'] ?? []),
      topic: data['topic'],
      visibility: data['visibility'] ?? '公开',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      userId: data['userId'] ?? '',
      likes: data['likes'] ?? 0,
      comments: data['comments'] ?? 0,
      shares: data['shares'] ?? 0,
    );
  }

  /// 转换为 Map 用于保存到 Firestore
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'content': content,
      'imagePaths': images, // 使用 imagePaths 字段名
      'rating': rating,
      'isAnonymous': isAnonymous,
      'allowComments': allowComments,
      'allowShare': allowShare,
      'location': location,
      'tags': tags,
      'mentionedFriends': mentionedFriends,
      'topic': topic,
      'visibility': visibility,
      'createdAt': createdAt != null 
        ? Timestamp.fromDate(createdAt!) 
        : FieldValue.serverTimestamp(),
      'userId': userId,
      'likes': likes,
      'comments': comments,
      'shares': shares,
    };
  }

  /// 复制并修改某些字段
  Post copyWith({
    String? id,
    String? title,
    String? content,
    List<String>? images,
    int? rating,
    bool? isAnonymous,
    bool? allowComments,
    bool? allowShare,
    String? location,
    List<String>? tags,
    List<String>? mentionedFriends,
    String? topic,
    String? visibility,
    DateTime? createdAt,
    String? userId,
    int? likes,
    int? comments,
    int? shares,
  }) {
    return Post(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      images: images ?? this.images,
      rating: rating ?? this.rating,
      isAnonymous: isAnonymous ?? this.isAnonymous,
      allowComments: allowComments ?? this.allowComments,
      allowShare: allowShare ?? this.allowShare,
      location: location ?? this.location,
      tags: tags ?? this.tags,
      mentionedFriends: mentionedFriends ?? this.mentionedFriends,
      topic: topic ?? this.topic,
      visibility: visibility ?? this.visibility,
      createdAt: createdAt ?? this.createdAt,
      userId: userId ?? this.userId,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      shares: shares ?? this.shares,
    );
  }

  /// 转换为 JSON 字符串 (用于调试)
  @override
  String toString() {
    return 'Post{id: $id, title: $title, images: ${images.length}, likes: $likes}';
  }

  /// 判断是否相等
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    
    return other is Post &&
        other.id == id &&
        other.title == title &&
        other.userId == userId;
  }

  @override
  int get hashCode => id.hashCode ^ title.hashCode ^ userId.hashCode;
}