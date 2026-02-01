import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get_navigation/src/root/get_material_app.dart';
import 'modules/main/splashview.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const GoTripApp());
}

class GoTripApp extends StatelessWidget {
  const GoTripApp({super.key});
  
  get GoogleFonts => null;

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Color(0xFFF1F1F1),
        // 你可以顺便统一字体（可选）
        //textTheme: GoogleFonts.poppinsTextTheme(),
      ),
      home: Splashview(),
    );

  }
}
