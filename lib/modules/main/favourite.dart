import 'package:flutter/material.dart';
import '../../services/favourite_service.dart';
import '../place/favouriteButton.dart';
import '../place/placeDetailPage.dart';
import '../landmark/landmarkResult.dart';
import '../../services/vision_service.dart';
import '../../services/apps_Loading.dart';
import '../../services/error_handler.dart';
import 'package:cached_network_image/cached_network_image.dart';

// ─────────────────────────────────────────────
// 📌 Google Places API types → 自定义分类映射
// ─────────────────────────────────────────────
class PlaceCategory {
  final String label;
  final IconData icon;
  final List<String> types;

  const PlaceCategory({
    required this.label,
    required this.icon,
    required this.types,
  });
}

const List<PlaceCategory> kPlaceCategories = [
  PlaceCategory(label: 'All', icon: Icons.apps_rounded, types: []),
  PlaceCategory(label: 'Food', icon: Icons.restaurant_rounded, types: [
    'restaurant',
    'food',
    'cafe',
    'bakery',
    'bar',
    'meal_delivery',
    'meal_takeaway',
    'coffee_shop',
    'fast_food_restaurant',
    'pizza_restaurant',
    'ramen_restaurant',
    'sushi_restaurant',
    'seafood_restaurant',
    'steak_house',
    'vegetarian_restaurant',
    'vegan_restaurant',
    'ice_cream_shop',
    'dessert_shop',
    'juice_bar',
    'bubble_tea_store',
  ]),
  PlaceCategory(label: 'Nature', icon: Icons.park_rounded, types: [
    'park',
    'national_park',
    'nature_reserve',
    'botanical_garden',
    'garden',
    'hiking_area',
    'campground',
    'wildlife_park',
    'wildlife_refuge',
    'forest',
    'beach',
    'lake',
    'mountain',
    'waterfall',
  ]),
  PlaceCategory(label: 'Attraction', icon: Icons.photo_camera_rounded, types: [
    'tourist_attraction',
    'landmark',
    'historical_landmark',
    'heritage_site',
    'monument',
    'sculpture',
    'plaza',
    'cultural_landmark',
    'observation_deck',
    'performing_arts_theater',
    'event_venue',
  ]),
  PlaceCategory(label: 'Culture', icon: Icons.museum_rounded, types: [
    'museum',
    'art_gallery',
    'library',
    'cultural_center',
    'aquarium',
    'zoo',
    'planetarium',
    'science_museum',
    'history_museum',
    'art_studio',
    'movie_theater',
    'concert_hall',
  ]),
  PlaceCategory(label: 'Shopping', icon: Icons.shopping_bag_rounded, types: [
    'shopping_mall',
    'store',
    'supermarket',
    'grocery_store',
    'clothing_store',
    'shoe_store',
    'book_store',
    'convenience_store',
    'department_store',
    'electronics_store',
    'furniture_store',
    'home_goods_store',
    'market',
    'night_market',
    'outlet_mall',
  ]),
  PlaceCategory(label: 'Hotel', icon: Icons.hotel_rounded, types: [
    'lodging',
    'hotel',
    'motel',
    'hostel',
    'resort_hotel',
    'bed_and_breakfast',
    'extended_stay_hotel',
    'vacation_rental',
  ]),
  PlaceCategory(
      label: 'Transport',
      icon: Icons.directions_transit_rounded,
      types: [
        'airport',
        'train_station',
        'subway_station',
        'bus_station',
        'bus_stop',
        'ferry_terminal',
        'transit_depot',
        'taxi_stand',
        'light_rail_station',
        'car_rental',
      ]),
];

String getPlaceCategory(List<String> googleTypes) {
  final lowerTypes = googleTypes.map((t) => t.toLowerCase()).toList();
  for (final category in kPlaceCategories) {
    if (category.label == 'All') continue;
    for (final keyword in category.types) {
      if (lowerTypes.any((t) => t.contains(keyword))) {
        return category.label;
      }
    }
  }
  return 'Other';
}

enum FavouriteDestination {
  landmarkResult,
  placeDetail,
}

