// services/connectivity_service.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService extends ChangeNotifier {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _started = false;

  // 🆕 全局横幅监听这个流，收到事件就"抖一下"抓注意力
  final _attentionController = StreamController<void>.broadcast();
  Stream<void> get onAttentionRequested => _attentionController.stream;

  // 🆕 存住调用方给的 retry 回调，横幅上的 Retry 按钮直接调这个
  VoidCallback? _pendingRetry;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final initial = await Connectivity().checkConnectivity();
    _isOnline = !initial.contains(ConnectivityResult.none);

    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final nowOnline = !results.contains(ConnectivityResult.none);
      if (nowOnline != _isOnline) {
        _isOnline = nowOnline;
        notifyListeners();
      }
    });
  }

  /// 断网时不再自己弹 SnackBar —— 全局横幅已经在顶部显示了。
  /// 这里只做两件事：
  /// 1. 存住 onRetry，横幅上的 Retry 按钮点击时会调用它
  /// 2. 广播一个"引起注意"事件，让横幅抖一下/亮一下，
  ///    告诉用户"你刚才点的那个操作，就是因为这个原因失败的"
  Future<bool> ensureConnected(
    BuildContext context, {
    VoidCallback? onRetry,
  }) async {
    final result = await Connectivity().checkConnectivity();
    final online = !result.contains(ConnectivityResult.none);

    if (online) return true;

    _pendingRetry = onRetry;
    _attentionController.add(null);
    return false;
  }

  /// 横幅上的 Retry 按钮调这个
  void retryPendingAction() {
    _pendingRetry?.call();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _attentionController.close();
    super.dispose();
  }
}