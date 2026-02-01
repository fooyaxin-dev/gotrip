import 'package:flutter/material.dart';
import 'package:animated_splash_screen/animated_splash_screen.dart';
import 'package:lottie/lottie.dart';
import 'package:page_transition/page_transition.dart';

import '../../services/authgate_service.dart';  // <- 记得 import

class Splashview extends StatelessWidget {
  const Splashview({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedSplashScreen(
      splash: Center(
        child: Lottie.asset(
          'assets/Map Location Pointer.json',
        ),
      ),
      backgroundColor: Colors.white,
      splashIconSize: 800,
      duration: 2950,
      splashTransition: SplashTransition.fadeTransition,
      pageTransitionType: PageTransitionType.fade,

      // ✅ 关键改动：
      nextScreen: const AuthGate(),
    );
  }
}