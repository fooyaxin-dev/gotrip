import 'package:flutter/material.dart';
import 'modules/guide/guide_page.dart';
import 'modules/dashboard/dashboard_page.dart';
import 'modules/profile/profile.dart';
import 'modules/interaction/interaction_page.dart';
import 'modules/landmark/landmarkFAB.dart';
import 'bottomnav.dart';


class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const MainPage(),        // 0 - Home
    const RealTimeGuidePage(),       // 1 - Guide
    const SizedBox(),    // 2 - Camera / Scan
    const InteractionPage(), // 3 - Interaction
    const ProfilePage(),     // 4 - Profile
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      drawer: _buildAppDrawer(context),
      
      body: _pages[_currentIndex],

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
            child: const Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.white,
                  child: Icon(Icons.person, size: 32, color: Color(0xFF6366F1)),
                ),
                SizedBox(width: 15),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("User Name",
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    SizedBox(height: 4),
                    Text("user@email.com",
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),

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
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

// ================= MainPage  =================
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {

  late PageController _pageController;

  // ===== 天气状态（假数据）=====
  final String _weatherCondition = "sunny"; // sunny / cloudy / rainy
  final int _temperature = 19;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.8);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ===== 根据天气决定 icon =====
  IconData _getWeatherIcon(String condition) {
    switch (condition) {
      case "cloudy":
        return Icons.cloud_rounded;
      case "rainy":
        return Icons.umbrella_rounded;
      case "sunny":
      default:
        return Icons.wb_sunny_rounded;
    }
  }

  // ===== Category =====

  final List<Map<String, dynamic>> _categories = [
    {
      "label": "All",
      "icon": Icons.grid_view_rounded,        // 全部 / 浏览
      "color": const Color(0xFFCCFBF1),              // Mint
    },
    {
      "label": "Nature",
      "icon": Icons.park_rounded,              // 🌿 自然 / 公园
      "color": const Color(0xFFDCFCE7),              // Soft Green
    },
    {
      "label": "Historical",
      "icon": Icons.account_balance_rounded,   // 🏛️ 历史建筑
      "color": const Color(0xFFFFEDD5),              // Warm Sand
    },
    {
      "label": "Shopping",
      "icon": Icons.shopping_bag_rounded,      // 🛍️ 购物
      "color": const Color(0xFFE0E7FF),              // Indigo Soft
    },
    {
      "label": "Food",
      "icon": Icons.restaurant_rounded,        // 🍴 美食
      "color": const Color(0xFFFFE4E6),              // Rose
    },
    {
      "label": "Entertainment",
      "icon": Icons.local_activity_rounded,    // 🎡 娱乐 / 景点
      "color": const Color(0xFFF3E8FF),              // Purple Soft
    },
  ];

  String _selectedCategory = "All";

  final Map<String, List<String>> _placeByCategory = {
    "All": ["Petronas Twin Towers", "Batu Caves", "KL Tower"],
    "Nature": ["Batu Caves", "Taman Negara", "KL Forest Eco Park"],
    "Historical": ["Sultan Abdul Samad Building", "Merdeka Square"],
    "Shopping": ["Pavilion KL", "Suria KLCC"],
    "Food": ["Jalan Alor", "Lot 10 Hutong"],
    "Entertainment": ["Sunway Lagoon", "Aquaria KLCC"],
  };



@override
Widget build(BuildContext context) {
  return BasePage(
    child: SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          _buildHeader(),
          const SizedBox(height: 25),

          // ---- Category Chips ----
          const SizedBox(height: 20),
          _buildCategorySection(),
          const SizedBox(height: 30),


          _buildSectionHeader("Recommended Places", true),
          const SizedBox(height: 10),
          SizedBox(
            height: 320,
            child: PageView.builder(
              controller: _pageController,
              itemCount: _placeByCategory[_selectedCategory]!.length,

              physics: const BouncingScrollPhysics(),
              itemBuilder: (context, index) {
                return AnimatedBuilder(
                  animation: _pageController,
                  builder: (context, child) {
                    double value = 0;
                    if (_pageController.position.haveDimensions) {
                      value = _pageController.page! - index;
                    }
                    return Transform(
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.001)
                        ..rotateY(value * 0.4)
                        ..scale(1 - (value.abs() * 0.1)),
                      child: child,
                    );
                  },
                  child: _buildPlaceCard(index),
                );
              },
            ),
          ),

          const SizedBox(height: 20),

          _buildSectionHeader("Nearby Trending", false),
          const SizedBox(height: 15),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 25),
            child: Column(
              children: _selectedCategory == "Food"
                  ? [
                      _buildTrendingCard("Jalan Alor", "Kuala Lumpur", "6 min", Icons.restaurant),
                      _buildTrendingCard("Lot 10 Hutong", "Kuala Lumpur", "9 min", Icons.restaurant_menu),
                    ]
                  : _selectedCategory == "Shopping"
                      ? [
                          _buildTrendingCard("Pavilion KL", "Kuala Lumpur", "8 min", Icons.shopping_bag),
                          _buildTrendingCard("Suria KLCC", "Kuala Lumpur", "10 min", Icons.store),
                        ]
                      : _selectedCategory == "Nature"
                          ? [
                              _buildTrendingCard("KL Forest Eco Park", "Kuala Lumpur", "7 min", Icons.park),
                            ]
                          : [ // All
                              _buildTrendingCard("KLCC Park", "Kuala Lumpur", "5 min", Icons.park_rounded),
                            ],
            ),
          ),

        ],
      ),
    ),
  );
}


  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(25, 60, 25, 35),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4F46E5), Color(0xFF818CF8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(40),
          bottomRight: Radius.circular(40),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu_rounded, color: Colors.white),
                      onPressed: () {
                        Scaffold.of(context).openDrawer();
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Hello, User 👋",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "Explore the world!",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      _getWeatherIcon(_weatherCondition),
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "$_temperature°C",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 25),
          InkWell(
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.location_searching_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 12),
                  Text("Detect where the user are", style: TextStyle(color: Colors.white, fontSize: 14)),
                  Spacer(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            decoration: InputDecoration(
              hintText: "Search places...",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white70),
              filled: true,
              fillColor: Colors.white.withOpacity(0.2),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySection() {
    return SizedBox(
      height: 110,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 25),
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 18),
        itemBuilder: (context, index) {
          final category = _categories[index];
          final label = category["label"];
          final icon = category["icon"];
          final color = category["color"];
          final isSelected = label == _selectedCategory;

          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedCategory = label;
              });
            },
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: isSelected
                            ? Colors.black.withOpacity(0.15)
                            : Colors.black.withOpacity(0.05),
                        blurRadius: isSelected ? 10 : 6,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    icon,
                    size: 28,
                    color: isSelected
                        ? const Color.fromARGB(255, 194, 194, 199)
                        : Colors.black87,
                  ),

                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }



  Widget _buildSectionHeader(String title, bool showAll) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
          if (showAll) const Text("See All", style: TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildPlaceCard(int index) {

    final places = _placeByCategory[_selectedCategory] ?? [];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20, offset: const Offset(0, 10)),
        ],
      ),
      child: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
              ),
              child: Center(child: Icon(Icons.image, size: 50, color: Colors.indigo.withOpacity(0.2))),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  places[index],
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),

                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.star_rounded, color: Colors.amber, size: 18),
                    const SizedBox(width: 4),
                    const Text("4.8", style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Icon(Icons.arrow_circle_right, color: Colors.indigo.shade400, size: 28),
                  ],
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildTrendingCard(String name, String loc, String dist, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF6366F1).withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: const Color(0xFF6366F1), size: 20),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(loc, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
          Text(dist, style: const TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
