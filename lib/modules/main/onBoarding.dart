// pages/onboarding/onboarding_page.dart
import 'package:flutter/material.dart';
import '../../services/userPreference_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main/homepage.dart';
import '../../services/apps_Loading.dart';
import 'package:firebase_auth/firebase_auth.dart';  

class OnboardingPage extends StatefulWidget {
  final bool isEditing;
  final VoidCallback? onDone;

  const OnboardingPage({
    super.key,
    this.isEditing = false,
    this.onDone,
  });

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {

  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isSaving   = false;

  final Set<String> _selectedCategories = {};
  final Set<String> _selectedCuisines   = {};
  String     _selectedTravelMode        = 'walk';
  BudgetTier _selectedBudget            = BudgetTier.budget; // ← new

  late final AnimationController _fadeCtrl;
  late final Animation<double>    _fadeAnim;

  bool get _showCuisinePage => _selectedCategories.contains('restaurant');
  // Pages: category → (cuisine) → budget → travel mode
  int  get _totalPages      => _showCuisinePage ? 4 : 3;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    _fadeCtrl.forward();

    if (widget.isEditing) {
      final prefs = UserPreferenceService.instance.current;
      _selectedCategories.addAll(prefs.categories);
      _selectedCuisines.addAll(prefs.cuisines);
      _selectedTravelMode = prefs.travelMode;
      _selectedBudget     = prefs.budgetTier;
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Data
  // ─────────────────────────────────────────────

  final List<Map<String, dynamic>> _categories = [
    {'key': 'restaurant',         'label': 'Food',          'icon': '🍜', 'color': Color(0xFFFF6B35)},
    {'key': 'park',               'label': 'Nature',        'icon': '🌿', 'color': Color(0xFF2ECC71)},
    {'key': 'tourist_attraction', 'label': 'Historical',    'icon': '🏛️', 'color': Color(0xFF3498DB)},
    {'key': 'shopping_mall',      'label': 'Shopping',      'icon': '🛍️', 'color': Color(0xFF9B59B6)},
    {'key': 'amusement_park',     'label': 'Entertainment', 'icon': '🎭', 'color': Color(0xFFE74C3C)},
  ];

  final List<Map<String, dynamic>> _cuisines = [
    {'key': 'chinese',  'label': 'Chinese',  'icon': '🥢'},
    {'key': 'malay',    'label': 'Malay',    'icon': '🍛'},
    {'key': 'indian',   'label': 'Indian',   'icon': '🫓'},
    {'key': 'western',  'label': 'Western',  'icon': '🍔'},
    {'key': 'japanese', 'label': 'Japanese', 'icon': '🍱'},
    {'key': 'korean',   'label': 'Korean',   'icon': '🥩'},
    {'key': 'dessert',  'label': 'Dessert',  'icon': '🧁'},
    {'key': 'cafe',     'label': 'Cafe',     'icon': '☕'},
  ];

  final List<Map<String, dynamic>> _travelModes = [
    {'key': 'walk',  'label': 'Walking', 'icon': Icons.directions_walk, 'desc': 'Prefer nearby places'},
    {'key': 'motor', 'label': 'Motor',   'icon': Icons.motorcycle,      'desc': 'Can go a bit further'},   // 🆕
    {'key': 'drive', 'label': 'Driving', 'icon': Icons.directions_car,  'desc': 'Can go further'},
    {'key': 'both',  'label': 'Both',    'icon': Icons.swap_horiz,      'desc': 'Flexible'},
  ];

  // Budget tiers with icon, label, desc, color
  final List<Map<String, dynamic>> _budgets = [
    {
      'tier':  BudgetTier.budget,
      'icon':  '💰',
      'label': 'Budget',
      'desc':  'Affordable spots & local eats',
      'color': const Color(0xFF2ECC71),
    },
    {
      'tier':  BudgetTier.midRange,
      'icon':  '💳',
      'label': 'Mid-range',
      'desc':  'A balance of comfort & value',
      'color': const Color(0xFF3498DB),
    },
    {
      'tier':  BudgetTier.premium,
      'icon':  '✨',
      'label': 'Premium',
      'desc':  'Top-rated & high-end experiences',
      'color': const Color(0xFF9B59B6),
    },
  ];

  // ─────────────────────────────────────────────
  // Actions
  // ─────────────────────────────────────────────

  void _nextPage() {
    if (_currentPage == 0 && _selectedCategories.isEmpty) {
      _showSnack('Please select at least one category');
      return;
    }

    if (_currentPage < _totalPages - 1) {
      _fadeCtrl.reset();
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
      _fadeCtrl.forward();
    } else {
      _finish();
    }
  }

  void _prevPage() {
    _fadeCtrl.reset();
    _pageController.previousPage(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
    _fadeCtrl.forward();
  }

  Future<void> _finish() async {
    setState(() => _isSaving = true);

    try {
      final prefs = UserPreferences(
        categories:     _selectedCategories.toList(),
        cuisines:       _selectedCuisines.toList(),
        travelMode:     _selectedTravelMode,
        budgetTier:     _selectedBudget,
        onboardingDone: true,
      );

      await UserPreferenceService.instance.save(prefs);

      // ★ 按 uid 缓存，避免共享设备/多账号切换时互相污染
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final sp = await SharedPreferences.getInstance();
        await sp.setBool('cached_onboarding_done_$uid', true);
      }

      if (!mounted) return;

      if (widget.isEditing) {
        widget.onDone?.call();
        Navigator.pop(context);
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save preferences: $e')),
        );
      }
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      appBar: widget.isEditing
          ? AppBar(
              backgroundColor: const Color(0xFFF8F6FF),
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.black87, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
              title: const Text('Edit Preferences',
                  style: TextStyle(
                      color: Colors.black87,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              centerTitle: true,
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            _buildProgressBar(),
            Expanded(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _currentPage = i),
                  children: [
                    _buildCategoryPage(),
                    if (_showCuisinePage) _buildCuisinePage(),
                    _buildBudgetPage(),      // ← new
                    _buildTravelModePage(),
                  ],
                ),
              ),
            ),
            _buildBottomButton(),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Progress bar
  // ─────────────────────────────────────────────

  Widget _buildProgressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(
        children: List.generate(_totalPages, (i) {
          return Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i < _totalPages - 1 ? 6 : 0),
              decoration: BoxDecoration(
                color: i <= _currentPage
                    ? const Color(0xFF7C4DFF)
                    : Colors.grey[200],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Page 1: Categories
  // ─────────────────────────────────────────────

  Widget _buildCategoryPage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isEditing ? '✏️ Update interests' : '👋 Welcome!',
            style: const TextStyle(fontSize: 14, color: Color(0xFF7C4DFF),
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('What do you love\nexploring?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E), height: 1.2)),
          const SizedBox(height: 8),
          Text('Select all that apply',
              style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          const SizedBox(height: 28),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 1.5,
              physics: const NeverScrollableScrollPhysics(),
              children: _categories.map((cat) {
                final isSelected = _selectedCategories.contains(cat['key']);
                return GestureDetector(
                  onTap: () => setState(() {
                    isSelected
                        ? _selectedCategories.remove(cat['key'])
                        : _selectedCategories.add(cat['key'] as String);
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (cat['color'] as Color).withOpacity(0.12)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isSelected
                            ? cat['color'] as Color
                            : Colors.grey[200]!,
                        width: isSelected ? 2 : 1,
                      ),
                      boxShadow: isSelected
                          ? [BoxShadow(
                              color: (cat['color'] as Color).withOpacity(0.2),
                              blurRadius: 12, offset: const Offset(0, 4))]
                          : [BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 8, offset: const Offset(0, 2))],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(cat['icon'] as String,
                            style: const TextStyle(fontSize: 28)),
                        const SizedBox(height: 6),
                        Text(cat['label'] as String,
                            style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? cat['color'] as Color
                                  : Colors.grey[700],
                            )),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Page 2: Cuisines (只在选了 Food 时出现)
  // ─────────────────────────────────────────────

  Widget _buildCuisinePage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isEditing ? '✏️ Update food preferences' : '🍽️ Food Preferences',
            style: const TextStyle(fontSize: 14, color: Color(0xFF7C4DFF),
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('What cuisines do\nyou enjoy?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E), height: 1.2)),
          const SizedBox(height: 8),
          Text('Select all that apply',
              style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          const SizedBox(height: 28),
          Expanded(
            child: GridView.count(
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              physics: const NeverScrollableScrollPhysics(),
              children: _cuisines.map((c) {
                final isSelected = _selectedCuisines.contains(c['key']);
                return GestureDetector(
                  onTap: () => setState(() {
                    isSelected
                        ? _selectedCuisines.remove(c['key'])
                        : _selectedCuisines.add(c['key'] as String);
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF7C4DFF).withOpacity(0.1)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF7C4DFF)
                            : Colors.grey[200]!,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(c['icon'] as String,
                            style: const TextStyle(fontSize: 22)),
                        const SizedBox(height: 4),
                        Text(c['label'] as String,
                            style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? const Color(0xFF7C4DFF)
                                  : Colors.grey[600],
                            )),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Page 3: Budget  ← NEW
  // ─────────────────────────────────────────────

  Widget _buildBudgetPage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isEditing ? '✏️ Update budget' : '💸 Your Budget',
            style: const TextStyle(fontSize: 14, color: Color(0xFF7C4DFF),
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('What\'s your travel\nspending style?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E), height: 1.2)),
          const SizedBox(height: 8),
          Text('We\'ll recommend places that fit your budget',
              style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          const SizedBox(height: 32),

          ..._budgets.map((b) {
            final tier       = b['tier'] as BudgetTier;
            final isSelected = _selectedBudget == tier;
            final color      = b['color'] as Color;

            return GestureDetector(
              onTap: () => setState(() => _selectedBudget = tier),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: isSelected ? color.withOpacity(0.08) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected ? color : Colors.grey[200]!,
                    width: isSelected ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isSelected
                          ? color.withOpacity(0.15)
                          : Colors.black.withOpacity(0.04),
                      blurRadius: isSelected ? 12 : 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    // Icon container
                    Container(
                      width: 52, height: 52,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? color.withOpacity(0.15)
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Text(b['icon'] as String,
                            style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Label + desc
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b['label'] as String,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? color : Colors.black87,
                              )),
                          const SizedBox(height: 2),
                          Text(b['desc'] as String,
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey[500])),
                        ],
                      ),
                    ),

                    // Check mark
                    AnimatedOpacity(
                      opacity: isSelected ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.check_circle_rounded,
                          color: color, size: 24),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Page 4: Travel Mode
  // ─────────────────────────────────────────────

  Widget _buildTravelModePage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isEditing ? '✏️ Update travel style' : '🚗 Almost there!',
            style: const TextStyle(fontSize: 14, color: Color(0xFF7C4DFF),
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('How do you usually\nget around?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E), height: 1.2)),
          const SizedBox(height: 8),
          Text('This helps us show the right distances',
              style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          const SizedBox(height: 32),
          ..._travelModes.map((mode) {
            final isSelected = _selectedTravelMode == mode['key'];
            return GestureDetector(
              onTap: () => setState(() =>
                  _selectedTravelMode = mode['key'] as String),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF7C4DFF).withOpacity(0.08)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF7C4DFF)
                        : Colors.grey[200]!,
                    width: isSelected ? 2 : 1,
                  ),
                  boxShadow: [BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF7C4DFF).withOpacity(0.15)
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(mode['icon'] as IconData,
                          color: isSelected
                              ? const Color(0xFF7C4DFF)
                              : Colors.grey[500],
                          size: 26),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(mode['label'] as String,
                              style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold,
                                color: isSelected
                                    ? const Color(0xFF7C4DFF)
                                    : Colors.black87,
                              )),
                          Text(mode['desc'] as String,
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey[500])),
                        ],
                      ),
                    ),
                    if (isSelected)
                      const Icon(Icons.check_circle_rounded,
                          color: Color(0xFF7C4DFF), size: 24),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Bottom button
  // ─────────────────────────────────────────────

  Widget _buildBottomButton() {
    final isLast = _currentPage == _totalPages - 1;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, 24 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          if (_currentPage > 0)
            GestureDetector(
              onTap: _prevPage,
              child: Container(
                width: 52, height: 52,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: const Icon(Icons.arrow_back_ios_new,
                    size: 18, color: Colors.black54),
              ),
            ),
          Expanded(
            child: SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _nextPage,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C4DFF),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: _isSaving
                    ? const SizedBox(width: 22, height: 22,
                        child: TravelLoadingIndicator(size :22))
                    : Text(
                        isLast
                            ? (widget.isEditing ? 'Save Changes ✓' : "Let's Go! 🚀")
                            : 'Continue',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}