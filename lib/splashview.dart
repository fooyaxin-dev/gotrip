import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'login.dart';

class Splashview extends StatefulWidget {
  const Splashview({super.key});

  @override
  State<Splashview> createState() => _SplashviewState();
}

class _SplashviewState extends State<Splashview> {

  @override
  void initState() {
    super.initState();

    Timer(const Duration(seconds: 2), () {
      Get.off(LoginPage()); // off = 不回到 splash
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.deepPurpleAccent,
      body: Center(
        child: Text(
          'Splash View',
          style: TextStyle(
            fontSize: 35,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
