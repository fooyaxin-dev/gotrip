import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:get/get_navigation/src/root/get_material_app.dart';
import 'modules/main/splashview.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart'; // 🆕
import 'services/firebase_options.dart';
import 'services/connectivity_service.dart'; // 🆕
import 'modules/main/connectivity_banner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 🆕 让 Flutter 框架层面的报错（比如 build() 里抛出的异常）
  // 自动上报给 Crashlytics
  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
  };

  // 🆕 让 Flutter 框架以外的报错（比如异步代码、isolate 里的错误）
  // 也自动上报
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  ConnectivityService.instance.start();

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
      ),
      builder: (context, child) {
        return ConnectivityBanner(child: child!);
      },
      home: Splashview(),
    );
  }
}
