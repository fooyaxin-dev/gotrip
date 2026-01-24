import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'login.dart';
import 'homepage.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // 直接判断 user 是否存在
    if (user != null) {
      return const HomePage();
    } else {
      return const LoginPage();
    }
  }
}

//STREAMBUILDER 版本, NEED MORE TIME BUT GOT REAL TIME FUCNTIONALITY
// import 'package:firebase_auth/firebase_auth.dart';
// import 'package:flutter/material.dart';
// import 'login.dart';
// import 'homepage.dart';

// class AuthGate extends StatelessWidget {
//   const AuthGate({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return StreamBuilder<User?>(
//       stream: FirebaseAuth.instance.authStateChanges(),
//       builder: (context, snapshot) {

//         // 等待状态
//         if (snapshot.connectionState == ConnectionState.waiting) {
//           return const Scaffold(
//             body: Center(child: CircularProgressIndicator()),
//           );
//         }

//         // 如果 10 秒还没返回，就直接跳 Login（防止卡死）
//         if (snapshot.connectionState == ConnectionState.none) {
//           return const LoginPage();
//         }

//         if (snapshot.hasData) {
//           return const HomePage();
//         } else {
//           return const LoginPage();
//         }
//       },
//     );
//   }
// }