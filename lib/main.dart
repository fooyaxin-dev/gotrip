import 'package:flutter/material.dart';
import 'package:get/get_navigation/src/root/get_material_app.dart';
import 'splashview.dart';

void main() {
  runApp(const GoTripApp());
}

class GoTripApp extends StatelessWidget {
  const GoTripApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const GetMaterialApp(
      debugShowCheckedModeBanner: false,
      //title: 'GoTrip FYP',
      //theme: ThemeData(
      //   useMaterial3: true,
      //   scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      //   textTheme: GoogleFonts.poppinsTextTheme(),
      // ),
      home: Splashview(),
    );
  }
}
