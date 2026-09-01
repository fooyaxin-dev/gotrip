import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/services/connectivity_service.dart';
import 'package:gotrip/modules/main/connectivity_banner.dart';
import 'package:gotrip/services/error_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  List<String> mockChannelResults = ['wifi'];
  int checkMethodCallCount = 0;

  setUp(() {
    checkMethodCallCount = 0;
    mockChannelResults = ['wifi'];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'check') {
        checkMethodCallCount++;
        return mockChannelResults;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('Recovery Task 2A: Real Connectivity & Non-Functional Tests', () {
    test('1. Wi-Fi result updates the real service to online', () async {
      mockChannelResults = ['wifi'];
      final service = ConnectivityService.instance;
      final isOnline = await service.checkConnectivity();
      expect(isOnline, isTrue);
      expect(service.isOnline, isTrue);
    });

    test('2. Mobile result updates the real service to online', () async {
      mockChannelResults = ['mobile'];
      final service = ConnectivityService.instance;
      final isOnline = await service.checkConnectivity();
      expect(isOnline, isTrue);
      expect(service.isOnline, isTrue);
    });

    test('3. None result updates the real service to offline', () async {
      mockChannelResults = ['none'];
      final service = ConnectivityService.instance;
      final isOnline = await service.checkConnectivity();
      expect(isOnline, isFalse);
      expect(service.isOnline, isFalse);
    });

    test('4. Mixed results containing a usable interface remain online',
        () async {
      mockChannelResults = ['none', 'wifi'];
      final service = ConnectivityService.instance;
      final isOnline = await service.checkConnectivity();
      expect(isOnline, isTrue);
      expect(service.isOnline, isTrue);
    });

    testWidgets(
        '5. The real banner appears after the real service changes offline',
        (tester) async {
      mockChannelResults = ['wifi'];
      await ConnectivityService.instance.checkConnectivity();

      await tester.pumpWidget(
        const MaterialApp(
          home: ConnectivityBanner(
            child: Scaffold(
              body: Text('Home Content'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In online state, the animated banner slide is off-screen (Offset(0, -1))
      final initialSlide =
          tester.widget<AnimatedSlide>(find.byType(AnimatedSlide));
      expect(initialSlide.offset, const Offset(0, -1));

      // Real service changes to offline
      mockChannelResults = ['none'];
      await ConnectivityService.instance.checkConnectivity();
      await tester.pumpAndSettle();

      // Banner slides down to Offset.zero
      final offlineSlide =
          tester.widget<AnimatedSlide>(find.byType(AnimatedSlide));
      expect(offlineSlide.offset, Offset.zero);
      expect(find.text('No internet connection'), findsOneWidget);
    });

    testWidgets(
        '6. The real banner disappears after the real service changes online',
        (tester) async {
      mockChannelResults = ['none'];
      await ConnectivityService.instance.checkConnectivity();

      await tester.pumpWidget(
        const MaterialApp(
          home: ConnectivityBanner(
            child: Scaffold(
              body: Text('Home Content'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset,
          Offset.zero);

      // Real service recovers to online
      mockChannelResults = ['wifi'];
      await ConnectivityService.instance.checkConnectivity();
      await tester.pumpAndSettle();

      // Banner retracts
      expect(tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset,
          const Offset(0, -1));
    });

    testWidgets(
        '7. Pressing "Check Connection" invokes a real interface recheck',
        (tester) async {
      mockChannelResults = ['none'];
      await ConnectivityService.instance.checkConnectivity();

      await tester.pumpWidget(
        const MaterialApp(
          home: ConnectivityBanner(
            child: Scaffold(
              body: Text('Home Content'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final callsBefore = checkMethodCallCount;

      // Press the real "Check Connection" TextButton on the real banner
      await tester.tap(find.text('Check Connection'));
      await tester.pump();

      expect(checkMethodCallCount, greaterThan(callsBefore));
    });

    test('8. ErrorHandler does not expose raw Firebase error codes', () {
      final rawFirestoreError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
        message:
            'The caller does not have permission to execute the specified operation.',
      );

      final userMessage = ErrorHandler.userFriendlyMessage(rawFirestoreError);

      expect(userMessage.contains('cloud_firestore'), isFalse);
      expect(userMessage.contains('permission-denied'), isFalse);
      expect(userMessage.contains('Exception:'), isFalse);
      expect(userMessage.isNotEmpty, isTrue);

      final rawSocketError =
          Exception('SocketException: Failed host lookup: google.com');
      final networkMessage = ErrorHandler.userFriendlyMessage(rawSocketError);
      expect(networkMessage.contains('SocketException'), isFalse);
    });
  });
}