class FavouriteRouter {
  /// Generates the canonical slug used for deterministic landmark IDs.
  static String canonicalLandmarkSlug(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  /// Classifies where a favourite item should navigate.
  static FavouriteDestination classifyDestination(Map<String, dynamic> place) {
    final source = (place['source'] as String?)?.trim().toLowerCase();

    // 1. Explicit source matches
    if (source == 'landmark') {
      return FavouriteDestination.landmarkResult;
    }
    if (source == 'place' || source == 'geoapify') {
      return FavouriteDestination.placeDetail;
    }

    // 2. Legacy / missing source: Deterministic evidence only
    final placeId = (place['placeId'] as String? ?? '').trim();
    final name = (place['name'] as String? ?? '').trim();

    if (placeId.isNotEmpty) {
      if (placeId.startsWith('landmark_')) {
        return FavouriteDestination.landmarkResult;
      }

      if (name.isNotEmpty) {
        final slug = canonicalLandmarkSlug(name);
        if (slug.isNotEmpty &&
            (placeId == slug || placeId == 'landmark_$slug')) {
          return FavouriteDestination.landmarkResult;
        }
      }
    }

    // 3. Fallback: normal place detail
    return FavouriteDestination.placeDetail;
  }
}

// ─────────────────────────────────────────────
// 📄 FavouritePage
// ─────────────────────────────────────────────
class FavouritePage extends StatefulWidget {
  const FavouritePage({super.key});

