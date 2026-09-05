import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/modules/place/placeDetailPage.dart';

void main() {
  final sampleReasons = [
    'Highly rated place matching your preferred categories: historical landmark, culture, museum.',
    'Matches your preferred travel mode and distance radius preference for today.',
    'Consistently popular among travelers who appreciate architectural heritage and quiet exploration.',
  ];

  final mondayPeriod = {
    'open': {'day': 1, 'hour': 9, 'minute': 0},
    'close': {'day': 1, 'hour': 17, 'minute': 0},
  };

  final openPlaceDetail = {
    'utcOffsetMinutes': 0,
    'regularOpeningHours': {
      'periods': [mondayPeriod],
    },
  };

  final closedPlaceDetail = {
    'utcOffsetMinutes': 0,
    'regularOpeningHours': {
      'periods': [mondayPeriod],
    },
  };

  final openNowUtc = DateTime.utc(2026, 9, 7, 11, 0); // Monday 11:00 -> Open
  final closedNowUtc =
      DateTime.utc(2026, 9, 7, 20, 0); // Monday 20:00 -> Closed

  Future<void> pumpResponsiveWidget(
    WidgetTester tester, {
    required Widget child,
    required double width,
    required double textScale,
  }) async {
    tester.view.physicalSize = Size(width * 3.0, 800 * 3.0);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('WhyRecommendedCard responsive tests', () {
    testWidgets('WhyRecommendedCard at 320px, scale 1.0 has no exception',
        (tester) async {
      await pumpResponsiveWidget(
        tester,
        child: const WhyRecommendedCard(
          matchTier: 'Top Match',
          explanationReasons: ['Matches your interest in museums.'],
        ),
        width: 320,
        textScale: 1.0,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Why this was recommended'), findsOneWidget);
      expect(find.text('Top Match'), findsOneWidget);
      expect(find.text('Matches your interest in museums.'), findsOneWidget);
    });

    testWidgets('WhyRecommendedCard at 320px, scale 1.5 has no exception',
        (tester) async {
      await pumpResponsiveWidget(
        tester,
        child: const WhyRecommendedCard(
          matchTier: 'High Match',
          explanationReasons: ['Matches your interest in historic landmarks.'],
        ),
        width: 320,
        textScale: 1.5,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Why this was recommended'), findsOneWidget);
      expect(find.text('High Match'), findsOneWidget);
    });

    testWidgets('WhyRecommendedCard at 320px, scale 2.0 has no exception',
        (tester) async {
      await pumpResponsiveWidget(
        tester,
        child: const WhyRecommendedCard(
          matchTier: 'Top Match',
          explanationReasons: ['Matches your interest in scenic viewpoints.'],
        ),
        width: 320,
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Why this was recommended'), findsOneWidget);
      expect(find.text('Top Match'), findsOneWidget);
    });

    testWidgets('Long matchTier at 320px does not overflow', (tester) async {
      const longTier =
          'Exceptionally High Match for Culture, History & Architecture Enthusiasts';
      await pumpResponsiveWidget(
        tester,
        child: const WhyRecommendedCard(
          matchTier: longTier,
          explanationReasons: ['Great cultural site to explore today.'],
        ),
        width: 320,
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Why this was recommended'), findsOneWidget);
      expect(find.text(longTier), findsOneWidget);
    });

    testWidgets('Multiple long reasons remain present and not truncated',
        (tester) async {
      await pumpResponsiveWidget(
        tester,
        child: WhyRecommendedCard(
          matchTier: 'Top Match',
          explanationReasons: sampleReasons,
        ),
        width: 320,
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
      for (final reason in sampleReasons) {
        expect(find.text(reason), findsOneWidget);
      }
      expect(find.text('Why this was recommended'), findsOneWidget);
      expect(find.text('Top Match'), findsOneWidget);
    });

    // Matrix tests across all required widths and text scales
    const testWidths = [320.0, 360.0, 393.0, 412.0];
    const testScales = [1.0, 1.3, 1.5, 2.0];

    for (final w in testWidths) {
      for (final s in testScales) {
        testWidgets('WhyRecommendedCard layout matrix width ${w}px scale $s',
            (tester) async {
          await pumpResponsiveWidget(
            tester,
            child: WhyRecommendedCard(
              matchTier: 'Very High Match',
              explanationReasons: sampleReasons,
            ),
            width: w,
            textScale: s,
          );

          expect(tester.takeException(), isNull);
          expect(find.text('Why this was recommended'), findsOneWidget);
          expect(find.text('Very High Match'), findsOneWidget);
          for (final reason in sampleReasons) {
            expect(find.text(reason), findsOneWidget);
          }
        });
      }
    }
  });

  group('PlaceOpeningStatusChip responsive tests', () {
    testWidgets(
        'PlaceOpeningStatusChip at 320px, scale 2.0 has no exception (Open Now)',
        (tester) async {
      await pumpResponsiveWidget(
        tester,
        child: PlaceOpeningStatusChip(
          placeDetail: openPlaceDetail,
          nowUtc: openNowUtc,
        ),
        width: 320,
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('● Open Now'), findsOneWidget);
      expect(find.text('· Based on regular hours'), findsOneWidget);
      expect(find.text('○ Closed Now'), findsNothing);
    });

    testWidgets(
        'PlaceOpeningStatusChip at 320px, scale 2.0 has no exception (Closed Now)',
        (tester) async {
      await pumpResponsiveWidget(
        tester,
        child: PlaceOpeningStatusChip(
          placeDetail: closedPlaceDetail,
          nowUtc: closedNowUtc,
        ),
        width: 320,
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('○ Closed Now'), findsOneWidget);
      expect(find.text('· Based on regular hours'), findsOneWidget);
      expect(find.text('● Open Now'), findsNothing);
    });

    testWidgets(
        'Unknown status still shows neither Open Now nor Closed Now at 320px scale 2.0',
        (tester) async {
      await pumpResponsiveWidget(
        tester,
        child: const PlaceOpeningStatusChip(
          placeDetail: {}, // Empty detail -> unknown
        ),
        width: 320,
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('● Open Now'), findsNothing);
      expect(find.text('○ Closed Now'), findsNothing);
      expect(find.text('· Based on regular hours'), findsNothing);
    });

    // Matrix tests across all required widths and text scales for PlaceOpeningStatusChip
    for (final w in [320.0, 360.0, 393.0, 412.0]) {
      for (final s in [1.0, 1.3, 1.5, 2.0]) {
        testWidgets(
            'PlaceOpeningStatusChip matrix width ${w}px scale $s (Open)',
            (tester) async {
          await pumpResponsiveWidget(
            tester,
            child: PlaceOpeningStatusChip(
              placeDetail: openPlaceDetail,
              nowUtc: openNowUtc,
            ),
            width: w,
            textScale: s,
          );

          expect(tester.takeException(), isNull);
          expect(find.text('● Open Now'), findsOneWidget);
          expect(find.text('· Based on regular hours'), findsOneWidget);
        });

        testWidgets(
            'PlaceOpeningStatusChip matrix width ${w}px scale $s (Closed)',
            (tester) async {
          await pumpResponsiveWidget(
            tester,
            child: PlaceOpeningStatusChip(
              placeDetail: closedPlaceDetail,
              nowUtc: closedNowUtc,
            ),
            width: w,
            textScale: s,
          );

          expect(tester.takeException(), isNull);
          expect(find.text('○ Closed Now'), findsOneWidget);
          expect(find.text('· Based on regular hours'), findsOneWidget);
        });
      }
    }
  });
}
