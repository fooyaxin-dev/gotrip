import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'modules/guide/guidePage.dart';
import 'modules/dashboard/dashboard_page.dart';
import 'modules/profile/profile.dart';
import 'modules/interaction/interaction_page.dart';
import 'modules/landmark/landmarkFAB.dart';
import 'logout.dart';
import 'modules/main/mainpage.dart';


class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  String _username = "UserName";
  String _email = "user@email.com";

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
  final prefs = await SharedPreferences.getInstance();
  String cachedUsername = prefs.getString('username') ?? "";
  String cachedEmail = prefs.getString('email') ?? "";

  // 先显示缓存
  setState(() {
    _username = cachedUsername.isEmpty ? "UserName" : cachedUsername;
    _email = cachedEmail.isEmpty ? "user@email.com" : cachedEmail;
  });

  // 再去 Firestore 拿最新
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
  if (doc.exists) {
    final latestUsername = doc.data()?['username'] ?? _username;
    final latestEmail = doc.data()?['email'] ?? _email;

    setState(() {
      _username = latestUsername;
      _email = latestEmail;
    });

    // 更新缓存
    prefs.setString('username', latestUsername);
    prefs.setString('email', latestEmail);
  }
}

  @override
  Widget build(BuildContext context) {

      final pages = [
      MainPage(username: _username),
      const RealTimeGuidePage(),
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
            const SizedBox(width: 40), // FAB 空位
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
                const CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.white,
                  child: Icon(Icons.person, size: 32, color: Color(0xFF6366F1)),
                ),
                const SizedBox(width: 15),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_username,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(_email,
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
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
              Navigator.pop(context); // 关 Drawer
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
              Navigator.pop(context); // 关 Drawer
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DashboardPage(),
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

