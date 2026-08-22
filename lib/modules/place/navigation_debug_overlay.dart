import 'package:flutter/material.dart';
import '../../services/navigate_service.dart';

/// Temporary diagnostic overlay for real-device / wireless navigation tests.
///
/// Keep this during testing and remove it for the final release.
class NavigationDebugOverlay extends StatelessWidget {
  final NavigationController nav;

  const NavigationDebugOverlay({
    super.key,
    required this.nav,
  });

  String _fmtDistance(double value) {
    if (!value.isFinite) return '∞';
    return '${value.toStringAsFixed(1)} m';
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
    return AnimatedBuilder(
      animation: nav,
      builder: (context, _) {
        final state = nav.debugTrackingState;

        return IgnorePointer(
          child: Container(
            width: 190,
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.72),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.white.withOpacity(0.18),
              ),
            ),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                height: 1.3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text(
                        'NAV DEBUG',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                        ),
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
                    'Route gap ${_fmtDistance(nav.debugRawDistanceToRoute)}',
                  ),
                  Text(
                    'Match gap ${_fmtDistance(nav.debugMatchPerpDistance)}',
                  ),
                  Text(
                    'Recovery  ${nav.debugRecoverySeconds.toStringAsFixed(1)} s',
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
                    'Segment   ${nav.debugNearestSegment}   Step ${nav.debugCurrentStepIndex}',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
