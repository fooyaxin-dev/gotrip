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
  /// 不传 = 自动居中撑满可用空间；传了 = 固定小尺寸内联显示
  final double? size;

  static const String _animationPath = 'assets/loading_cat.json';

  const TravelLoadingIndicator({super.key, this.size});

  @override
  Widget build(BuildContext context) {
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

    // 没给固定 size → 自己负责在可用空间里居中，调用方不用再包 Center
    if (size == null) {
      return Center(child: animation);
    }

    // 给了 size → 当作普通内联小 widget，位置交给调用方（Row/按钮等）决定
    return animation;
  }
}