class UserProfile {
  final String uid;
  final String username;
  final String bio;
  final String profileImageUrl;
  final String backgroundImageUrl;
  final int postCount;
  final int favouriteCount;

  UserProfile({
    required this.uid,
    required this.username,
    required this.bio,
    required this.profileImageUrl,
    required this.backgroundImageUrl,
    this.postCount = 0,
    this.favouriteCount = 0,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map, String uid) {
    return UserProfile(
      uid: uid,
      username: map['username'] ?? '',
      bio: map['bio'] ?? '',
      profileImageUrl: map['profileImageUrl'] ?? '',
      backgroundImageUrl: map['backgroundImageUrl'] ?? '',
      postCount: map['postCount'] ?? 0,
      favouriteCount: map['favouriteCount'] ?? 0,
    );
  }

  // 转换为 Map 以便存储到 Firestore
  Map<String, dynamic> toMap() {
    return {
      'username': username,
      'bio': bio,
      'profileImageUrl': profileImageUrl,
      'backgroundImageUrl': backgroundImageUrl,
      'postCount': postCount,
      'favouriteCount': favouriteCount,
    };
  }

  UserProfile copyWith({
    String? username,
    String? bio,
    String? profileImageUrl,
    String? backgroundImageUrl,
    int? postCount,
    int? favouriteCount,
  }) {
    return UserProfile(
      uid: this.uid,
      username: username ?? this.username,
      bio: bio ?? this.bio,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      backgroundImageUrl: backgroundImageUrl ?? this.backgroundImageUrl,
      postCount: postCount ?? this.postCount,
      favouriteCount: favouriteCount ?? this.favouriteCount,
    );
  }
}