import 'package:flutter/material.dart';
import 'package:animated_splash_screen/animated_splash_screen.dart';
import 'package:lottie/lottie.dart';
import 'package:page_transition/page_transition.dart';

import '../../services/authgate_service.dart';
import '../../services/location_service.dart'; // 🆕

class Splashview extends StatefulWidget {           // 🆕 was StatelessWidget
  const Splashview({super.key});

  @override
  State<Splashview> createState() => _SplashviewState();
}

class _SplashviewState extends State<Splashview> {
  @override
  void initState() {
    super.initState();
    // 🆕 Fire-and-forget — by the time the user reaches MainPage/Nearby,
    // permission is already resolved and the first GPS fix is likely in.
    // MainPage's own _initLocation() call later is harmless — initLocation()
    // just cancels/recreates the position stream, so calling it twice is safe.
    LocationService.instance.initLocation();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSplashScreen(
      splash: Center(
        child: Lottie.asset('assets/Map Location Pointer.json'),
      ),
      backgroundColor: Colors.white,
      splashIconSize: 800,
      duration: 2950,
      splashTransition: SplashTransition.fadeTransition,
      pageTransitionType: PageTransitionType.fade,
      nextScreen: const AuthGate(),
    );
  }
}