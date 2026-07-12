// widgets/travel_loading_indicator.dart
//
// Drop-in replacement for TravelLoadingIndicator().
// Uses the "Purple Globe Airplane Travel Loader" Lottie animation.
//
// Setup:
// 1. Put travelLoading.json into your assets folder, e.g. assets/animations/travelLoading.json
// 2. Register it in pubspec.yaml:
//      flutter:
//        assets:
//          - assets/animations/travelLoading.json
// 3. Make sure the `lottie` package is in pubspec.yaml (it already is elsewhere in this project).
// 4. Import this file wherever TravelLoadingIndicator() used to be called, e.g.:
//      import '../../widgets/travel_loading_indicator.dart';
//    (adjust the relative path to match where you place this file)

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class TravelLoadingIndicator extends StatelessWidget {
  final double size;

  const TravelLoadingIndicator({super.key, this.size = 250}); // size control !!! 

  @override
  Widget build(BuildContext context) {
    return Lottie.asset(
      'assets/travelLoading.json',
      width: size,
      height: size,
      fit: BoxFit.contain,
      repeat: true,
    );
  }
}