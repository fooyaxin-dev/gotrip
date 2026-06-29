import 'package:cloud_firestore/cloud_firestore.dart';

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
  final List<String> tags;
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
    this.tags = const [],
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
      id:               doc.id,
      title:            data['title']           ?? '',
      content:          data['content']         ?? '',
      images:           List<String>.from(rawImages),
      videoPaths:       List<String>.from(data['videoPaths']       ?? []),
      rating:           data['rating']          ?? 0,
      isAnonymous:      data['isAnonymous']     ?? false,
      allowComments:    data['allowComments']   ?? true,
      allowShare:       data['allowShare']      ?? true,
      location:         data['location'],
      city:             data['city'],
      locationLat:      (data['locationLat'] as num?)?.toDouble(),  // ← 新增
      locationLng:      (data['locationLng'] as num?)?.toDouble(),  // ← 新增
      tags:             List<String>.from(data['tags']             ?? []),
      topic:            data['topic'],
      visibility:       data['visibility']      ?? 'public',
      createdAt:        (data['createdAt'] as Timestamp?)?.toDate(),
      userId:           data['userId']          ?? '',
      userName:         userName,
      userPhoto:        data['userPhoto'],
      userEmail:        data['userEmail'],
      likes:            data['likes']           ?? 0,
      comments:         data['comments']        ?? 0,
      shares:           data['shares']          ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title':            title,
      'content':          content,
      'images':           images,
      'rating':           rating,
      'isAnonymous':      isAnonymous,
      'allowComments':    allowComments,
      'allowShare':       allowShare,
      'location':         location,
      'city':             city,
      'locationLat':      locationLat,   // ← 新增
      'locationLng':      locationLng,   // ← 新增
      'tags':             tags,
      'topic':            topic,
      'visibility':       visibility,
      'createdAt':        createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
      'userId':           userId,
      'userName':         userName,
      'userPhoto':        userPhoto,
      'userEmail':        userEmail,
      'likes':            likes,
      'comments':         comments,
      'shares':           shares,
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
    String? city,
    double? locationLat,   // ← 新增
    double? locationLng,   // ← 新增
    List<String>? tags,
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
      id:               id               ?? this.id,
      title:            title            ?? this.title,
      content:          content          ?? this.content,
      images:           images           ?? this.images,
      rating:           rating           ?? this.rating,
      isAnonymous:      isAnonymous      ?? this.isAnonymous,
      allowComments:    allowComments    ?? this.allowComments,
      allowShare:       allowShare       ?? this.allowShare,
      location:         location         ?? this.location,
      city:             city             ?? this.city,
      locationLat:      locationLat      ?? this.locationLat,   
      locationLng:      locationLng      ?? this.locationLng,   
      tags:             tags             ?? this.tags,
      topic:            topic            ?? this.topic,
      visibility:       visibility       ?? this.visibility,
      createdAt:        createdAt        ?? this.createdAt,
      userId:           userId           ?? this.userId,
      userName:         userName         ?? this.userName,
      userPhoto:        userPhoto        ?? this.userPhoto,
      userEmail:        userEmail        ?? this.userEmail,
      likes:            likes            ?? this.likes,
      comments:         comments         ?? this.comments,
      shares:           shares           ?? this.shares,
    );
  }

  bool get hasNetworkImages =>
      images.isNotEmpty && images.first.startsWith('http');

  @override
  String toString() =>
      'Post{id: $id, title: $title, userName: $userName, city: $city, lat: $locationLat, lng: $locationLng, images: ${images.length}, likes: $likes}';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Post && other.id == id && other.title == title && other.userId == userId;
  }

  @override
  int get hashCode => id.hashCode ^ title.hashCode ^ userId.hashCode;
}