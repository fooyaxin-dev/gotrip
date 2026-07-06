import 'dart:async';
import 'package:flutter/material.dart';

/// A tiny, reusable debouncer.
///
/// Call `debouncer.run(() { ... })` every time the value changes (e.g. every
/// tick while the user drags a slider). The passed callback only actually
/// fires once no new call has come in for `delay` — so if the user is still
/// dragging, every earlier call gets cancelled and only the final one runs.
///
/// Usage:
/// ```dart
/// final _radiusDebouncer = Debouncer(delay: const Duration(milliseconds: 300));
///
/// @override
/// void dispose() {
///   _radiusDebouncer.dispose(); // 🔒 always dispose to cancel any pending timer
///   super.dispose();
/// }
///
/// Slider(
///   value: _radius,
///   onChanged: (v) {
///     setState(() => _radius = v); // ← update the UI (label / circle) instantly
///     _radiusDebouncer.run(() {
///       // ← only actually fires 300ms after the user stops moving the slider
///       NearbyPlacesService.instance.loadNearbyPlacesOnce(
///         categories,
///         context,
///         radius: _radius.round(),
///       );
///     });
///   },
/// )
/// ```
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 300)});

  final Duration delay;
  Timer? _timer;

  /// Cancels any pending call and schedules a new one `delay` from now.
  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Cancels any pending call without scheduling a new one.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Call from your State's dispose() to avoid a setState-after-dispose
  /// crash if the widget is torn down while a debounced call is still
  /// pending.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}