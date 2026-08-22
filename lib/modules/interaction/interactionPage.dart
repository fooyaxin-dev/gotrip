// ===== interactionPage.dart =====

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'addPost.dart';
import '../../models/postModel.dart';
import '../../services/post_service.dart';
import '../../services/like_service.dart';
import '../profile/profile.dart';
import '../../services/algolia_service.dart';
import '../../services/userPreference_service.dart';
import '../../services/sentiment_service.dart';
import '../../modules/place/detectPlacePage.dart';
import 'editPost.dart';
import 'postDetailPage.dart';
import '../../services/apps_Loading.dart';
import 'postMedia.dart';


class InteractionPage extends StatefulWidget {
  const InteractionPage({super.key});
  @override
  State<InteractionPage> createState() => _InteractionPageState();
}

class _InteractionPageState extends State<InteractionPage> {
  final PostService _postService = PostService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final LikeService _likeService = LikeService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // ── Committed search（按下搜索/回车后，主列表被替换成的结果）──
  bool _isSearchActive = false;
  bool _isSearchLoading = false;
  List<Post> _searchResultPosts = [];
  String _lastSearchQuery = '';

  // ── 关键词建议下拉（只在输入框 focus 时出现，纯文字）──
  bool _showSuggestions = false;
  bool _isSearching = false;
  List<String> _keywordSuggestions = [];


  String? _selectedCity;
  String? _selectedCityLabel;

  // ── City browsing bar (below search bar) ──
  List<String> _availableCities = [];
  bool _citiesLoading = true;

  Timer? _debounce;

  // ── User info cache ──
  final Map<String, Map<String, dynamic>> _userCache = {};


  // ── Feed pagination state ──
  final ScrollController _feedScrollController = ScrollController();
  static const int _feedPageSize = 20;
  
  List<Post> _feedPosts = [];
  DocumentSnapshot? _feedLastDoc;
  bool _feedHasMore = true;
  bool _feedInitialLoading = true;
  bool _feedLoadingMore = false;

  int _feedRequestId = 0;


  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus && _searchController.text.trim().isNotEmpty) {
        setState(() => _showSuggestions = _keywordSuggestions.isNotEmpty);
      } else if (!_searchFocus.hasFocus) {
        setState(() => _showSuggestions = false);
      }
    });

    // ★ 新增：feed 分页
    _loadFeedFirstPage();
    _loadAvailableCities();
    _feedScrollController.addListener(_onFeedScroll);

  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    _feedScrollController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _getUserInfo(String userId) async {
    if (_userCache.containsKey(userId)) return _userCache[userId]!;
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        _userCache[userId] = data;
        return data;
      }
    } catch (_) {}
    return {};
  }

  // ── Feed pagination ──────────────────────────────────────────────────────

  void _onFeedScroll() {
    if (_isSearchActive) return; // 搜索模式下不触发 feed 翻页
    if (_feedLoadingMore || !_feedHasMore) return;

    final pos = _feedScrollController.position;
    // 滑到还剩 300px 到底部时就提前加载下一页，体验更顺滑
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _loadMoreFeedPosts();
    }
  }

  Future<void> _loadFeedFirstPage() async {
  final requestId = ++_feedRequestId;
  final requestedCity = _selectedCity;

  if (!mounted) return;

  setState(() {
    _feedInitialLoading = true;
    _feedLoadingMore = false;
    _feedPosts = [];
    _feedLastDoc = null;
    _feedHasMore = true;
  });

  try {
    final page = requestedCity != null
        ? await _postService.getPostsByCityPaginated(
            city: requestedCity,
          )
        : await _postService.getPublicPostsPaginated();

    // Ignore stale request result.
    if (!mounted ||
        requestId != _feedRequestId) {
      return;
    }

    setState(() {
      _feedPosts = page.posts;
      _feedLastDoc = page.lastDocument;
      _feedHasMore = page.hasMore;
    });
  } catch (e) {
    debugPrint(
      '❌ Failed to load feed first page: $e',
    );

    // Don't let an old failed request affect
    // the current city/feed state.
    if (!mounted ||
        requestId != _feedRequestId) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Unable to load posts. Please check your connection and try again.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } finally {
    // Only the latest request may change the
    // current loading state.
    if (mounted &&
        requestId == _feedRequestId) {
      setState(() {
        _feedInitialLoading = false;
      });
    }
  }
}

