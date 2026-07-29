// widgets/connectivity_banner.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../services/connectivity_service.dart';

/// 包在 MaterialApp 最外层，全 app 共用一条离线提示。
/// - 断网时自动从顶部滑出，恢复网络自动收回，不用任何页面手动调用
/// - 页面调用 ConnectivityService.ensureConnected() 时，如果恰好断网，
///   会让这条横幅震一下 + 短暂加亮，抓住用户注意力，
///   而不是在页面里再弹第二条重复的提示
class ConnectivityBanner extends StatefulWidget {
  final Widget child;
  const ConnectivityBanner({super.key, required this.child});

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _attentionController;
  StreamSubscription? _attentionSub;

  @override
  void initState() {
    super.initState();
    ConnectivityService.instance.addListener(_onConnectivityChanged);

    _attentionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    _attentionSub = ConnectivityService.instance.onAttentionRequested.listen((_) {
      if (!ConnectivityService.instance.isOnline) {
        _attentionController.forward(from: 0);
      }
    });
  }

  void _onConnectivityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ConnectivityService.instance.removeListener(_onConnectivityChanged);
    _attentionSub?.cancel();
    _attentionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ConnectivityService.instance.isOnline;

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 0, left: 0, right: 0,
          child: IgnorePointer(
            ignoring: isOnline,
            child: AnimatedBuilder(
              animation: _attentionController,
              builder: (context, banner) {
                // 抖动: 左右轻微摆动，随时间衰减
                final t = _attentionController.value;
                final shakeOffset = sin(t * pi * 6) * 6 * (1 - t);
                // 短暂加亮: 从更亮的红色回落到常态红色
                final highlight = (1 - t).clamp(0.0, 1.0);
                final bgColor = Color.lerp(
                  Colors.red[700],
                  Colors.red[400],
                  highlight,
                )!;

                return Transform.translate(
                  offset: Offset(shakeOffset, 0),
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    offset: isOnline ? const Offset(0, -1) : Offset.zero,
                    child: SafeArea(
                      bottom: false,
                      child: Material(
                        color: bgColor,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Row(children: [
                            const Icon(Icons.wifi_off_rounded,
                                color: Colors.white, size: 16),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text('No internet connection',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 13)),
                            ),
                            TextButton(
                              onPressed: () =>
                                  ConnectivityService.instance.retryPendingAction(),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('Retry',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}