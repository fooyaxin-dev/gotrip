import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'userModel.dart';
import '../../services/user_service.dart';
import 'editProfile.dart';

class ProfileInfoWidget extends StatefulWidget {
  final VoidCallback onZoom;
  const ProfileInfoWidget({super.key, required this.onZoom});

  @override
  State<ProfileInfoWidget> createState() => _ProfileInfoWidgetState();
}

class _ProfileInfoWidgetState extends State<ProfileInfoWidget> {
  final UserService _userService = UserService();
  late final Stream<UserProfile?> _stream;

  @override
  void initState() {
    super.initState();
    // ✅ 只创建一次，不会重复订阅
    _stream = _userService.getCurrentUserProfileStream();
  }

  ImageProvider _getImageProvider(String imageUrl, String defaultAsset) {
    if (imageUrl.isEmpty) return AssetImage(defaultAsset);
    if (imageUrl.startsWith('data:image')) {
      String base64String = imageUrl.split(',')[1];
      Uint8List bytes = base64Decode(base64String);
      return MemoryImage(bytes);
    }
    if (imageUrl.startsWith('http')) return NetworkImage(imageUrl);
    return AssetImage(defaultAsset);
  }

  Future<void> _navigateToEditProfile(UserProfile userProfile) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EditProfilePage(userProfile: userProfile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;

    return StreamBuilder<UserProfile?>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final userProfile = snapshot.data;
        if (userProfile == null) return const SizedBox();

        return Column(
          children: [
            // 头像
            CircleAvatar(
              backgroundColor: Colors.orange,
              radius: 47,
              child: CircleAvatar(
                backgroundColor: Colors.white,
                radius: 45,
                child: InkWell(
                  onTap: widget.onZoom,
                  child: CircleAvatar(
                    radius: 43,
                    backgroundImage: _getImageProvider(
                      userProfile.profileImageUrl,
                      'assets/images/profile.jpg',
                    ),
                  ),
                ),
              ),
            ),

            SizedBox(height: height * 0.02),

            Text(
              userProfile.username.isNotEmpty
                  ? '@${userProfile.username}'
                  : '@YAxin',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),

            Padding(
              padding:
                  const EdgeInsets.only(left: 30.0, right: 30.0, top: 10),
              child: Text(
                userProfile.bio.isNotEmpty ? userProfile.bio : 'Bio',
                style:
                    TextStyle(fontSize: 15, color: Colors.grey.shade400),
                textAlign: TextAlign.center,
              ),
            ),

            SizedBox(height: height * 0.02),

            ElevatedButton.icon(
              onPressed: () => _navigateToEditProfile(userProfile),
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('Edit Profile'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),

            SizedBox(height: height * 0.02),

            // 统计数字
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _statColumn('Post', '${userProfile.postCount}'),
                _statColumn('Favourite', '${userProfile.favouriteCount}'),
                _statColumn('Route', '${userProfile.routeCount}'),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _statColumn(String label, String value) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(fontSize: 15, color: Colors.grey)),
        Padding(
          padding: const EdgeInsets.only(top: 6.0),
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ),
      ],
    );
  }
}