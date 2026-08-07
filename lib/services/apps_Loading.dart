// lib/widgets/app_loading.dart
//
// ─────────────────────────────────────────────────────────────────
// 统一 Loading 组件（自动居中版）
//
// 规则很简单：
//   - 没给 size          → 自动撑满父容器可用空间，并把动画居中
//                          （放进 SizedBox / Scaffold body / Center 都不用再手动包 Center）
//   - 给了 size（内联场景，比如按钮里）→ 就是一个固定尺寸的小widget，
//                          不会自己去抢占/居中整个父容器空间，跟原本
//                          CircularProgressIndicator 内联时的行为一致
//
// 用法：
//   全屏/整块居中：
//     之前: Center(child: CircularProgressIndicator())
//     之后: const AppLoading()                        // 不用再手动包 Center 了
//
//   按钮/小尺寸内联：
//     之前: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
//     之后: const AppLoading(size: 20)
// ─────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class TravelLoadingIndicator extends StatelessWidget {
  final double? size;
  final Color? color; 
  static const String _animationPath = 'assets/loading_cat.json';

  // 🆕 低于这个尺寸，Lottie 插画会被压得看不清，改用简洁的圆圈转圈
  static const double _smallSizeThreshold = 40;

  const TravelLoadingIndicator({super.key, this.size, this.color});

  @override
  Widget build(BuildContext context) {
    // 🆕 小尺寸场景（按钮/inline 加载）——用标准圆圈，不用插画动画
    if (size != null && size! <= _smallSizeThreshold) {
      return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          valueColor: AlwaysStoppedAnimation<Color>(
            color ?? Colors.white,   // 默认仍是白色，不破坏其它调用点
          ),
        ),
      );
    }

    final double displaySize = size ?? 290;

    final animation = Lottie.asset(
      _animationPath,
      width: displaySize,
      height: displaySize,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => SizedBox(
        width: displaySize,
        height: displaySize,
        child: Lottie.asset(
          'assets/travelLoading.json',
          width: size,
          height: size,
          fit: BoxFit.contain,
          repeat: true,
        ),
      ),
    );

    if (size == null) {
      return Center(child: animation);
    }
    return animation;
  }
}