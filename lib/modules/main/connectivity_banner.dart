// widgets/connectivity_banner.dart
import 'package:flutter/material.dart';
import '../../services/connectivity_service.dart';

/// Wrapped at the root level (MaterialApp.builder), providing a single global offline banner.
/// - Automatically slides down from the top when device network interface is absent.
/// - Automatically retracts when network interface returns.
/// - Retry button rechecks network interface connectivity.
class ConnectivityBanner extends StatefulWidget {
  final Widget child;
  const ConnectivityBanner({super.key, required this.child});

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner> {
  @override
  void initState() {
    super.initState();
    ConnectivityService.instance.addListener(_onConnectivityChanged);
  }

  void _onConnectivityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ConnectivityService.instance.removeListener(_onConnectivityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ConnectivityService.instance.isOnline;

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: isOnline,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              offset: isOnline ? const Offset(0, -1) : Offset.zero,
              child: SafeArea(
                bottom: false,
                child: Material(
                  color: Colors.red[700],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.wifi_off_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'No internet connection',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              ConnectivityService.instance.checkConnectivity(),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 0),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'Check Connection',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
