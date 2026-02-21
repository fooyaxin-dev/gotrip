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
  String _profileImageUrl = ""; // ⭐ 新增：存储头像

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    String cachedUsername = prefs.getString('username') ?? "";
    String cachedEmail = prefs.getString('email') ?? "";
    String cachedProfileImage = prefs.getString('profileImageUrl') ?? ""; // ⭐ 读取缓存的头像

    // 先显示缓存
    setState(() {
      _username = cachedUsername.isEmpty ? "UserName" : cachedUsername;
      _email = cachedEmail.isEmpty ? "user@email.com" : cachedEmail;
      _profileImageUrl = cachedProfileImage; // ⭐ 设置头像
    });

    // 再去 Firestore 拿最新
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (doc.exists) {
      final latestUsername = doc.data()?['username'] ?? _username;
      final latestEmail = doc.data()?['email'] ?? _email;
      final latestProfileImage = doc.data()?['profileImageUrl'] ?? ""; // ⭐ 读取头像

      setState(() {
        _username = latestUsername;
        _email = latestEmail;
        _profileImageUrl = latestProfileImage; // ⭐ 更新头像
      });

      // 更新缓存
      prefs.setString('username', latestUsername);
      prefs.setString('email', latestEmail);
      prefs.setString('profileImageUrl', latestProfileImage); // ⭐ 缓存头像
    }
  }

  // ⭐ 新增：从 Base64 或 URL 获取 ImageProvider
  ImageProvider _getProfileImageProvider() {
    if (_profileImageUrl.isEmpty) {
      // 没有头像，返回默认图标
      return const AssetImage('assets/images/profile.jpg');
    }

    // 检查是否是 Base64 图片
    if (_profileImageUrl.startsWith('data:image')) {
      try {
        // 提取 Base64 部分
        String base64String = _profileImageUrl.split(',')[1];
        Uint8List bytes = base64Decode(base64String);
        return MemoryImage(bytes);
      } catch (e) {
        print('❌ Base64 解码失败: $e');
        return const AssetImage('assets/images/profile.jpg');
      }
    }

    // 如果是 URL（未来可能用）
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
                // ⭐ 修改：使用数据库中的头像
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.white,
                  child: CircleAvatar(
                    radius: 26,
                    backgroundImage: _getProfileImageProvider(),
                    // 如果图片加载失败，显示默认图标
                    onBackgroundImageError: (exception, stackTrace) {
                      print('❌ 头像加载失败: $exception');
                    },
                    child: _profileImageUrl.isEmpty
                        ? const Icon(Icons.person, size: 32, color: Color(0xFF6366F1))
                        : null, // 有头像时不显示图标
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