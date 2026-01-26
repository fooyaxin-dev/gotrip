import 'package:flutter/material.dart';
import 'login.dart';
import 'package:animated_splash_screen/animated_splash_screen.dart';
import 'package:lottie/lottie.dart'; 
import 'package:page_transition/page_transition.dart';

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
      duration: 4000,
      splashTransition: SplashTransition.fadeTransition,
      pageTransitionType: PageTransitionType.fade,
      nextScreen: const LoginPage(),
    );
  }
}