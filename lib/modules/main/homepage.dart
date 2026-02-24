import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../realtime/detectPlacePage.dart';
import '../dashboard/dashboard_page.dart';
import '../profile/profile.dart';
import '../interaction/interactionPage.dart';
import '../landmark/landmarkFAB.dart';
import '../login_logout/logout.dart';
import 'mainpage.dart';
import 'favourite.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  String _username = "UserName";
  String _email = "user@email.com";
  String _profileImageUrl = "";
  StreamSubscription? _userSubscription; // ⭐ 实时监听订阅

  @override
  void initState() {
    super.initState();
    _loadCachedData();   // 先加载缓存，加快首屏显示
    _listenToUserData(); // 再监听 Firestore 实时更新
  }

  @override
  void dispose() {
    _userSubscription?.cancel(); // ⭐ 页面销毁时取消监听，防止内存泄漏
    super.dispose();
  }

  // 先从本地缓存加载，加快首屏速度
  Future<void> _loadCachedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('username') ?? "UserName";
      _email = prefs.getString('email') ?? "user@email.com";
      _profileImageUrl = prefs.getString('profileImageUrl') ?? "";
    });
  }

  // ⭐ 实时监听 Firestore，数据库一有变化，UI 立即自动更新
  void _listenToUserData() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _userSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots() // 用 snapshots() 实时监听，替代 get()
        .listen((doc) async {
      if (doc.exists) {
        final data = doc.data()!;
        final latestUsername = data['username'] ?? _username;
        final latestEmail = data['email'] ?? _email;
        final latestProfileImage = data['profileImageUrl'] ?? "";

        setState(() {
          _username = latestUsername;
          _email = latestEmail;
          _profileImageUrl = latestProfileImage;
        });

        // 同步更新本地缓存
        final prefs = await SharedPreferences.getInstance();
        prefs.setString('username', latestUsername);
        prefs.setString('email', latestEmail);
        prefs.setString('profileImageUrl', latestProfileImage);
      }
    });
  }

  // 从 Base64 或 URL 获取 ImageProvider
  ImageProvider _getProfileImageProvider() {
    if (_profileImageUrl.isEmpty) {
      return const AssetImage('assets/images/profile.jpg');
    }

    // 检查是否是 Base64 图片
    if (_profileImageUrl.startsWith('data:image')) {
      try {
        String base64String = _profileImageUrl.split(',')[1];
        Uint8List bytes = base64Decode(base64String);
        return MemoryImage(bytes);
      } catch (e) {
        print('❌ Base64 解码失败: $e');
        return const AssetImage('assets/images/profile.jpg');
      }
    }

    // 如果是 URL
    if (_profileImageUrl.startsWith('http')) {
      return NetworkImage(_profileImageUrl);
    }

    // 默认
    return const AssetImage('assets/images/profile.jpg');
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      MainPage(username: _username),
      RealTimeDetectPage(onBack: () {
        setState(() => _currentIndex = 0);
      }),
      const SizedBox(),
      const InteractionPage(),
      const ProfilePage(),
    ];

    return Scaffold(
      extendBody: true,
      drawer: _buildAppDrawer(context),
      body: pages[_currentIndex],
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const LandmarkFAB(),
            ),
          );
        },
        backgroundColor: const Color(0xFF6366F1),
        shape: const CircleBorder(),
        elevation: 6,
        child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 28),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        height: 65,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        color: Colors.white,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildNavItem(Icons.home_rounded, "Home", 0),
            _buildNavItem(Icons.explore_rounded, "Guide", 1),
            const SizedBox(width: 40),
            _buildNavItem(Icons.forum_rounded, "Hub", 3),
            _buildNavItem(Icons.person_rounded, "Profile", 4),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    bool isSelected = _currentIndex == index;
    return InkWell(
      onTap: () => setState(() => _currentIndex = index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isSelected ? const Color(0xFF6366F1) : Colors.blueGrey.shade300),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? const Color(0xFF6366F1) : Colors.blueGrey.shade300,
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppDrawer(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 50, 20, 20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF4F46E5), Color(0xFF818CF8)],
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.white,
                  child: CircleAvatar(
                    radius: 26,
                    backgroundImage: _getProfileImageProvider(),
                    onBackgroundImageError: (exception, stackTrace) {
                      print('❌ 头像加载失败: $exception');
                    },
                    child: _profileImageUrl.isEmpty
                        ? const Icon(Icons.person, size: 32, color: Color(0xFF6366F1))
                        : null,
                  ),
                ),
                const SizedBox(width: 15),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _username,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _email,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 15),

          ListTile(
            leading: const Icon(Icons.dashboard_rounded),
            title: const Text("Landmark Recognition"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LandmarkFAB(),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.dashboard_rounded),
            title: const Text("Dashboard"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DashboardPage(),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.dashboard_rounded),
            title: const Text("Favourite"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const FavouritePage(),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.settings_rounded),
            title: const Text("Settings"),
            onTap: () {},
          ),

          const Spacer(),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: const Text("Logout"),
            onTap: () => AuthService.logout(context),
          ),
        ],
      ),
    );
  }
}