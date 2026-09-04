import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/navigate_service.dart';

/// Temporary diagnostic overlay for real-device / wireless navigation tests.
///
/// This version refreshes itself every 500 ms as well as listening to the
/// NavigationController. That means GPS age / accepted-progress age can keep
/// increasing on screen even if the navigation controller itself becomes
/// stuck and stops notifying listeners.
class NavigationDebugOverlay extends StatefulWidget {
  final NavigationController nav;

  const NavigationDebugOverlay({
    super.key,
    required this.nav,
  });

  @override
  State<NavigationDebugOverlay> createState() => _NavigationDebugOverlayState();
}

class _NavigationDebugOverlayState extends State<NavigationDebugOverlay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.nav.addListener(_onNavChanged);
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void didUpdateWidget(covariant NavigationDebugOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nav != widget.nav) {
      oldWidget.nav.removeListener(_onNavChanged);
      widget.nav.addListener(_onNavChanged);
    }
  }

  @override
  void dispose() {
    widget.nav.removeListener(_onNavChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _onNavChanged() {
    if (mounted) setState(() {});
  }

  String _fmtDistance(double value) {
    if (!value.isFinite) return '∞';
    return '${value.toStringAsFixed(1)} m';
  }

  String _fmtAge(double value) {
    if (!value.isFinite) return '∞';
    return '${value.toStringAsFixed(1)} s';
  }

  Color _stateColor(String state) {
    switch (state) {
      case 'MATCH':
        return Colors.greenAccent;
      case 'MATCH~':
        return Colors.lightGreenAccent;
      case 'HOLD':
        return Colors.orangeAccent;
      case 'LOW GPS':
        return Colors.amberAccent;
      case 'JOIN ROUTE':
        return Colors.lightBlueAccent;
      case 'OFFLINE':
        return Colors.cyanAccent;
      case 'GPS RECOVER':
        return Colors.purpleAccent;
      case 'REROUTE':
        return Colors.redAccent;
      case 'WAIT GPS':
      case 'WAIT ROUTE':
        return Colors.white70;
      default:
        return Colors.white70;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    final state = nav.debugTrackingState;

    return IgnorePointer(
      child: Container(
        width: 205,
        padding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.74),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withOpacity(0.18),
          ),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10.2,
            height: 1.28,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    'NAV DEBUG',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    state,
                    style: TextStyle(
                      color: _stateColor(state),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Progress  ${nav.debugMatchedProgress.toStringAsFixed(1)} m',
              ),
              Text(
                'Visual    ${nav.displayDistAlongRoute.toStringAsFixed(1)} m',
              ),
              Text(
                'Lag       ${nav.debugVisualLagMeters.toStringAsFixed(1)} m',
              ),
              Text(
                'Vis-Prog  ${nav.debugSignedVisualLeadMeters >= 0 ? "+" : ""}${nav.debugSignedVisualLeadMeters.toStringAsFixed(1)} m',
              ),
              Text(
                'Predict   ${nav.debugPredictionLeadMeters.toStringAsFixed(1)} m',
              ),
              Text(
                'Route gap ${_fmtDistance(nav.debugRawDistanceToRoute)}',
              ),
              Text(
                'Match gap ${_fmtDistance(nav.debugMatchPerpDistance)}',
              ),
              Text(
                'Recovery  ${nav.debugRecoverySeconds.toStringAsFixed(1)} s',
              ),
              Text(
                'GPS age   ${_fmtAge(nav.debugGpsAgeSeconds)}',
              ),
              Text(
                'Fix age   ${_fmtAge(nav.debugNavigationFixAgeSeconds)}',
              ),
              Text(
                'Accept age ${_fmtAge(nav.debugAcceptedProgressAgeSeconds)}',
              ),
              Text(
                'Speed     ${nav.debugSpeedKmh.toStringAsFixed(0)} km/h',
              ),
              Text(
                'GPS ±     ${nav.debugGpsAccuracy.toStringAsFixed(1)} m',
              ),
              Text(
                'Camera    ${nav.debugCameraBearing.toStringAsFixed(0)}°',
              ),
              Text(
                'Handle    ${nav.debugHandleMs.toStringAsFixed(1)} ms',
              ),
              Text(
                'Route#    ${nav.debugRouteVersion}   Pts ${nav.debugRoutePointCount}',
              ),
              Text(
                'Segment   ${nav.debugNearestSegment}   Step ${nav.debugCurrentStepIndex}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
