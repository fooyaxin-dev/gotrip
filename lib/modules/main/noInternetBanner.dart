// modules/main/noInternetBanner.dart
//
// 断网时自动浮现的轻量提示条，恢复网络后自动消失。
// 用法：把它包在整个 app 的最外层（HomePage 那一层），
// 断网状态会对所有 tab 都生效，不用每个页面单独处理。

import 'package:flutter/material.dart';
import '../../services/connectivity_service.dart';
 
class NoInternetBanner extends StatelessWidget {
  final Widget child;
  const NoInternetBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ConnectivityService.instance,
      builder: (context, _) {
        final isOnline = ConnectivityService.instance.isOnline;
        return Stack(
          children: [
            child,
            if (!isOnline)
              Positioned(
                top: 0, left: 0, right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    width: double.infinity,
                    color: Colors.red[700],
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi_off_rounded,
                            color: Colors.white, size: 16),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'No internet connection',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            // 手动触发一次刷新检查（用户点「重试」时）
                            ConnectivityService.instance.start();
                          },
                          child: const Text(
                            'Retry',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}