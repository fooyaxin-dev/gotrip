import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/favourite_service.dart';
import '../../services/userPreference_service.dart';
import '../../services/error_handler.dart';

/// ❤️ 可复用的收藏按钮
/// showBackground: true  → 白色圆形背景（用于 PlaceCard 图片浮层）
/// showBackground: false → 普通 IconButton（用于 PlaceDetailPage / BottomSheet）
class FavouriteButton extends StatefulWidget {
  final String placeId;
  final String name;
  final String address;
  final double? rating;
  final String? photoUrl;
  final double? lat;
  final double? lng;
  final List<String>? types; // 👈 新增：用于 FavouritePage 分类 filter

  final Color activeColor;
  final Color inactiveColor;
  final double iconSize;
  final bool showBackground;

  const FavouriteButton({
    super.key,
    required this.placeId,
    required this.name,
    required this.address,
    this.rating,
    this.photoUrl,
    this.lat,
    this.lng,
    this.types, // 👈 新增
    this.activeColor = Colors.red,
    this.inactiveColor = Colors.grey,
    this.iconSize = 24,
    this.showBackground = false,
  });

  @override
  State<FavouriteButton> createState() => _FavouriteButtonState();
}

class _FavouriteButtonState extends State<FavouriteButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  bool _isLoading = false;
  bool? _optimisticFavouriteStatus;
  int _operationCount = 0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _animController, curve: Curves.elasticOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleTap(bool currentStatus) async {
    if (_isLoading) return;

    final newStatus = !currentStatus;
    final opId = ++_operationCount;

    _animController.forward().then((_) {
      if (mounted) _animController.reverse();
    });

    setState(() {
      _isLoading = true;
      _optimisticFavouriteStatus = newStatus;
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(newStatus
            ? '❤️ Added to favourites'
            : 'Removed from favourites'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      if (newStatus) {
        await FavouriteService.addFavourite(
          placeId: widget.placeId,
          name: widget.name,
          address: widget.address,
          rating: widget.rating,
          photoUrl: widget.photoUrl,
          lat: widget.lat,
          lng: widget.lng,
          types: widget.types,
        );
      } else {
        await FavouriteService.removeFavourite(widget.placeId);
      }

      // ✅ Secondary background preference learning
      if (widget.types != null) {
        unawaited(_learnFromFavourite(widget.types!, newStatus));
      }

      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted && _operationCount == opId) {
          setState(() {
            _optimisticFavouriteStatus = null;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _optimisticFavouriteStatus = null;
        });
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ErrorHandler.userFriendlyMessage(
                e,
                defaultMessage: 'Unable to update favourite. Please try again.',
              ),
            ),
            backgroundColor: Colors.red[700],
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _isLoading = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _learnFromFavourite(List<String> types, bool isFavouriting) async {
    try {
      await UserPreferenceService.instance.updateFromFavourite(
        primaryType: types.isNotEmpty ? types.first : '',
        allTypes: types,
        isFavouriting: isFavouriting,
      );
    } catch (e) {
      debugPrint('⚠️ Favourite succeeded, but preference learning failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: FavouriteService.getFavouriteStatusStream(widget.placeId),
      builder: (context, snapshot) {
        final isFavFromStream = snapshot.data ?? false;
        final isFav = _optimisticFavouriteStatus ?? isFavFromStream;

        final icon = ScaleTransition(
          scale: _scaleAnimation,
          child: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? widget.activeColor : widget.inactiveColor,
            size: widget.iconSize,
          ),
        );

        if (widget.showBackground) {
          return GestureDetector(
            onTap: _isLoading ? null : () => _handleTap(isFav),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: icon,
            ),
          );
        }

        return IconButton(
          onPressed: _isLoading ? null : () => _handleTap(isFav),
          icon: icon,
        );
      },
    );
  }
}
