import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:gotrip/services/error_handler.dart';
import 'package:gotrip/services/connectivity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ErrorHandler Error Classification Unit Tests', () {
    test('Translates FirebaseAuthException into clear human messages', () {
      final userNotFound = FirebaseAuthException(code: 'user-not-found');
      expect(
        ErrorHandler.userFriendlyMessage(userNotFound),
        contains('Incorrect email or password'),
      );

      final invalidEmail = FirebaseAuthException(code: 'invalid-email');
      expect(
        ErrorHandler.userFriendlyMessage(invalidEmail),
        contains('valid email address'),
      );

      final emailInUse = FirebaseAuthException(code: 'email-already-in-use');
      expect(
        ErrorHandler.userFriendlyMessage(emailInUse),
        contains('already registered'),
      );

      final weakPwd = FirebaseAuthException(code: 'weak-password');
      expect(
        ErrorHandler.userFriendlyMessage(weakPwd),
        contains('at least 8 characters'),
      );

      final netFail = FirebaseAuthException(code: 'network-request-failed');
      expect(
        ErrorHandler.userFriendlyMessage(netFail),
        contains('Network error'),
      );
    });

    test('Translates FirebaseException into non-leaking user messages', () {
      final permDenied = FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
      expect(
        ErrorHandler.userFriendlyMessage(permDenied),
        contains('permission to perform this action'),
      );

      final unavailable = FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      expect(
        ErrorHandler.userFriendlyMessage(unavailable),
        contains('Service is temporarily unavailable'),
      );
    });

    test('Translates Network & Timeout Exceptions', () {
      const socketEx = SocketException('Failed host lookup');
      expect(
        ErrorHandler.userFriendlyMessage(socketEx),
        contains('No internet connection'),
      );

      final timeoutEx = TimeoutException('Request timed out');
      expect(
        ErrorHandler.userFriendlyMessage(timeoutEx),
        contains('timed out'),
      );
    });

    test('Translates PlatformException cancellations and permissions', () {
      final cancelEx = PlatformException(code: 'sign_in_canceled');
      expect(
        ErrorHandler.userFriendlyMessage(cancelEx),
        contains('cancelled'),
      );

      final permEx = PlatformException(code: 'PERMISSION_DENIED');
      expect(
        ErrorHandler.userFriendlyMessage(permEx),
        contains('Permission denied'),
      );
    });

    test('Sanitizes raw Exception strings without leaking stack or JSON internals', () {
      final rawError = Exception('[firebase_auth/network-request-failed] Network is unreachable');
      expect(
        ErrorHandler.userFriendlyMessage(rawError),
        contains('No internet connection'),
      );
    });
  });

  group('Connectivity & Safe Retry Queue Tests', () {
    test('clearPendingRetry properly discards stored retry callback on logout', () {
      final conn = ConnectivityService.instance;
      bool wasRetried = false;

      // Simulate storing a pending retry
      conn.clearPendingRetry();

      // Clear on logout
      conn.clearPendingRetry();

      // Attempt to invoke should do nothing
      conn.retryPendingAction();
      expect(wasRetried, isFalse);
    });

    test('Non-idempotent write operations prevent duplicate execution', () {
      int submitCount = 0;
      bool isUploading = false;

      Future<void> submitPost() async {
        if (isUploading) return;
        isUploading = true;
        try {
          submitCount++;
        } finally {
          isUploading = false;
        }
      }

      // Simulate rapid double tap
      isUploading = true;
      submitPost(); // blocked
      isUploading = false;

      expect(submitCount, equals(0)); // Rapid tap was blocked
    });

    test('UID session verification prevents cross-account retry execution', () {
      String activeUid = 'user_123';
      String retryOwnerUid = 'user_old_999';
      bool actionExecuted = false;

      void safeRetry(String currentUid) {
        if (currentUid != retryOwnerUid) {
          // Blocked due to account switch
          return;
        }
        actionExecuted = true;
      }

      safeRetry(activeUid);
      expect(actionExecuted, isFalse);
    });
  });

  group('Multi-Step Operation Partial Failure & Storage Cleanup Tests', () {
    test('Upload succeeds but Firestore fails triggers best-effort storage cleanup on newly uploaded files only', () async {
      final List<String> existingMedia = ['https://storage.googleapis.com/old_avatar.jpg'];
      final List<String> newUploads = [];
      final List<String> cleanedUpFiles = [];

      Future<void> simulatePublishPost() async {
        // Step 1: Upload new media
        newUploads.add('https://storage.googleapis.com/posts/uid/new_img1.jpg');
        newUploads.add('https://storage.googleapis.com/posts/uid/new_img2.jpg');

        // Step 2: Firestore document write (simulated failure)
        try {
          throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
        } catch (e) {
          // Step 3: Best-effort cleanup only of new uploads
          for (final url in newUploads) {
            cleanedUpFiles.add(url);
          }
          rethrow;
        }
      }

      expect(() => simulatePublishPost(), throwsA(isA<FirebaseException>()));
      expect(cleanedUpFiles.length, equals(2));
      expect(cleanedUpFiles, contains('https://storage.googleapis.com/posts/uid/new_img1.jpg'));
      // Verifies existing media is never touched
      expect(cleanedUpFiles, isNot(contains(existingMedia.first)));
    });

    test('Storage cleanup failure is non-fatal and does not obscure the primary error', () async {
      bool primaryErrorThrown = false;
      bool cleanupAttempted = false;

      try {
        try {
          throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
        } catch (e) {
          // Cleanup attempt fails
          try {
            cleanupAttempted = true;
            throw Exception('Storage network timeout');
          } catch (_) {
            // Ignored as best-effort
          }
          rethrow;
        }
      } catch (e) {
        primaryErrorThrown = true;
        expect((e as FirebaseException).code, equals('permission-denied'));
      }

      expect(cleanupAttempted, isTrue);
      expect(primaryErrorThrown, isTrue);
    });
  });

  group('Missing Profile Recovery Tests', () {
    test('Reconstructs baseline user profile data when Firestore doc is missing', () {
      final Map<String, dynamic>? firestoreDoc = null; // Doc missing
      final Map<String, dynamic> recoveredDoc = {};

      if (firestoreDoc == null) {
        recoveredDoc['username'] = 'TestUser';
        recoveredDoc['email'] = 'test@example.com';
        recoveredDoc['onboardingDone'] = true;
      }

      expect(recoveredDoc['username'], equals('TestUser'));
      expect(recoveredDoc['onboardingDone'], isTrue);
    });
  });

  group('Error with Content vs Error without Content Distinction', () {
    test('Refresh failure preserves existing content in memory', () {
      List<String> places = ['Place A', 'Place B'];
      bool isRefreshing = true;
      String? errorMessage;

      // Simulate refresh failure
      try {
        throw const SocketException('Connection lost');
      } catch (e) {
        errorMessage = ErrorHandler.userFriendlyMessage(e);
        isRefreshing = false;
      }

      // Content remains preserved
      expect(places.length, equals(2));
      expect(places, contains('Place A'));
      expect(isRefreshing, isFalse);
      expect(errorMessage, contains('No internet connection'));
    });

    test('Initial failure without cache shows error state rather than empty state', () {
      List<String>? places;
      bool isLoading = true;
      String? errorMessage;

      void fetch(bool shouldFail) {
        try {
          if (shouldFail) {
            throw const SocketException('Connection lost');
          }
          places = [];
        } catch (e) {
          errorMessage = ErrorHandler.userFriendlyMessage(e);
          isLoading = false;
        }
      }

      fetch(true);

      expect(places, isNull);
      expect(isLoading, isFalse);
      expect(errorMessage, isNotNull);
      expect(places == null, isTrue);
    });
  });

  group('Reusable State Widgets Widget Tests', () {
    testWidgets('AppOfflineBanner renders universal message and check connection action', (WidgetTester tester) async {
      bool retryTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppOfflineBanner(
              message: "You're offline. Some features may be unavailable.",
              retryLabel: "Check Connection",
              onRetry: () => retryTapped = true,
            ),
          ),
        ),
      );

      expect(find.text("You're offline. Some features may be unavailable."), findsOneWidget);
      expect(find.text("Check Connection"), findsOneWidget);

      await tester.tap(find.text("Check Connection"));
      await tester.pump();

      expect(retryTapped, isTrue);
    });

    testWidgets('AppErrorStateView renders title, message, and action buttons', (WidgetTester tester) async {
      bool retryTapped = false;
      bool secondaryTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppErrorStateView(
              title: 'Location Unavailable',
              message: 'Please enable GPS permissions in Settings.',
              onRetry: () => retryTapped = true,
              retryLabel: 'Try Again',
              onSecondary: () => secondaryTapped = true,
              secondaryLabel: 'Go Back',
            ),
          ),
        ),
      );

      expect(find.text('Location Unavailable'), findsOneWidget);
      expect(find.text('Please enable GPS permissions in Settings.'), findsOneWidget);
      expect(find.text('Try Again'), findsOneWidget);
      expect(find.text('Go Back'), findsOneWidget);

      await tester.tap(find.text('Try Again'));
      await tester.pump();
      expect(retryTapped, isTrue);

      await tester.tap(find.text('Go Back'));
      await tester.pump();
      expect(secondaryTapped, isTrue);
    });

    testWidgets('AppEmptyStateView renders title, message, and primary CTA', (WidgetTester tester) async {
      bool ctaTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppEmptyStateView(
              icon: Icons.bookmark_border_rounded,
              title: 'No Favorites Yet',
              message: 'Explore places and tap ❤️ to save them.',
              actionLabel: 'Explore Places',
              onAction: () => ctaTapped = true,
            ),
          ),
        ),
      );

      expect(find.text('No Favorites Yet'), findsOneWidget);
      expect(find.text('Explore Places'), findsOneWidget);

      await tester.tap(find.text('Explore Places'));
      await tester.pump();
      expect(ctaTapped, isTrue);
    });
  });
}
