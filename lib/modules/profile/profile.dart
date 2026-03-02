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

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final UserService _userService = UserService();

  bool showProfile = true;
  int _currentIndex = 0;

  void zoomProfile() {
    setState(() {
      showProfile = !showProfile;
    });
  }

  Future<void> _navigateToEditProfile(UserProfile userProfile) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EditProfilePage(userProfile: userProfile),
      ),
    );
    // Stream 会自动更新，不需要手动 reload
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
    var height = MediaQuery.of(context).size.height;

    // ✅ 用 StreamBuilder 实时监听，favouriteCount 变化自动更新
    return StreamBuilder<UserProfile?>(
      stream: _userService.getCurrentUserProfileStream(),
      builder: (context, snapshot) {
        // 加载中
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // 出错或没有数据
        final userProfile = snapshot.data;
        if (userProfile == null) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('无法加载用户资料'),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () => setState(() {}),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          child: Scaffold(
            body: showProfile
                ? Stack(
                    children: [
                      // 背景图片
                      Container(
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

                      // 主要内容
                      Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(
                              bottom: kBottomNavigationBarHeight + 16),
                          child: Column(
                            children: [
                              SizedBox(height: height * 0.13),

                              // 头像
                              CircleAvatar(
                                backgroundColor: Colors.orange,
                                radius: 47,
                                child: CircleAvatar(
                                  backgroundColor: Colors.white,
                                  radius: 45,
                                  child: InkWell(
                                    onTap: zoomProfile,
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

                              // 用户名
                              Text(
                                userProfile.username.isNotEmpty
                                    ? '@${userProfile.username}'
                                    : '@YAxin',
                                style: const TextStyle(
                                    fontSize: 16, color: Colors.grey),
                              ),

                              // 个人简介
                              Padding(
                                padding: const EdgeInsets.only(
                                    left: 30.0, right: 30.0, top: 10),
                                child: Text(
                                  userProfile.bio.isNotEmpty
                                      ? userProfile.bio
                                      : 'Bio',
                                  style: TextStyle(
                                      fontSize: 15,
                                      color: Colors.grey.shade400),
                                  textAlign: TextAlign.center,
                                ),
                              ),

                              SizedBox(height: height * 0.02),

                              // 编辑按钮
                              ElevatedButton.icon(
                                onPressed: () =>
                                    _navigateToEditProfile(userProfile),
                                icon: const Icon(Icons.edit, size: 18),
                                label: const Text('编辑资料'),
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

                              _totalPostwithHistory(userProfile),

                              SizedBox(height: height * 0.03),

                              BarSwap(
                                onTabChanged: (index) {
                                  setState(() => _currentIndex = index);
                                },
                              ),

                              SizedBox(height: height * 0.02),

                              _currentIndex == 0
                                  ? const postWidget()
                                  : const historyWidget(),
                            ],
                          ),
                        ),
                      )
                    ],
                  )

                // 放大头像视图
                : InkWell(
                    onTap: zoomProfile,
                    child: Stack(
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

                        Center(
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                SizedBox(height: height * 0.13),
                                CircleAvatar(
                                  backgroundColor: Colors.orange,
                                  radius: 47,
                                  child: CircleAvatar(
                                    backgroundColor: Colors.white,
                                    radius: 45,
                                    child: CircleAvatar(
                                      radius: 43,
                                      backgroundImage: _getImageProvider(
                                        userProfile.profileImageUrl,
                                        'assets/images/profile.jpg',
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(height: height * 0.02),
                                Text(
                                  userProfile.username.isNotEmpty
                                      ? '@${userProfile.username}'
                                      : '@YAxin',
                                  style: const TextStyle(
                                      fontSize: 16, color: Colors.grey),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(
                                      left: 30.0, right: 30.0, top: 10),
                                  child: Text(
                                    userProfile.bio.isNotEmpty
                                        ? userProfile.bio
                                        : 'Bio',
                                    style: TextStyle(
                                        fontSize: 15,
                                        color: Colors.grey.shade400),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                SizedBox(height: height * 0.05),
                                _totalPostwithHistory(userProfile),
                                SizedBox(height: height * 0.03),
                                BarSwap(
                                  onTabChanged: (index) {
                                    setState(() => _currentIndex = index);
                                  },
                                ),
                                SizedBox(height: height * 0.02),
                                _currentIndex == 0
                                    ? const postWidget()
                                    : const historyWidget(),
                              ],
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
                        )
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  // ✅ userProfile 作为参数传入，不再依赖 _userProfile 状态
  Widget _totalPostwithHistory(UserProfile userProfile) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _statColumn('Post', '${userProfile.postCount}'),
        _statColumn('Favourite', '${userProfile.favouriteCount}'),
        _statColumn('Route', '${userProfile.routeCount}'),
      ],
    );
  }

  Widget _statColumn(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 15, color: Colors.grey),
        ),
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