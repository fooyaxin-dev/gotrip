import 'package:flutter/material.dart';
import '../../services/favourite_service.dart';

/// ❤️ 可复用的收藏按钮组件
/// 支持两种模式：
///   - IconButton 模式（用于 PlaceDetailPage 标题栏）
///   - Overlay 模式（用于 PlaceCard 右上角浮层）
/// 
class FavouriteButton extends StatefulWidget {
  final String placeId;
  final String name;
  final String address;
  final double? rating;
  final String? photoUrl;
  final double? lat;
  final double? lng;

  /// 外观控制
  final Color activeColor;
  final Color inactiveColor;
  final double iconSize;
  final bool showBackground; // true = 显示圆形背景（用于卡片浮层）

  const FavouriteButton({
    super.key,
    required this.placeId,
    required this.name,
    required this.address,
    this.rating,
    this.photoUrl,
    this.lat,
    this.lng,
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

    // 播放动画
    _animController.forward().then((_) => _animController.reverse());

    setState(() => _isLoading = true);

    try {
      final newStatus = await FavouriteService.toggleFavourite(
        placeId: widget.placeId,
        name: widget.name,
        address: widget.address,
        rating: widget.rating,
        photoUrl: widget.photoUrl,
        lat: widget.lat,
        lng: widget.lng,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newStatus ? '❤️ 已添加到收藏' : '已取消收藏'),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('操作失败，请重试'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: FavouriteService.getFavouriteStatusStream(widget.placeId),
      builder: (context, snapshot) {
        final isFav = snapshot.data ?? false;

        final icon = ScaleTransition(
          scale: _scaleAnimation,
          child: _isLoading
              ? SizedBox(
                  width: widget.iconSize,
                  height: widget.iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: widget.activeColor,
                  ),
                )
              : Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  color: isFav ? widget.activeColor : widget.inactiveColor,
                  size: widget.iconSize,
                ),
        );

        // 带背景模式（用于卡片浮层）
        if (widget.showBackground) {
          return GestureDetector(
            onTap: () => _handleTap(isFav),
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

        // 普通 IconButton 模式（用于 DetailPage）
        return IconButton(
          onPressed: () => _handleTap(isFav),
          icon: icon,
        );
      },
    );
  }
}