import 'package:cloud_firestore/cloud_firestore.dart';

/// 帖子数据模型 - 本地存储版本
class Post {
  final String? id;
  final String title;
  final String content;
  final List<String> images;
  final int rating;
  final bool isAnonymous;
  final bool allowComments;
  final bool allowShare;
  final String? location;
  final String? city;        // ✅ 新增
  final List<String> tags;
  final List<String> mentionedFriends;
  final String? topic;
  final String visibility;
  final DateTime? createdAt;
  final String userId;
  final String userName;
  final String? userPhoto;
  final String? userEmail;
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
    this.city,             // ✅ 新增
    this.tags = const [],
    this.mentionedFriends = const [],
    this.topic,
    this.visibility = '公开',
    this.createdAt,
    required this.userId,
    required this.userName,
    this.userPhoto,
    this.userEmail,
    this.likes = 0,
    this.comments = 0,
    this.shares = 0,
  });

  factory Post.fromFirestore(DocumentSnapshot doc) {
    Map<String, dynamic> data = doc.data() as Map<String, dynamic>;

    String userName = 'Unknown User';
    if (data['userName'] != null && data['userName'].toString().isNotEmpty) {
      userName = data['userName'];
    } else if (data['userEmail'] != null) {
      userName = data['userEmail'].toString().split('@')[0];
    } else if (data['userId'] != null) {
      userName = 'User_${data['userId'].toString().substring(0, 8)}';
    }

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
      city: data['city'],    // ✅ 新增
      tags: List<String>.from(data['tags'] ?? []),
      mentionedFriends: List<String>.from(data['mentionedFriends'] ?? []),
      topic: data['topic'],
      visibility: data['visibility'] ?? '公开',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      userId: data['userId'] ?? '',
      userName: userName,
      userPhoto: data['userPhoto'],
      userEmail: data['userEmail'],
      likes: data['likes'] ?? 0,
      comments: data['comments'] ?? 0,
      shares: data['shares'] ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'content': content,
      'imagePaths': images,
      'rating': rating,
      'isAnonymous': isAnonymous,
      'allowComments': allowComments,
      'allowShare': allowShare,
      'location': location,
      'city': city,          // ✅ 新增
      'tags': tags,
      'mentionedFriends': mentionedFriends,
      'topic': topic,
      'visibility': visibility,
      'createdAt': createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
      'userId': userId,
      'userName': userName,
      'userPhoto': userPhoto,
      'userEmail': userEmail,
      'likes': likes,
      'comments': comments,
      'shares': shares,
    };
  }

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
    String? city,          // ✅ 新增
    List<String>? tags,
    List<String>? mentionedFriends,
    String? topic,
    String? visibility,
    DateTime? createdAt,
    String? userId,
    String? userName,
    String? userPhoto,
    String? userEmail,
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
      city: city ?? this.city,  // ✅ 新增
      tags: tags ?? this.tags,
      mentionedFriends: mentionedFriends ?? this.mentionedFriends,
      topic: topic ?? this.topic,
      visibility: visibility ?? this.visibility,
      createdAt: createdAt ?? this.createdAt,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userPhoto: userPhoto ?? this.userPhoto,
      userEmail: userEmail ?? this.userEmail,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      shares: shares ?? this.shares,
    );
  }

  @override
  String toString() {
    return 'Post{id: $id, title: $title, userName: $userName, city: $city, images: ${images.length}, likes: $likes}';
  }

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