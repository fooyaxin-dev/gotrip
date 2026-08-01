import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/location_service.dart';
import '../place/detectPlacePage.dart';
import '../dashboard/dashboard_page.dart';
import '../profile/profile.dart';
import '../interaction/interactionPage.dart';
import '../landmark/landmarkFAB.dart';
import '../landmark/landmarkHistory.dart';
import '../login_logout/logout.dart';
import '../settings/settingsPage.dart';
import 'mainpage.dart';
import 'favourite.dart';
import '../itinerary/itineraryPage.dart';
import '../itinerary/itineraryGeneratePage.dart';
import '../../services/userPreference_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  bool _nearbyTabVisited = false; 
  bool _locationTrackingActive = false;
  String _username = "UserName";
  String _email = "user@email.com";
  String _profileImageUrl = "";
  StreamSubscription? _userSubscription;

  @override
  void initState() {
    super.initState();
    _loadCachedData();
    _listenToUserData();
    _syncLocationTracking(); 
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    if (_locationTrackingActive) {
      LocationService.instance.stopTracking(); // 🆕 释放引用
    }
    super.dispose();
  }

  Future<void> _loadCachedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username        = prefs.getString('username')        ?? "UserName";
      _email           = prefs.getString('email')           ?? "user@email.com";
      _profileImageUrl = prefs.getString('profileImageUrl') ?? "";
    });
  }

// 🆕 只有 Home(0) 和 Nearby(1) 这两个 tab 需要"持续更新的实时位置"
  // （Home 用来提示"你移动很远了、附近地点已更新"；Nearby 地图本身
  // 就需要跟手的定位点）。Itinerary(3) 和 Profile(4) 只需要
  // "上一次已知的位置"当快照即可，不需要 GPS 持续跑。
  void _syncLocationTracking() {
    final needsTracking = _currentIndex == 0 || _currentIndex == 1;
    if (needsTracking && !_locationTrackingActive) {
      LocationService.instance.startTracking();
      _locationTrackingActive = true;
    } else if (!needsTracking && _locationTrackingActive) {
      LocationService.instance.stopTracking();
      _locationTrackingActive = false;
    }
  }

  void _listenToUserData() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _userSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((doc) async {
      if (doc.exists) {
        final data             = doc.data()!;
        final latestUsername   = data['username']       ?? _username;
        final latestEmail      = data['email']          ?? _email;
        final latestProfileImg = data['profileImageUrl']?? "";

        setState(() {
          _username        = latestUsername;
          _email           = latestEmail;
          _profileImageUrl = latestProfileImg;
        });

        final prefs = await SharedPreferences.getInstance();
        prefs.setString('username',        latestUsername);
        prefs.setString('email',           latestEmail);
        prefs.setString('profileImageUrl', latestProfileImg);
      }
    });
  }

  ImageProvider _getProfileImageProvider() {
    if (_profileImageUrl.isEmpty) {
      return const AssetImage('assets/images/profile.jpg');
    }
    if (_profileImageUrl.startsWith('data:image')) {
      try {
        final base64String = _profileImageUrl.split(',')[1];
        return MemoryImage(base64Decode(base64String));
      } catch (_) {
        return const AssetImage('assets/images/profile.jpg');
      }
    }
    if (_profileImageUrl.startsWith('http')) {
      return NetworkImage(_profileImageUrl);
    }
    return const AssetImage('assets/images/profile.jpg');
  }

  // ─────────────────────────────────────────────
  // Navigate to generate itinerary
  // ─────────────────────────────────────────────

  int _itineraryReloadKey = 0;

  Future<void> _goGenerateItinerary() async {
    await UserPreferenceService.instance.load();
    if (!mounted) return;
    
    await Navigator.push(  
      context,
      MaterialPageRoute(builder: (_) => const GenerateItineraryPage()),
    );
    
    if (mounted) {
      setState(() => _itineraryReloadKey++);
    }
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    
    final bool isItineraryTab = _currentIndex == 3;

    return Scaffold(
      extendBody: true,
      drawer: _buildAppDrawer(context),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          MainPage(username: _username),
          _nearbyTabVisited
              ? RealTimeDetectPage(onBack: () {
                  setState(() => _currentIndex = 0);
                })
              : const SizedBox(), // ← 沒訪問過就放空的
          const SizedBox(),
          ItineraryPage(
            key: ValueKey(_itineraryReloadKey),
            onBack: () => setState(() => _currentIndex = 0),
            onPlanTrip: _goGenerateItinerary,
          ),
          const ProfilePage(),
        ],
      ),

      floatingActionButtonAnimator: FloatingActionButtonAnimator.scaling,

      // ── Dynamic FAB based on current tab ──
      floatingActionButton: isItineraryTab
          // Itinerary tab → New Trip button (bottom right)
          ? FloatingActionButton.extended(
            key: const ValueKey('newTripFab'), 
              onPressed: _goGenerateItinerary,
              backgroundColor: const Color(0xFF7C4DFF),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('New Trip',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            )
          // Other tabs → Camera button (center docked)
          : FloatingActionButton(
            key: const ValueKey('cameraFab'), 
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LandmarkFAB()),
              ),
              backgroundColor: const Color(0xFF6366F1),
              shape: const CircleBorder(),
              elevation: 6,
              child: const Icon(Icons.camera_alt_rounded,
                  color: Colors.white, size: 28),
            ),

      // ── FAB position changes with tab ──
      floatingActionButtonLocation: isItineraryTab
          ? FloatingActionButtonLocation.endFloat    // New Trip → bottom right
          : FloatingActionButtonLocation.centerDocked, // Camera → center notch

      bottomNavigationBar: BottomAppBar(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        height: 65,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        color: Colors.white,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildNavItem(Icons.home_rounded,    "Home",      0),
            _buildNavItem(Icons.explore_rounded, "Nearby",    1),
            const SizedBox(width: 40), // notch spacer
            _buildNavItem(Icons.book_rounded,    "Itinerary", 3),
            _buildNavItem(Icons.person_rounded,  "Profile",   4),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _currentIndex == index;
   return InkWell(
      onTap: () => setState(() {
        _currentIndex = index;
        if (index == 1) _nearbyTabVisited = true;
        _syncLocationTracking(); // 🆕
      }),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              color: isSelected
                  ? const Color(0xFF6366F1)
                  : Colors.blueGrey.shade300),
          Text(label,
              style: TextStyle(
                color: isSelected
                    ? const Color(0xFF6366F1)
                    : Colors.blueGrey.shade300,
                fontSize: 10,
                fontWeight:
                    isSelected ? FontWeight.bold : FontWeight.normal,
              )),
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
                    onBackgroundImageError: (e, _) =>
                        print('❌ 头像加载失败: $e'),
                    child: _profileImageUrl.isEmpty
                        ? const Icon(Icons.person,
                            size: 32, color: Color(0xFF6366F1))
                        : null,
                  ),
                ),
                const SizedBox(width: 15),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_username,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(_email,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 15),

          ListTile(
            leading: const Icon(Icons.location_on_sharp),
            title: const Text("Landmark Record"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const LandmarkHistoryPage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_rounded),
            title: const Text("Dashboard"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DashboardPage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.favorite_outline_outlined),
            title: const Text("Favourite"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const FavouritePage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.forum_rounded),
            title: const Text("Hub"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const InteractionPage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_rounded),
            title: const Text("Settings"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsPage()));
            },
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