// ════════════════════════════════════════════════════════════════
// 文件: models/postModel.dart
// 改动: Post class — 在已有的 placeId / placeTypes 基础上，
//       新增 sentimentScore / sentimentLabel / sentimentMatchedTokens
//       / sentimentAnalyzedAt 字段
//
// 这是完整文件，直接整份替换你现在的 postModel.dart 即可
// （interaction 区块和 profile 区块两处都要替换成一样的内容）
// ════════════════════════════════════════════════════════════════

import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/sentiment_service.dart';

class Post {
  final String? id;
  final String title;
  final String content;
  final List<String> images;
  final List<String> videoPaths;
  final int rating;
  final bool isAnonymous;
  final bool allowComments;
  final bool allowShare;
  final String? location;
  final String? city;
  final double? locationLat;
  final double? locationLng;

  // ── Layer 1: place linkage (added earlier) ──────────────────
  final String? placeId;          // Google Place ID，null = 没选地点
  final List<String> placeTypes;  // 该地点的 Google types

  // ── Sentiment analysis fields (new) ──────────────────────────
  // null = 还没分析完成（刚发布，后台任务还没跑完）或本来就没文字内容
  final double? sentimentScore;        // 0.0~1.0，连续值，给推荐算法用
  final SentimentLabel? sentimentLabel; // positive/neutral/negative，给 UI 展示用
  final int? sentimentMatchedTokens;   // 命中了多少个情感词，用作可信度参考
  final DateTime? sentimentAnalyzedAt; // 分析完成时间戳

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
    this.videoPaths = const [],
    this.rating = 0,
    this.isAnonymous = false,
    this.allowComments = true,
    this.allowShare = true,
    this.location,
    this.city,
    this.locationLat,
    this.locationLng,
    this.placeId,
    this.placeTypes = const [],
    this.sentimentScore,           // ★ 新增
    this.sentimentLabel,           // ★ 新增
    this.sentimentMatchedTokens,   // ★ 新增
    this.sentimentAnalyzedAt,      // ★ 新增
    this.tags = const [],
    this.mentionedFriends = const [],
    this.topic,
    this.visibility = 'public',
    this.createdAt,
    required this.userId,
    required this.userName,
    this.userPhoto,
    this.userEmail,
    this.likes = 0,
    this.comments = 0,
    this.shares = 0,
  });

  // ──────────────────────────────────────────────────────
  factory Post.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    String userName = 'Unknown User';
    if (data['userName'] != null && data['userName'].toString().isNotEmpty) {
      userName = data['userName'];
    } else if (data['userEmail'] != null) {
      userName = data['userEmail'].toString().split('@')[0];
    } else if (data['userId'] != null) {
      userName = 'User_${data['userId'].toString().substring(0, 8)}';
    }

    final rawImages = data['images'] ?? data['imagePaths'] ?? [];

    return Post(
      id: doc.id,
      title: data['title'] ?? '',
      content: data['content'] ?? '',
      images: List<String>.from(rawImages),
      videoPaths: List<String>.from(data['videoPaths'] ?? []),
      rating: data['rating'] ?? 0,
      isAnonymous: data['isAnonymous'] ?? false,
      allowComments: data['allowComments'] ?? true,
      allowShare: data['allowShare'] ?? true,
      location: data['location'],
      city: data['city'],
      locationLat: (data['locationLat'] as num?)?.toDouble(),
      locationLng: (data['locationLng'] as num?)?.toDouble(),
      placeId: data['placeId'],
      placeTypes: List<String>.from(data['placeTypes'] ?? <String>[]),

      // ★ 新增：从 Firestore 读取 sentiment 字段
      sentimentScore: (data['sentimentScore'] as num?)?.toDouble(),
      sentimentLabel: data['sentimentLabel'] != null
          ? SentimentLabelX.fromJson(data['sentimentLabel'] as String?)
          : null,
      sentimentMatchedTokens: (data['sentimentMatchedTokens'] as num?)?.toInt(),
      sentimentAnalyzedAt:
          (data['sentimentAnalyzedAt'] as Timestamp?)?.toDate(),

      tags: List<String>.from(data['tags'] ?? []),
      mentionedFriends: List<String>.from(data['mentionedFriends'] ?? []),
      topic: data['topic'],
      visibility: data['visibility'] ?? 'public',
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

  // ──────────────────────────────────────────────────────
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'content': content,
      'images': images,
      'videoPaths': videoPaths,
      'rating': rating,
      'isAnonymous': isAnonymous,
      'allowComments': allowComments,
      'allowShare': allowShare,
      'location': location,
      'city': city,
      'locationLat': locationLat,
      'locationLng': locationLng,
      'placeId': placeId,
      'placeTypes': placeTypes,

      // ★ 新增：写入 Firestore。注意：发帖瞬间这些都是 null
      // （因为分析是异步后台跑的），等分析完成后会用 .update() 单独补上
      'sentimentScore': sentimentScore,
      'sentimentLabel': sentimentLabel?.toJson(),
      'sentimentMatchedTokens': sentimentMatchedTokens,
      'sentimentAnalyzedAt': sentimentAnalyzedAt != null
          ? Timestamp.fromDate(sentimentAnalyzedAt!)
          : null,

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

  // ──────────────────────────────────────────────────────
  Post copyWith({
    String? id,
    String? title,
    String? content,
    List<String>? images,
    List<String>? videoPaths,
    int? rating,
    bool? isAnonymous,
    bool? allowComments,
    bool? allowShare,
    String? location,
    String? city,
    String? placeId,
    List<String>? placeTypes,
    double? sentimentScore,            // ★ 新增
    SentimentLabel? sentimentLabel,    // ★ 新增
    int? sentimentMatchedTokens,       // ★ 新增
    DateTime? sentimentAnalyzedAt,     // ★ 新增
    double? locationLat,               // ★ 新增
    double? locationLng,               // ★ 新增
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
      videoPaths: videoPaths ?? this.videoPaths,
      rating: rating ?? this.rating,
      isAnonymous: isAnonymous ?? this.isAnonymous,
      allowComments: allowComments ?? this.allowComments,
      allowShare: allowShare ?? this.allowShare,
      location: location ?? this.location,
      city: city ?? this.city,
      placeId: placeId ?? this.placeId,
      placeTypes: placeTypes ?? this.placeTypes,
      sentimentScore: sentimentScore ?? this.sentimentScore,
      sentimentLabel: sentimentLabel ?? this.sentimentLabel,
      sentimentMatchedTokens:
          sentimentMatchedTokens ?? this.sentimentMatchedTokens,
      sentimentAnalyzedAt: sentimentAnalyzedAt ?? this.sentimentAnalyzedAt,
      locationLat: locationLat ?? this.locationLat,
      locationLng: locationLng ?? this.locationLng,
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

  // ── Helpers ──────────────────────────────────────────────
  bool get isLinkedToPlace => placeId != null && placeId!.isNotEmpty;

  /// True once the background sentiment job has finished for this post.
  bool get hasSentimentResult => sentimentLabel != null;

  bool get hasNetworkImages =>
      images.isNotEmpty && images.first.startsWith('http');

  @override
  String toString() =>
      'Post{id: $id, title: $title, userName: $userName, city: $city, '
      'placeId: $placeId, sentiment: ${sentimentLabel?.toJson()}, '
      'images: ${images.length}, likes: $likes}';

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