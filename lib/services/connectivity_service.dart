// services/connectivity_service.dart
import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

class ConnectivityService extends ChangeNotifier {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final Connectivity _connectivity = Connectivity();

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _offlineRecheckTimer;

  bool _started = false;
  bool _disposed = false;

  // 每次检测都会取得新的编号。只有最后一次检测可以更新全局状态，
  // 避免较慢的旧检测覆盖较新的检测结果。
  int _latestCheckId = 0;

  static const Duration _probeTimeout = Duration(seconds: 4);
  static const Duration _offlineRecheckInterval = Duration(seconds: 10);

  // 这两个地址正常联网时会返回 HTTP 204。
  // 使用 HTTPS 也可以避免大部分 captive portal 登录页被误判为联网。
  static final List<Uri> _probeUrls = <Uri>[
    Uri.parse('https://clients3.google.com/generate_204'),
    Uri.parse('https://connectivitycheck.gstatic.com/generate_204'),
  ];

  // 全局横幅监听这个流，收到事件后提示用户注意断网状态。
  final StreamController<void> _attentionController =
      StreamController<void>.broadcast();
  Stream<void> get onAttentionRequested => _attentionController.stream;

  // 存住最后一个因断网而失败的操作，供横幅 Retry 按钮使用。
  VoidCallback? _pendingRetry;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    // 先订阅，避免初始检测期间错过网络变化事件。
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      unawaited(_refreshConnectivity(knownResults: results));
    });

    await _refreshConnectivity();
  }

  /// 同时检查：
  /// 1. 手机是否连接了 Wi-Fi / mobile data 等网络接口；
  /// 2. 该网络是否真的可以访问 Internet。
  Future<bool> _refreshConnectivity({
    List<ConnectivityResult>? knownResults,
  }) async {
    if (_disposed) return false;

    final int checkId = ++_latestCheckId;

    try {
      final results =
          knownResults ?? await _connectivity.checkConnectivity();

      final hasNetworkInterface = results.any(
        (result) => result != ConnectivityResult.none,
      );

      final online =
          hasNetworkInterface && await _hasActualInternetAccess();

      // 只允许最新检测提交状态。
      if (!_disposed && checkId == _latestCheckId) {
        _setOnline(online);
        return online;
      }

      // 如果这次检测已经过期，返回目前最新的全局状态。
      return _isOnline;
    } catch (error) {
      debugPrint('Connectivity check failed: $error');

      if (!_disposed && checkId == _latestCheckId) {
        _setOnline(false);
        return false;
      }

      return _isOnline;
    }
  }

  Future<bool> _hasActualInternetAccess() async {
    final results = await Future.wait(
      _probeUrls.map(_probeUrl),
    );
    return results.any((success) => success);
  }

  Future<bool> _probeUrl(Uri uri) async {
    final client = HttpClient()..connectionTimeout = _probeTimeout;

    try {
      final request = await client.getUrl(uri).timeout(_probeTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

      final response = await request.close().timeout(_probeTimeout);
      await response.drain<void>();

      return response.statusCode == HttpStatus.noContent;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _setOnline(bool value) {
    if (_disposed) return;

    if (value) {
      // 网络恢复后，旧操作不应一直留在 Retry 按钮中。
      _pendingRetry = null;
      _offlineRecheckTimer?.cancel();
      _offlineRecheckTimer = null;
    } else {
      // Wi-Fi 仍连接但 Internet 后来恢复时，connectivity_plus 不一定会
      // 发出接口变化事件，因此离线期间定时重新做真实连通测试。
      _offlineRecheckTimer ??= Timer.periodic(
        _offlineRecheckInterval,
        (_) => unawaited(_refreshConnectivity()),
      );
    }

    if (_isOnline == value) return;

    _isOnline = value;
    notifyListeners();
  }

  /// 断网时不自己弹 SnackBar，由全局横幅统一显示。
  ///
  /// 返回 true 代表目前真的可以访问 Internet；返回 false 时会保存
  /// onRetry，并通知横幅提示用户。
  Future<bool> ensureConnected(
    BuildContext context, {
    VoidCallback? onRetry,
  }) async {
    final online = await _refreshConnectivity();

    if (online) return true;

    _pendingRetry = onRetry;
    if (!_disposed) {
      _attentionController.add(null);
    }
    return false;
  }

  /// 横幅上的 Retry 按钮调用这个方法。
  /// 会先重新确认网络，成功后才执行原本失败的操作。
  void retryPendingAction() {
    if (_disposed) return;

    final action = _pendingRetry;
    _pendingRetry = null;
    unawaited(_retryAfterConnectivityCheck(action));
  }

  Future<void> _retryAfterConnectivityCheck(VoidCallback? action) async {
    final online = await _refreshConnectivity();

    if (online) {
      action?.call();
      return;
    }

    // 仍然离线时保留原操作，让用户稍后可以再试。
    _pendingRetry ??= action;
    if (!_disposed) {
      _attentionController.add(null);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _latestCheckId++;
    _offlineRecheckTimer?.cancel();
    _sub?.cancel();
    _attentionController.close();
    super.dispose();
  }
}
