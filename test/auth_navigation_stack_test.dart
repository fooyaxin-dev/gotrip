import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Authentication Navigation Stack Lifecycle Tests [Widget / Navigation Test]', () {
    testWidgets('Entering Home via pushAndRemoveUntil clears all Auth routes from stack',
        (tester) async {
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Text('Login Screen Root')),
        ),
      );

      expect(find.text('Login Screen Root'), findsOneWidget);

      // 1. User taps Sign Up (pushed to stack)
      navKey.currentState!.push(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Signup Screen')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Signup Screen'), findsOneWidget);

      // 2. Signup finishes -> Pops back or pushAndRemoveUntil to Onboarding
      navKey.currentState!.pushReplacement(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Onboarding Screen')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Onboarding Screen'), findsOneWidget);

      // 3. User finishes Onboarding -> pushAndRemoveUntil to HomePage
      navKey.currentState!.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Home Page Root')),
        ),
        (route) => false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Home Page Root'), findsOneWidget);

      // 4. Simulate Android System Back button on Home
      final didPop = await navKey.currentState!.maybePop();

      // Confirm Android Back cannot pop Home to reveal Login, Signup or Onboarding
      expect(didPop, isFalse);
      expect(find.text('Home Page Root'), findsOneWidget);
      expect(find.text('Login Screen Root'), findsNothing);
      expect(find.text('Signup Screen'), findsNothing);
      expect(find.text('Onboarding Screen'), findsNothing);
    });

    testWidgets('Logout via pushAndRemoveUntil clears all Authenticated routes from stack',
        (tester) async {
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Text('Home Screen')),
        ),
      );

      // User visits Profile
      navKey.currentState!.push(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Profile Screen')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Profile Screen'), findsOneWidget);

      // User triggers Logout (pushAndRemoveUntil LoginPage)
      navKey.currentState!.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Login Screen')),
        ),
        (route) => false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Login Screen'), findsOneWidget);

      // Android Back from Login cannot return to Profile or Home
      final didPop = await navKey.currentState!.maybePop();
      expect(didPop, isFalse);
      expect(find.text('Login Screen'), findsOneWidget);
      expect(find.text('Home Screen'), findsNothing);
      expect(find.text('Profile Screen'), findsNothing);
    });
  });
}
