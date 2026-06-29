import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/userPreference_service.dart';
import '../modules/login_logout/login.dart';
import '../modules/main/homepage.dart';
import '../modules/main/onBoarding.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {

        // ── Waiting for Firebase to restore session ──────────────────────
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF7C4DFF)),
            ),
          );
        }

        // ── No session — go to login ─────────────────────────────────────
        if (!snapshot.hasData || snapshot.data == null) {
          return const LoginPage();
        }

        final user = snapshot.data!;

        // ── Email/password user who hasn't verified yet ──────────────────
        // Google users are inherently verified, skip this check for them
        if (!user.emailVerified && !_isGoogleUser(user)) {
          FirebaseAuth.instance.signOut();
          return const LoginPage();
        }

        // ── Valid session — check onboarding state ───────────────────────
        return FutureBuilder(
          future: UserPreferenceService.instance.load(),
          builder: (context, prefSnapshot) {
            if (prefSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(color: Color(0xFF7C4DFF)),
                ),
              );
            }
            final prefs = prefSnapshot.data;
            if (prefs == null || !prefs.onboardingDone) {
              return const OnboardingPage();
            }
            return const HomePage();
          },
        );
      },
    );
  }

  bool _isGoogleUser(User user) {
    return user.providerData.any((info) => info.providerId == 'google.com');
  }
}