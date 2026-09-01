// services/connectivity_service.dart
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

/// Single source of truth for device network interface availability.
/// - Does not use arbitrary external HTTP 204 endpoints to gate global network status.
/// - Accurately supports connectivity_plus List<ConnectivityResult>.
/// - Keeps only interface-level state without blocking valid operations.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final Connectivity _connectivity = Connectivity();

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _started = false;
  bool _disposed = false;
  int _latestCheckId = 0;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    _sub = _connectivity.onConnectivityChanged.listen((results) {
      _handleConnectivityResults(results);
    });

    await checkConnectivity();
  }

  /// Checks the current network interface status.
  Future<bool> checkConnectivity() async {
    if (_disposed) return false;
    final checkId = ++_latestCheckId;

    try {
      final results = await _connectivity.checkConnectivity();
      if (!_disposed && checkId == _latestCheckId) {
        _handleConnectivityResults(results);
      }
      return _isOnline;
    } catch (e) {
      debugPrint('Connectivity check failed: $e');
      return _isOnline;
    }
  }

  void _handleConnectivityResults(List<ConnectivityResult> results) {
    if (_disposed) return;

    final hasNetworkInterface = results.any(
      (result) => result != ConnectivityResult.none,
    );

    if (_isOnline != hasNetworkInterface) {
      _isOnline = hasNetworkInterface;
      notifyListeners();
    }
  }

  /// Clears any pending retries (no-op retained for session isolation compatibility).
  void clearPendingRetry() {}

  /// Legacy retry handler (no-op; global banner triggers checkConnectivity directly).
  void retryPendingAction() {}

  @override
  void dispose() {
    _disposed = true;
    _latestCheckId++;
    _sub?.cancel();
    super.dispose();
  }
}
