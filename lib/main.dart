import 'package:flutter/material.dart';

import 'modules/landmark/landmark_page.dart';
import 'modules/guide/guide_page.dart';
import 'modules/dashboard/dashboard_page.dart';
import 'modules/interaction/interaction_page.dart';
import 'modules/settings/settings_page.dart';

void main() {
  runApp(const GoTripApp());
}

class GoTripApp extends StatelessWidget {
  const GoTripApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GoTrip FYP',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MainNavigation(),
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    LandmarkPage(),
    GuidePage(),
    DashboardPage(),
    InteractionPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_alt),
            label: 'Landmark',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Guide',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.forum),
            label: 'Post',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