Future<void> _loadMoreFeedPosts() async {
  if (_feedLoadingMore ||
      !_feedHasMore ||
      _feedLastDoc == null) {
    return;
  }

  final requestId = _feedRequestId;
  final requestedCity = _selectedCity;
  final requestedLastDoc = _feedLastDoc;

  if (!mounted) return;

  setState(() {
    _feedLoadingMore = true;
  });

  try {
    final page = requestedCity != null
        ? await _postService.getPostsByCityPaginated(
            city: requestedCity,
            startAfter: requestedLastDoc,
          )
        : await _postService.getPublicPostsPaginated(
            startAfter: requestedLastDoc,
          );

    // User may have switched city / refreshed the feed
    // while this pagination request was running.
    if (!mounted ||
        requestId != _feedRequestId ||
        requestedCity != _selectedCity) {
      return;
    }

    setState(() {
      // Extra protection against duplicate posts.
      final existingIds =
          _feedPosts
              .map((post) => post.id)
              .whereType<String>()
              .toSet();

      final newPosts = page.posts.where(
        (post) =>
            post.id == null ||
            !existingIds.contains(post.id),
      );

      _feedPosts.addAll(newPosts);

      _feedLastDoc = page.lastDocument;
      _feedHasMore = page.hasMore;
    });
  } catch (e) {
    debugPrint(
      '❌ Failed to load more feed posts: $e',
    );

    if (!mounted ||
        requestId != _feedRequestId) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Unable to load more posts. Please try again.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } finally {
    // Do not let an outdated request change
    // the loading flag of a newer feed request.
    if (mounted &&
        requestId == _feedRequestId) {
      setState(() {
        _feedLoadingMore = false;
      });
    }
  }
}
  
  void _onCityChipTap(String? city) {
    if (_selectedCity == city) return;
    setState(() {
      _isSearchActive = false;
      _selectedCity = city;
      _selectedCityLabel = city;
      _searchController.clear();
    });
    _loadFeedFirstPage();
  }

  Future<void> _loadAvailableCities() async {
    try {
      final snapshot = await _firestore
          .collection('posts')
          .where('visibility', isEqualTo: 'public')   // ✅ 对应 postModel 的 visibility 字段
          .get();

      final Map<String, int> cityCount = {};
      for (final doc in snapshot.docs) {
        final city = (doc.data()['city'] as String?)?.trim();
        if (city != null && city.isNotEmpty) {
          cityCount[city] = (cityCount[city] ?? 0) + 1;
        }
      }
      final sorted = cityCount.keys.toList()
        ..sort((a, b) => cityCount[b]!.compareTo(cityCount[a]!));

      if (!mounted) return;
      setState(() {
        _availableCities = sorted;
        _citiesLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _citiesLoading = false);
    }
  }



  // ─── 打字时的即时建议（dropdown，小数量）────────────────────────────────

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      setState(() {
        _isSearchActive = false;
        _searchResultPosts = [];
        _keywordSuggestions = [];
        _showSuggestions = false;
        _isSearchLoading = false;
      });
      return;
    }

    setState(() {
      _isSearchActive = true;   // ← 主列表立刻切换成"搜索模式"
      _isSearchLoading = true;
    });

    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      try {
        final results = await AlgoliaService.searchPosts(trimmed, hitsPerPage: 10);
        if (!mounted) return;
        setState(() {
          _searchResultPosts = results;
          _lastSearchQuery = trimmed;
          _isSearchLoading = false;
          _keywordSuggestions = _buildKeywordSuggestions(results, trimmed);
          // 只有 focus 还在输入框上时才继续显示下拉
          _showSuggestions = _searchFocus.hasFocus && _keywordSuggestions.isNotEmpty;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _searchResultPosts = [];
          _isSearchLoading = false;
        });
      }
    });
  }

  /// 从搜索结果里提炼出「关键词」文字建议：命中的标题 + 命中的标签，去重取前 6 个
  List<String> _buildKeywordSuggestions(List<Post> results, String query) {
    final qLower = query.toLowerCase();
    final set = <String>{};
    for (final p in results) {
      if (p.title.toLowerCase().contains(qLower)) set.add(p.title);
      for (final t in p.tags) {
        if (t.toLowerCase().contains(qLower)) set.add(t);
      }
      if (set.length >= 6) break;
    }
    return set.take(6).toList();
  }

  Widget _buildCityChipsBar() {
    if (_citiesLoading || _availableCities.isEmpty) return const SizedBox.shrink();

    return Container(
      color: Colors.white,
      height: 44,
      padding: const EdgeInsets.only(bottom: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _buildCityChip('All', _selectedCity == null, () => _onCityChipTap(null)),
          ..._availableCities.map((city) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _buildCityChip(city, _selectedCity == city, () => _onCityChipTap(city)),
              )),
        ],
      ),
    );
  }

  Widget _buildCityChip(String label, bool isSelected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF7C4DFF) : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? const Color(0xFF7C4DFF) : Colors.grey[300]!),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (label != 'All') ...[
            const Icon(Icons.location_on, size: 12, color: Color(0xFFD35D3E)),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : Colors.black87,
              )),
        ]),
      ),
    );
  }

  
  // ─── 提交搜索（按回车 / 点搜索键 / 点建议项）→ 替换主列表 ──────────────────

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    _debounce?.cancel();
    if (trimmed.isEmpty) {
      _clearSearch();
      return;
    }

    setState(() {
      _isSearchActive = true;
      _isSearchLoading = true;
      _lastSearchQuery = trimmed;
      _showSuggestions = false;
    });

    try {
      final results = await AlgoliaService.searchPosts(trimmed, hitsPerPage: 10);
      if (!mounted) return;
      setState(() {
        _searchResultPosts = results;
        _isSearchLoading = false;
        _keywordSuggestions = _buildKeywordSuggestions(results, trimmed);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchResultPosts = [];
        _isSearchLoading = false;
      });
    }
  }

  void _selectKeyword(String keyword) {
    _searchController.text = keyword;
    _searchController.selection =
        TextSelection.fromPosition(TextPosition(offset: keyword.length));
    _searchFocus.unfocus();
    setState(() => _showSuggestions = false);
    _performSearch(keyword);
  }

  void _clearSearch() {
    setState(() {
      _selectedCity = null;
      _selectedCityLabel = null;
      _showSuggestions = false;
      _keywordSuggestions = [];
      _isSearchActive = false;
      _isSearchLoading = false;
      _searchResultPosts = [];
      _lastSearchQuery = '';
    });
    _searchController.clear();
    _searchFocus.unfocus();
  }

  // ─── Location tap modal ────────────────────────────────────────────────────

  void _onLocationTap(Post post) {
    if (post.locationLat != null && post.locationLng != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RealTimeDetectPage(
            landmarkLat: post.locationLat,
            landmarkLng: post.locationLng,
            onBack: () => Navigator.pop(context),
          ),
        ),
      );
      return;
    }

    if (post.city != null && post.city!.isNotEmpty) {
      setState(() {
        _isSearchActive = false;
        _selectedCity      = post.city;
        _selectedCityLabel = post.city;
        _searchController.text = post.city!;
      });
      _loadFeedFirstPage();
    }
  }
  
 
  // ── Sentiment badge ──────────────────────────────────────────────────────
  // 只在后台情感分析已完成时（post.hasSentimentResult）显示。
  // 颜色随情感极性变化，直接反映社区对这个地点/体验的整体感受。

  static const Map<SentimentLabel, Color> _sentimentColors = {
    SentimentLabel.positive: Color(0xFF2E7D32),
    SentimentLabel.neutral:  Color(0xFF757575),
    SentimentLabel.negative: Color(0xFFC62828),
  };

  Widget _buildSentimentBadge(SentimentLabel label) {
    final color = _sentimentColors[label]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label.emoji, style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 4),
        Text(label.displayLabel,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  // ── Rating badge ─────────────────────────────────────────────────────────
  // 只有 rating > 0 才会调用到这里 —— 用户没打分的帖子完全不显示这个 badge，
  // 不会被误解成"0星差评"。
  Widget _buildRatingBadge(int rating) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.star_rounded, size: 12, color: Colors.orange),
        const SizedBox(width: 3),
        Text('$rating.0',
            style: const TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold, color: Colors.orange)),
      ]),
    );
  }


  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        _searchFocus.unfocus();
        setState(() => _showSuggestions = false);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8F9FA),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 20),
            Column(children: [
              const Text("Post", style: TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Container(height: 3, width: 20, decoration: BoxDecoration(color: const Color(0xFF7C4DFF), borderRadius: BorderRadius.circular(2))),
            ]),
            const SizedBox(width: 20),
          ]),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.add_circle_outline, color: Colors.black, size: 28),
              onPressed: () async {
                final posted = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PostingPage()),
                );
                if (posted == true) {
                  _userCache.clear();          // 顺手清一下缓存,防止头像/用户名是旧数据
                  _loadFeedFirstPage();        // 只有真的发布成功才刷新
                }
              },
            ),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(preferredSize: const Size.fromHeight(56), child: _buildSearchBar()),
        ),
        body: Column(
          children: [
            _buildCityChipsBar(),
            Expanded(
              child: Stack(children: [
                _isSearchActive ? _buildSearchResultsList() : _buildFeedList(),
                if (_showSuggestions && !_isSearchActive)
                  Positioned(top: 0, left: 0, right: 0, child: _buildSearchDropdown()),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  // ── 原本的公开 feed / 按城市筛选的 feed（未搜索时展示）──
  // ── 原本按城市筛选/公开 feed（未搜索时展示）── 分页版本
  Widget _buildFeedList() {
    if (_feedInitialLoading) {
      return const Center(child: TravelLoadingIndicator());
    }
    if (_feedPosts.isEmpty) {
      return _buildEmptyState();
    }
    return RefreshIndicator(
      onRefresh: () async {
        _userCache.clear();
        await _loadFeedFirstPage();
      },
      color: const Color(0xFF7C4DFF),
      child: ListView.builder(
        key: const PageStorageKey('post_list'),
        controller: _feedScrollController,
        physics: const BouncingScrollPhysics(),
        // 多一个 item 位置放"加载更多"的转圈
        itemCount: _feedPosts.length + (_feedHasMore ? 1 : 0),
        padding: const EdgeInsets.only(top: 10, bottom: 90),
        itemBuilder: (context, index) {
          if (index >= _feedPosts.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 28, height: 28,
                  child: TravelLoadingIndicator(),
                ),
              ),
            );
          }
          return _buildPostCard(_feedPosts[index]);
        },
      ),
    );
  }

  // ── 已提交搜索后的结果列表（主体区域被完全替换）──
  Widget _buildSearchResultsList() {
    if (_isSearchLoading) {
      return const Center(child: TravelLoadingIndicator());
    }
    if (_searchResultPosts.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.search_off, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('No results for "$_lastSearchQuery"',
              style: TextStyle(color: Colors.grey[600], fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('Try a different keyword',
              style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          const SizedBox(height: 20),
          TextButton.icon(
            onPressed: _clearSearch,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to all posts'),
          ),
        ]),
      );
    }
    return ListView.builder(
      key: const PageStorageKey('search_result_list'),
      physics: const BouncingScrollPhysics(),
      itemCount: _searchResultPosts.length,
      padding: const EdgeInsets.only(top: 10, bottom: 90),
      itemBuilder: (context, index) => _buildPostCard(_searchResultPosts[index]),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        onChanged: _onSearchChanged,
        onSubmitted: _performSearch,
        textInputAction: TextInputAction.search,
        onTap: () {
          if (_searchController.text.trim().isNotEmpty && _keywordSuggestions.isNotEmpty) {
            setState(() => _showSuggestions = true);
          }
        },
        decoration: InputDecoration(
          hintText: 'Search posts, tags...',
          hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
          prefixIcon: _isSearchLoading
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: TravelLoadingIndicator(size: 22)))
            : const Icon(Icons.search, color: Color(0xFF7C4DFF), size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(icon: const Icon(Icons.close, size: 18, color: Colors.grey), onPressed: _clearSearch)
              : null,
          filled: true,
          fillColor: Colors.grey[100],
          contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: Color(0xFFD35D3E), width: 1.5)),
        ),
      ),
    );
  }

  Widget _buildSearchDropdown() {
    if (_keywordSuggestions.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.10), blurRadius: 16, offset: const Offset(0, 6))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader(Icons.search, 'Suggestions', const Color(0xFF7C4DFF)),
              ..._keywordSuggestions.map(_buildKeywordTile),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeywordTile(String keyword) {
    return InkWell(
      onTap: () => _selectKeyword(keyword),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Icon(Icons.search, size: 16, color: Colors.grey[400]),
          const SizedBox(width: 10),
          Expanded(
            child: Text(keyword,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Icon(Icons.north_west_rounded, size: 14, color: Colors.grey[400]),
        ]),
      ),
    );
  }
    
  Widget _buildNoResults() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Row(children: [
        Icon(Icons.search_off, color: Colors.grey),
        SizedBox(width: 12),
        Text('No posts found', style: TextStyle(color: Colors.grey, fontSize: 14)),
      ]),
    );
  }

  Widget _buildSectionHeader(IconData icon, String label, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(label.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color, letterSpacing: 0.8)),
      ]),
    );
  }

  // ── Dropdown 里的建议项：点击 = 直接提交完整搜索，展示替换后的结果列表 ──
  Widget _buildPostTile(Post post) {
    return InkWell(
      onTap: () {
        _searchController.text = post.title;
        UserPreferenceService.instance.updateFromSearch(
          placeTypes: post.placeTypes,
          postTags:   post.tags,
          postTopic:  post.topic,
        );
        _performSearch(post.title);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: post.images.isNotEmpty
              ? buildPostImage(post.images.first, width: 44, height: 44, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _postIconBox())
              : _postIconBox(),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(post.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87)),
            const SizedBox(height: 2),
            Row(children: [
              if (post.city != null && post.city!.isNotEmpty) ...[
                const Icon(Icons.location_on, size: 11, color: Color(0xFFD35D3E)),
                const SizedBox(width: 2),
                Text(post.city!, style: const TextStyle(fontSize: 11, color: Color(0xFFD35D3E))),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(post.content, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey[500]))),
            ]),
          ])),
          const SizedBox(width: 8),
          Row(children: [
            Icon(Icons.thumb_up_outlined, size: 12, color: Colors.grey[400]),
            const SizedBox(width: 3),
            Text('${post.likes}', style: TextStyle(fontSize: 11, color: Colors.grey[400])),
          ]),
        ]),
      ),
    );
  }

  Widget _postIconBox() {
    return Container(width: 44, height: 44, color: Colors.grey[200], child: const Icon(Icons.article_outlined, color: Colors.grey, size: 22));
  }

  Widget _buildEmptyState() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(_selectedCity != null ? Icons.location_off : Icons.post_add, size: 80, color: Colors.grey[400]),
      const SizedBox(height: 16),
      Text(_selectedCity != null ? 'No posts in $_selectedCity yet' : 'No posts yet',
          style: TextStyle(color: Colors.grey[600], fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(
        _selectedCity != null ? 'Be the first to share your $_selectedCity travel experience!' : 'Tap + to share your first travel story!',
        style: TextStyle(color: Colors.grey[500], fontSize: 13), textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      ElevatedButton.icon(
        onPressed: () async {
          final posted = await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PostingPage()),
          );
          print('🔍 posted = $posted'); 
          if (posted == true) {
            _userCache.clear();
            _loadFeedFirstPage();
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('Post Story'),
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD35D3E), padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12)),
      ),
    ]));
  }

  Widget _buildPostCard(Post post) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PostDetailPage(post: post)),
      ),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        elevation: 0.5,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildUserInfo(post),
            const SizedBox(height: 12),

            // ── Location chip + Sentiment badge（同一行，地点 + 大家的感受）──
            if ((post.city != null && post.city!.isNotEmpty) ||
                (post.location != null && post.location!.isNotEmpty) ||
                post.hasSentimentResult)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  if ((post.city != null && post.city!.isNotEmpty) ||
                      (post.location != null && post.location!.isNotEmpty))
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _onLocationTap(post),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.location_on, size: 13, color: Color(0xFFD35D3E)),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              [
                                if (post.city != null && post.city!.isNotEmpty) post.city!,
                                if (post.location != null &&
                                    post.location!.isNotEmpty &&
                                    post.location != post.city)
                                  post.location!,
                              ].join(' · '),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFD35D3E),
                                fontWeight: FontWeight.w500,
                                decoration: TextDecoration.underline,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_forward_ios, size: 10, color: Color(0xFFD35D3E)),
                        ]),
                      ),
                    ),
                  if (post.rating > 0) ...[
                    const SizedBox(width: 6),
                    _buildRatingBadge(post.rating),
                  ],
                  if (post.hasSentimentResult) ...[
                    const SizedBox(width: 6),
                    _buildSentimentBadge(post.sentimentLabel!),
                  ],
                ]),
              ),

            // ── Title ──
            Text(post.title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
            const SizedBox(height: 8),

            // ── Content (preview 3 lines) ──
            Text(post.content,
                style: TextStyle(fontSize: 14, color: Colors.grey[800], height: 1.4),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),

            // ── Media ──
            _buildMediaGrid(post),

            // ── Tags ──
            if (post.tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: post.tags.map((tag) => GestureDetector(
                  onTap: () {
                    _searchController.text = tag;
                    _performSearch(tag);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: const Color(0xFFD35D3E).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16)),
                    child: Text('#$tag',
                        style: const TextStyle(
                            color: Color(0xFFD35D3E),
                            fontSize: 12,
                            fontWeight: FontWeight.w500)),
                  ),
                )).toList(),
              ),
            ],

            const SizedBox(height: 16),
            const Divider(height: 1, thickness: 0.5),
            const SizedBox(height: 12),

            // ── Like & Comment ──
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildSocialBtn(
                    Icons.chat_bubble_outline,
                    post.comments > 0 ? '${post.comments}' : 'Comments',
                    () => _handleComment(post),
                    false),
                StreamBuilder<bool>(
                  stream: _likeService.likeStatusStream(post.id!),
                  initialData: false,
                  builder: (context, snapshot) =>
                      _buildLikeButton(post, snapshot.data ?? false),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
  
Future<void> _handleEdit(Post post) async {
  final updated = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (_) => EditPostPage(
        post: post,
      ),
    ),
  );

  if (!mounted || updated != true) {
    return;
  }

  // User information / badge data may also have
  // changed while navigating, so don't keep stale cache.
  _userCache.clear();

  // Refresh city chips too because visibility may have
  // changed from public → private/friends or vice versa.
  _loadAvailableCities();

  if (_isSearchActive) {
    final query = _lastSearchQuery.trim();

    if (query.isNotEmpty) {
      await _performSearch(query);
    }
  } else {
    await _loadFeedFirstPage();
  }
}
  
 void _handleDelete(Post post) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(
        'Delete Post',
      ),
      content: const Text(
        'Are you sure you want to delete this post?',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext),
          child: const Text(
            'Cancel',
          ),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(dialogContext);

            final postId = post.id;

            if (postId == null) {
              return;
            }

            try {
              await _postService.deletePost(
                postId,
              );

              if (!mounted) return;

              // Remove immediately from all in-memory lists
              // so the deleted card disappears without
              // waiting for another network request.
              setState(() {
                _feedPosts.removeWhere(
                  (p) => p.id == postId,
                );

                _searchResultPosts.removeWhere(
                  (p) => p.id == postId,
                );
              });

              // The available city list/count may also
              // have changed after deleting this post.
              _loadAvailableCities();

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Post deleted',
                  ),
                  backgroundColor: Colors.green,
                ),
              );
            } catch (e) {
              if (!mounted) return;

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Failed to delete: $e',
                  ),
                  backgroundColor: Colors.red,
                ),
              );
            }
          },
          child: const Text(
            'Delete',
            style: TextStyle(
              color: Colors.red,
            ),
          ),
        ),
      ],
    ),
  );
}

  Widget _buildUserInfo(Post post) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _getUserInfo(post.userId),
      builder: (context, snapshot) {
        String userName   = post.userName;
        String? userPhoto = post.userPhoto;
        if (snapshot.hasData && snapshot.data!.isNotEmpty) {
          userName  = snapshot.data!['username']        ?? userName;
          userPhoto = snapshot.data!['profileImageUrl'] ?? userPhoto;
        }
  
        final isOwner = post.userId == _auth.currentUser?.uid;

        return Row(children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5)),
            child: _buildUserAvatar(userName, userPhoto, post.userId, post.isAnonymous),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ── Username + top badge (Weibo-style) ──
              Row(children: [
                Text(post.isAnonymous ? 'Anonymous User' : userName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                if (!post.isAnonymous) ...[
                  const SizedBox(width: 6),
                  _buildBadgePillFromCache(snapshot.data),
                ],
              ]),
              const SizedBox(height: 2),
              Text("${_formatTime(post.createdAt)} · GoTrip",
                  style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            ]),
          ),
  
          // ── 只有自己的帖子才显示三点菜单 ──
          if (isOwner)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, color: Colors.grey[600]),
              onSelected: (value) {
                if (value == 'edit')   _handleEdit(post);
                if (value == 'delete') _handleDelete(post);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Edit'),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_outline, size: 20, color: Colors.red),
                    SizedBox(width: 12),
                    Text('Delete', style: TextStyle(color: Colors.red)),
                  ]),
                ),
              ],
            ),
        ]);
      },
    );
  }

  // ── Badge pill from Firestore user cache ─────────────────────────────────
  // Reads topBadgeEmoji / topBadgeLabel / topBadgeLevel stored in users/{uid}.
  // Zero extra Firestore reads — data already fetched by _getUserInfo().

  static const _tierColors = {
    'bronze': Color(0xFFCD7F32),
    'silver': Color(0xFFA8A9AD),
    'gold':   Color(0xFFFFD700),
  };

  Widget _buildBadgePillFromCache(Map<String, dynamic>? userInfo) {
    if (userInfo == null) return const SizedBox.shrink();
    final emoji = userInfo['topBadgeEmoji'] as String?;
    final label = userInfo['topBadgeLabel'] as String?;
    final level = userInfo['topBadgeLevel'] as String?;
    if (emoji == null || label == null || level == null) {
      return const SizedBox.shrink();
    }
    final color = _tierColors[level] ?? const Color(0xFF6366F1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(emoji, style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 3),
        Text(label,
            style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  Widget _buildMediaGrid(Post post) {
    final images = post.images;
    final videos = post.videoPaths;
    if (images.isEmpty && videos.isEmpty) return const SizedBox.shrink();

    final List<(String path, bool isVideo)> allMedia = [
      ...images.map((p) => (p, false)),
      ...videos.map((p) => (p, true)),
    ];

    if (allMedia.length == 1) {
      return ClipRRect(borderRadius: BorderRadius.circular(12), child: _buildSingleMediaTile(allMedia[0].$1, allMedia[0].$2, height: 250));
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: allMedia.length == 2 ? 2 : 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
      itemCount: allMedia.length > 9 ? 9 : allMedia.length,
      itemBuilder: (context, index) {
        final (path, isVideo) = allMedia[index];
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(fit: StackFit.expand, children: [
            _buildSingleMediaTile(path, isVideo),
            if (allMedia.length > 9 && index == 8)
              Container(color: Colors.black.withOpacity(0.6), child: Center(child: Text('+${allMedia.length - 9}', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)))),
          ]),
        );
      },
    );
  }

  Widget _buildSingleMediaTile(String path, bool isVideo, {double? height}) {
    if (isVideo) return SizedBox(height: height ?? 200, child: LocalVideoPlayer(path: path));
      return buildPostImage(path, height: height, fit: BoxFit.cover);
    }

  Widget _buildLikeButton(Post post, bool isLiked) {
    return StreamBuilder<int>(
      stream: _likeService.likeCountStream(post.id!),
      initialData: post.likes,
      builder: (context, snapshot) {
        int likeCount = snapshot.data ?? post.likes;
        return InkWell(
          onTap: () => _handleLike(post),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Icon(isLiked ? Icons.thumb_up : Icons.thumb_up_outlined, size: 20, color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700]),
              const SizedBox(width: 6),
              Text(likeCount > 0 ? '$likeCount' : 'Like',
                  style: TextStyle(color: isLiked ? const Color(0xFFD35D3E) : Colors.grey[700], fontSize: 13, fontWeight: isLiked ? FontWeight.bold : FontWeight.normal)),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildSocialBtn(IconData icon, String label, VoidCallback onTap, bool isActive) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Icon(icon, size: 20, color: Colors.grey[700]),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: Colors.grey[700], fontSize: 13)),
        ]),
      ),
    );
  }

  void _handleLike(Post post) async {
    try {
      final bool isLiked = await _likeService.toggleLike(post.id!);
      // ← 去掉 snackbar，只静默更新偏好
      UserPreferenceService.instance.updateFromLike(
        placeTypes: post.placeTypes,
        postTags: post.tags,
        postTopic: post.topic,
        isLiking: isLiked,
        sentimentLabel: post.sentimentLabel ?? SentimentLabel.neutral,
        sentimentMatchedTokens: post.sentimentMatchedTokens ?? 0,
      );
    } catch (e) {
      // 出错才提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Operation failed: $e')),
        );
      }
    }
  }

  void _handleComment(Post post) => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Comment feature under development...')));

  Widget _buildUserAvatar(String userName, String? userPhoto, String userId, bool isAnonymous) {
    if (isAnonymous) return CircleAvatar(radius: 20, backgroundColor: _getUserColor(userId), child: const Icon(Icons.person_outline, color: Colors.white, size: 22));
    if (userPhoto != null && userPhoto.isNotEmpty) {
      if (userPhoto.startsWith('data:image')) {
        try {
          Uint8List bytes = base64Decode(userPhoto.split(',')[1]);
          return CircleAvatar(radius: 20, backgroundImage: MemoryImage(bytes), backgroundColor: Colors.transparent);
        } catch (_) {}
      } else if (userPhoto.startsWith('http')) {
        return CircleAvatar(radius: 20, backgroundImage: NetworkImage(userPhoto), backgroundColor: Colors.transparent);
      }
    }
    return CircleAvatar(radius: 20, backgroundColor: _getUserColor(userId),
        child: Text(userName.isNotEmpty ? userName[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)));
  }

  String _formatTime(DateTime? dateTime) {
    if (dateTime == null) return 'Just now';
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} mins ago';
    if (diff.inHours < 24) return '${diff.inHours} hour${diff.inHours > 1 ? 's' : ''} ago';
    if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago';
    return '${dateTime.month}/${dateTime.day}';
  }

  Color _getUserColor(String userId) {
    final colors = [Colors.blueAccent, Colors.greenAccent, Colors.purpleAccent, Colors.orangeAccent, Colors.pinkAccent, Colors.tealAccent, Colors.indigoAccent, Colors.cyanAccent];
    return colors[userId.hashCode.abs() % colors.length];
  }
}