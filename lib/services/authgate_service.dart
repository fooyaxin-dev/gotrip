import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/userPreference_service.dart';
import '../modules/login_logout/login.dart';
import '../modules/main/homepage.dart';
import '../modules/main/onBoarding.dart';
import '../../services/apps_Loading.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  static String _onboardingDoneKey(String uid) => 'cached_onboarding_done_$uid';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {

        // ── Waiting for Firebase to restore session ──────────────────────
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: TravelLoadingIndicator(),
            ),
          );
        }

        // ── No session — go to login ─────────────────────────────────────
        if (!snapshot.hasData || snapshot.data == null) {
          return const LoginPage();
        }

        final user = snapshot.data!;

        // ── Email/password user who hasn't verified yet ──────────────────
        if (!user.emailVerified && !_isGoogleUser(user)) {
          FirebaseAuth.instance.signOut();
          return const LoginPage();
        }

        // ── Valid session — decide instantly if possible, else check once ──
        return FutureBuilder<bool?>(
          future: _getCachedOnboardingDone(user.uid),
          builder: (context, cacheSnapshot) {
            if (cacheSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(color: Color(0xFF7C4DFF)),
                ),
              );
            }

            final cachedDone = cacheSnapshot.data;

            // 🚀 Fast path: we already know the answer locally for THIS uid.
            // Enter immediately, load full preferences in the background —
            // UserPreferenceService.preferencesChanged notifies listeners
            // once the real data (categories/cuisines/etc) has arrived.
            if (cachedDone != null) {
              UserPreferenceService.instance.load(); // fire-and-forget
              return cachedDone ? const HomePage() : const OnboardingPage();
            }

            // 🐢 Slow path: first time on this device for this uid —
            // wait for Firestore once, then cache the result for next launch.
            return FutureBuilder<UserPreferences>(
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
                final done = prefs?.onboardingDone ?? false;
                _cacheOnboardingDone(user.uid, done); // fire-and-forget

                return done ? const HomePage() : const OnboardingPage();
              },
            );
          },
        );
      },
    );
  }

  bool _isGoogleUser(User user) {
    return user.providerData.any((info) => info.providerId == 'google.com');
  }

  Future<bool?> _getCachedOnboardingDone(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _onboardingDoneKey(uid);
    if (!prefs.containsKey(key)) return null;
    return prefs.getBool(key);
  }

  Future<void> _cacheOnboardingDone(String uid, bool done) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingDoneKey(uid), done);
  }
}