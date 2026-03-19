import 'dart:ui';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'barSwap.dart';
import 'postWidget.dart';
import 'historyWidget.dart';
import 'userModel.dart';
import '../../services/user_service.dart';
import 'editProfile.dart';
import 'profileInfo.dart';
import 'profileBackground.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final UserService _userService = UserService();
  late final Stream<UserProfile?> _stream;

  bool showProfile = true;
  int _currentIndex = 0;

  // ✅ 只创建一次
  final List<Widget> _tabs = const [
    postWidget(),
    HistoryWidget(),
  ];

  @override
  void initState() {
    super.initState();
    // ✅ stream 缓存在这里，整个生命周期只订阅一次
    _stream = _userService.getCurrentUserProfileStream();
  }

  void zoomProfile() {
    setState(() => showProfile = !showProfile);
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

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;

    return SafeArea(
      child: Scaffold(
        body: showProfile
            ? _buildProfileView(height)
            : _buildZoomView(height),
      ),
    );
  }

  // ── 正常视图 ──────────────────────────────────────────────────────────────
  Widget _buildProfileView(double height) {
    return Stack(
      children: [
        // 背景图片
        const ProfileBackgroundWidget(),

        // 渐变遮罩
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, Colors.white],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, .2],
            ),
          ),
        ),

        // 主内容
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(
                bottom: kBottomNavigationBarHeight + 16),
            child: Column(
              children: [
                SizedBox(height: height * 0.13),

                // ✅ 独立 widget，ProfilePage 的 setState 完全不影响它
                ProfileInfoWidget(onZoom: zoomProfile),

                SizedBox(height: height * 0.03),

                // ✅ tab 切换只重建这部分
                BarSwap(
                  key: const ValueKey('barswap'),
                  selectedIndex: _currentIndex,
                  onTabChanged: (index) {
                    setState(() => _currentIndex = index);
                  },
                ),

                SizedBox(height: height * 0.02),

                IndexedStack(
                  index: _currentIndex,
                  children: _tabs,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 放大头像视图 ──────────────────────────────────────────────────────────
  Widget _buildZoomView(double height) {
    return InkWell(
      onTap: zoomProfile,
      child: StreamBuilder<UserProfile?>(
        stream: _stream, // ✅ 用缓存的 stream
        builder: (context, snapshot) {
          final userProfile = snapshot.data;
          if (userProfile == null) return const SizedBox();

          return Stack(
            children: [
              Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: _getImageProvider(
                      userProfile.profileImageUrl,
                      'assets/images/profile.jpg',
                    ),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.white],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, .2],
                  ),
                ),
              ),
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  height: height,
                  color: Colors.white.withOpacity(0.3),
                  child: Center(
                    child: CircleAvatar(
                      radius: 120,
                      backgroundImage: _getImageProvider(
                        userProfile.profileImageUrl,
                        'assets/images/profile.jpg',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}