  @override
  State<FavouritePage> createState() => _FavouritePageState();
}

class _FavouritePageState extends State<FavouritePage>
    with TickerProviderStateMixin {
  // ✅ 不用 TabController 管 index，直接用 selectedType 字符串
  String _selectedType = 'All';

  IconData _tabIcon(String label) {
    return kPlaceCategories
        .firstWhere(
          (c) => c.label == label,
          orElse: () => const PlaceCategory(
              label: 'Other', icon: Icons.place_rounded, types: []),
        )
        .icon;
  }

  /// 从收藏列表里提取出实际存在的分类，按 kPlaceCategories 顺序排列
  List<String> _buildActiveTabs(List<Map<String, dynamic>> favourites) {
    final Set<String> found = {};
    for (final place in favourites) {
      final types =
          (place['types'] as List?)?.map((e) => e.toString()).toList() ?? [];
      found.add(getPlaceCategory(types));
    }

    final ordered = <String>['All'];
    for (final cat in kPlaceCategories) {
      if (cat.label != 'All' && found.contains(cat.label)) {
        ordered.add(cat.label);
      }
    }
    if (found.contains('Other')) ordered.add('Other');
    return ordered;
  }

  int _retryKey = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        key: ValueKey(_retryKey),
        stream: FavouriteService.getFavouritesStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: TravelLoadingIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: AppErrorStateView(
                title: 'Unable to Load Favourites',
                message: ErrorHandler.userFriendlyMessage(
                  snapshot.error,
                  defaultMessage:
                      'Please check your network connection and try again.',
                ),
                onRetry: () => setState(() => _retryKey++),
              ),
            );
          }

          final allFavourites = snapshot.data ?? [];

          // ✅ 每次 stream 更新都重新算 tabs，无需 TabController
          final activeTabs = _buildActiveTabs(allFavourites);

          // 如果当前选中的 tab 已经不存在了（例如删完某分类），重置到 All
          if (!activeTabs.contains(_selectedType)) {
            _selectedType = 'All';
          }

          // 按选中分类过滤
          final filtered = _selectedType == 'All'
              ? allFavourites
              : allFavourites.where((p) {
                  final types = (p['types'] as List?)
                          ?.map((e) => e.toString())
                          .toList() ??
                      [];
                  return getPlaceCategory(types) == _selectedType;
                }).toList();

          return CustomScrollView(
            slivers: [
              // 大标题
              SliverAppBar(
                expandedHeight: 120.0,
                floating: false,
                pinned: true,
                elevation: 0,
                backgroundColor: Colors.white,
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding:
                      const EdgeInsetsDirectional.only(start: 20, bottom: 16),
                  title: const Text(
                    "My Favourites",
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 24),
                  ),
                ),
                actions: [
                  IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.search, color: Colors.black)),
                ],
              ),

              // ✅ Filter bar — 用 SingleChildScrollView + Row，不用 TabBar/TabController
              SliverToBoxAdapter(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: activeTabs.map((label) {
                        final isSelected = _selectedType == label;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedType = label),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF6366F1)
                                  : Colors.grey[100],
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _tabIcon(label),
                                  size: 15,
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.grey[600],
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.grey[700],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),

              // 空状态
              if (filtered.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.favorite_border,
                            size: 72, color: Colors.grey[300]),
                        const SizedBox(height: 16),
                        Text(
                          _selectedType == 'All'
                              ? 'No favorites yet'
                              : 'This category has no favorites',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[500]),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Browse places and tap ❤️ to favorite',
                          style:
                              TextStyle(fontSize: 14, color: Colors.grey[400]),
                        ),
                      ],
                    ),
                  ),
                )

              // 网格
              else
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.7,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) =>
                          _buildModernCard(context, filtered[index]),
                      childCount: filtered.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildModernCard(BuildContext context, Map<String, dynamic> place) {
    final String placeId = place['placeId'] ?? '';
    final String name = place['name'] ?? 'Unknown';
    final String address = place['address'] ?? '';
    final double? rating = (place['rating'] as num?)?.toDouble();
    final String? photoUrl = place['photoUrl'];
    final double? lat = (place['lat'] as num?)?.toDouble();
    final double? lng = (place['lng'] as num?)?.toDouble();
    final List<String> types =
        (place['types'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final String category = getPlaceCategory(types);
    final destination = FavouriteRouter.classifyDestination(place);

    return GestureDetector(
      onTap: () {
        if (destination == FavouriteDestination.landmarkResult) {
          if (name.isEmpty || name == 'Unknown') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content:
                    Text('Unable to open landmark. Missing landmark details.'),
                behavior: SnackBarBehavior.floating,
              ),
            );
            return;
          }

          final landmarkResult = LandmarkResult(
            landmark: name,
            normalizedName: name,
            rawJson: '',
            lat: lat,
            lng: lng,
            confidence: 1.0,
            method: DetectionMethod.visionLandmark,
          );

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ResultPage(
                imageBytes: null,
                fallbackImageUrl: photoUrl,
                landmarkResult: landmarkResult,
                skipHistorySave: true,
                landmarkId: placeId,
              ),
            ),
          );
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PlaceDetailPage(
                placeId: placeId,
                placeName: name,
                lat: lat,
                lng: lng,
                source: (place['source'] == 'geoapify' ||
                        placeId.startsWith('geo_'))
                    ? 'geoapify'
                    : 'google',
              ),
            ),
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 5)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              // 背景图片
              Positioned.fill(
                child: photoUrl != null
                    ? CachedNetworkImage(
                        imageUrl: photoUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _buildImgPlaceholder(),
                      )
                    : _buildImgPlaceholder(),
              ),

              // 渐变蒙层
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.7)
                      ],
                    ),
                  ),
                ),
              ),

              // 左上角：评分 + 分类标签
              Positioned(
                top: 12,
                left: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (rating != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded,
                                color: Colors.amber, size: 13),
                            const SizedBox(width: 3),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.45),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_tabIcon(category),
                              color: Colors.white70, size: 11),
                          const SizedBox(width: 3),
                          Text(category,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 10)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 右上角：❤️ 收藏按钮
              Positioned(
                top: 4,
                right: 4,
                child: FavouriteButton(
                  placeId: placeId,
                  source: place['source'] as String? ??
                      (destination == FavouriteDestination.landmarkResult
                          ? 'landmark'
                          : 'place'),
                  googlePlaceId: place['googlePlaceId'] as String?,
                  name: name,
                  address: address,
                  rating: rating,
                  photoUrl: photoUrl,
                  lat: lat,
                  lng: lng,
                  types: types,
                  showBackground: false,
                  iconSize: 22,
                  activeColor: Colors.red,
                  inactiveColor: Colors.white70,
                ),
              ),

              // 底部：名称 + 地址
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.location_on,
                            color: Colors.white70, size: 12),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            address,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImgPlaceholder() {
    return Container(
      color: Colors.grey[200],
      child: Icon(Icons.image, size: 40, color: Colors.grey[400]),
    );
  }
}
