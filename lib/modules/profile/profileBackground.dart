import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../models/userModel.dart';
import '../../services/user_service.dart';

class ProfileBackgroundWidget extends StatefulWidget {
  const ProfileBackgroundWidget({super.key});

  @override
  State<ProfileBackgroundWidget> createState() =>
      _ProfileBackgroundWidgetState();
}

class _ProfileBackgroundWidgetState extends State<ProfileBackgroundWidget> {
  final UserService _userService = UserService();
  late final Stream<UserProfile?> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _userService.getCurrentUserProfileStream();
  }

  ImageProvider _getImageProvider(String imageUrl, String defaultAsset) {
    if (imageUrl.isEmpty) return AssetImage(defaultAsset);
    if (imageUrl.startsWith('data:image')) {
      Uint8List bytes = base64Decode(imageUrl.split(',')[1]);
      return MemoryImage(bytes);
    }
    if (imageUrl.startsWith('http')) return NetworkImage(imageUrl);
    return AssetImage(defaultAsset);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfile?>(
      stream: _stream,
      builder: (context, snapshot) {
        final userProfile = snapshot.data;
        if (userProfile == null) return const SizedBox();
        return Container(
          height: 200,
          width: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(
              image: _getImageProvider(
                userProfile.backgroundImageUrl,
                'assets/images/longbg1.jpg',
              ),
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }
}