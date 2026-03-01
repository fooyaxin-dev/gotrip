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
  UserProfile? _userProfile;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  // 加载用户资料
  Future<void> _loadUserProfile() async {
    setState(() {
      _isLoading = true;
    });

    UserProfile? profile = await _userService.getCurrentUserProfile();
    
    setState(() {
      _userProfile = profile;
      _isLoading = false;
    });
  }

  void zoomProfile() {
    setState(() {
      showProfile = !showProfile;
    });
  }

  // 跳转到编辑页面
  Future<void> _navigateToEditProfile() async {
    if (_userProfile == null) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EditProfilePage(userProfile: _userProfile!),
      ),
    );

    // 如果编辑成功，重新加载数据
    if (result == true) {
      _loadUserProfile();
    }
  }

  // 从 Base64 字符串创建 ImageProvider
  ImageProvider _getImageProvider(String imageUrl, String defaultAsset) {
    if (imageUrl.isEmpty) {
      return AssetImage(defaultAsset);
    }
    
    // 检查是否是 Base64 图片
    if (imageUrl.startsWith('data:image')) {
      // 提取 Base64 部分
      String base64String = imageUrl.split(',')[1];
      Uint8List bytes = base64Decode(base64String);
      return MemoryImage(bytes);
    }
    
    // 如果是 URL（未来可能用）
    if (imageUrl.startsWith('http')) {
      return NetworkImage(imageUrl);
    }
    
    // 默认
    return AssetImage(defaultAsset);
  }

  @override
  Widget build(BuildContext context) {
    var height = MediaQuery.of(context).size.height;

    // 显示加载指示器
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    // 如果没有用户数据，显示错误
    if (_userProfile == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('无法加载用户资料'),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _loadUserProfile,
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
                  //1 背景图片
                  Container(
                    height: 200,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: _getImageProvider(
                          _userProfile!.backgroundImageUrl,
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

                  //2 主要内容
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: kBottomNavigationBarHeight + 16),
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
                                    _userProfile!.profileImageUrl,
                                    'assets/images/profile.jpg',
                                  ),
                                ),
                              ),
                            ),
                          ),

                          SizedBox(height: height * 0.02),

                          // 用户名
                          Text(
                            _userProfile!.username.isNotEmpty
                                ? '@${_userProfile!.username}'
                                : '@YAxin',
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                            ),
                          ),

                          // 个人简介
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 30.0, right: 30.0, top: 10),
                            child: Text(
                              _userProfile!.bio.isNotEmpty ? _userProfile!.bio : 'Bio',
                              style: TextStyle(
                                fontSize: 15,
                                color: Colors.grey.shade400,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),

                          SizedBox(height: height * 0.02),

                          // 编辑按钮
                          ElevatedButton.icon(
                            onPressed: _navigateToEditProfile,
                            icon: const Icon(Icons.edit, size: 18),
                            label: const Text('编辑资料'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                          ),

                          SizedBox(height: height * 0.02),

                          _totalPostwithHistory(),

                          SizedBox(height: height * 0.03),

                          BarSwap(
                            onTabChanged: (index) {
                              setState(() {
                                _currentIndex = index;
                              });
                            },
                          ),

                          SizedBox(height: height * 0.02),

                          // 根据选中的tab显示不同内容
                          _currentIndex == 0 ? const postWidget() : const historyWidget(),
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
                    //1 背景
                    Container(
                      height: 200,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        image: DecorationImage(
                          image: _getImageProvider(
                            _userProfile!.profileImageUrl,
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

                    //2 内容
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
                                    _userProfile!.profileImageUrl,
                                    'assets/images/profile.jpg',
                                  ),
                                ),
                              ),
                            ),

                            SizedBox(height: height * 0.02),

                            Text(
                              _userProfile!.username.isNotEmpty
                                  ? '@${_userProfile!.username}'
                                  : '@YAxin',
                              style: const TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),

                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 30.0, right: 30.0, top: 10),
                              child: Text(
                                _userProfile!.bio.isNotEmpty ? _userProfile!.bio : 'Bio',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: Colors.grey.shade400,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),

                            SizedBox(height: height * 0.05),

                            _totalPostwithHistory(),

                            SizedBox(height: height * 0.03),

                            BarSwap(
                              onTabChanged: (index) {
                                setState(() {
                                  _currentIndex = index;
                                });
                              },
                            ),

                            SizedBox(height: height * 0.02),

                            _currentIndex == 0 ? const postWidget() : const historyWidget(),
                          ],
                        ),
                      ),
                    ),

                    // 模糊效果和放大头像
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        height: height,
                        // ignore: deprecated_member_use
                        color: Colors.white.withOpacity(0.3),
                        child: Center(
                          child: CircleAvatar(
                            radius: 120,
                            backgroundImage: _getImageProvider(
                              _userProfile!.profileImageUrl,
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
  }

  Widget _totalPostwithHistory() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Column(
          children: [
            const Text(
              'Post',
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6.0),
              child: Text(
                '${_userProfile!.postCount}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        Column(
          children: [
            const Text(
              'Favourite',
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6.0),
              child: Text(
                '${_userProfile!.favouriteCount}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        Column(
          children: [
            const Text(
              'Route',
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6.0),
              child: Text(
                '${_userProfile!.routeCount}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        )
      ],
    );
  }

  
}