import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/modules/place/placeDetailPage.dart';
import 'package:gotrip/services/opening_hours_evaluator.dart';

void main() {
  group('evaluateCurrentPlaceOpeningStatus unit tests', () {
    // Standard Monday 09:00 - 17:00 period (day: 1)
    final mondayPeriod = {
      'open': {'day': 1, 'hour': 9, 'minute': 0},
      'close': {'day': 1, 'hour': 17, 'minute': 0},
    };

    // Standard Sunday 12:00 - 18:00 period (day: 0)
    final sundayPeriod = {
      'open': {'day': 0, 'hour': 12, 'minute': 0},
      'close': {'day': 0, 'hour': 18, 'minute': 0},
    };

    // 24-hour period (Google Places: open Sunday 00:00, no close)
    final allDayPeriod = {
      'open': {'day': 0, 'hour': 0, 'minute': 0},
    };

    test(
        '1. Cached openNow: true is ignored when regular hours say Place is closed',
        () {
      // Monday 2026-09-07 20:00 UTC (after 17:00 closing)
      final nowUtc = DateTime.utc(2026, 9, 7, 20, 0);
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'openNow': true, // Stale cache claim
          'periods': [mondayPeriod],
        },
      };

      final status =
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);
      expect(status, equals(OpeningStatus.closed));
    });

    test(
        '2. Cached openNow: false is ignored when regular hours say Place is open',
        () {
      // Monday 2026-09-07 11:00 UTC (during 09:00 - 17:00)
      final nowUtc = DateTime.utc(2026, 9, 7, 11, 0);
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'openNow': false, // Stale cache claim
          'periods': [mondayPeriod],
        },
      };

      final status =
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);
      expect(status, equals(OpeningStatus.open));
    });

    test('3. Monday opening-hours calculation (Dart weekday 1 -> Google day 1)',
        () {
      // Monday 2026-09-07 14:30 UTC
      final nowUtc = DateTime.utc(2026, 9, 7, 14, 30);
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': [mondayPeriod],
        },
      };

      final status =
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);
      expect(status, equals(OpeningStatus.open));
    });

    test('4. Sunday opening-hours calculation (Dart weekday 7 -> Google day 0)',
        () {
      // Sunday 2026-09-06 14:00 UTC (Dart weekday is 7, Google day is 0)
      final nowUtc = DateTime.utc(2026, 9, 6, 14, 0);
      expect(nowUtc.weekday, equals(7)); // Verify Dart Sunday is 7

      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': [sundayPeriod],
        },
      };

      final status =
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);
      expect(status, equals(OpeningStatus.open));
    });

    test('5. Positive UTC offset calculation', () {
      // UTC is Monday 2026-09-07 01:00.
      // Offset +540 mins (+9 hours, Tokyo) -> Tokyo local time is 10:00 Monday.
      final nowUtc = DateTime.utc(2026, 9, 7, 1, 0);
      final placeDetail = {
        'utcOffsetMinutes': 540,
        'regularOpeningHours': {
          'periods': [mondayPeriod], // 09:00 - 17:00
        },
      };

      final status =
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);
      expect(status, equals(OpeningStatus.open));
    });

    test('6. Negative UTC offset calculation', () {
      // UTC is Monday 2026-09-07 13:00.
      // Offset -300 mins (-5 hours, New York) -> NY local time is 08:00 Monday (before 09:00 open).
      final nowUtc = DateTime.utc(2026, 9, 7, 13, 0);
      final placeDetail = {
        'utcOffsetMinutes': -300,
        'regularOpeningHours': {
          'periods': [mondayPeriod], // 09:00 - 17:00
        },
      };

      final status =
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);
      expect(status, equals(OpeningStatus.closed));
    });

    test('7. Offset that changes local calendar date', () {
      // UTC is Monday 2026-09-07 23:30.
      // Offset +120 mins (+2 hours) -> Local time is Tuesday 2026-09-08 01:30.
      // Monday period (day 1) does NOT cover Tuesday 01:30.
      final nowUtc = DateTime.utc(2026, 9, 7, 23, 30);
      final placeDetail = {
        'utcOffsetMinutes': 120,
        'regularOpeningHours': {
          'periods': [mondayPeriod],
        },
      };

      final status =
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtc);
      expect(status, equals(OpeningStatus.closed));
    });

    test('8. Overnight opening period (e.g. Friday 20:00 to Saturday 03:00)',
        () {
      final overnightPeriod = {
        'open': {'day': 5, 'hour': 20, 'minute': 0},
        'close': {'day': 6, 'hour': 3, 'minute': 0},
      };

      // Saturday 2026-09-12 01:30 UTC -> inside Friday overnight interval
      final nowUtcOpen = DateTime.utc(2026, 9, 12, 1, 30);
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': [overnightPeriod],
        },
      };

      expect(evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtcOpen),
          equals(OpeningStatus.open));

      // Saturday 2026-09-12 04:00 UTC -> closed
      final nowUtcClosed = DateTime.utc(2026, 9, 12, 4, 0);
      expect(
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtcClosed),
          equals(OpeningStatus.closed));
    });

    test(
        '9. Saturday-to-Sunday week wrap period (Saturday 22:00 to Sunday 04:00)',
        () {
      final weekWrapPeriod = {
        'open': {'day': 6, 'hour': 22, 'minute': 0},
        'close': {'day': 0, 'hour': 4, 'minute': 0},
      };

      // Sunday 2026-09-06 02:00 UTC -> inside week-wrap interval
      final nowUtcOpen = DateTime.utc(2026, 9, 6, 2, 0);
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': [weekWrapPeriod],
        },
      };

      expect(evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtcOpen),
          equals(OpeningStatus.open));

      // Sunday 2026-09-06 05:00 UTC -> closed
      final nowUtcClosed = DateTime.utc(2026, 9, 6, 5, 0);
      expect(
          evaluateCurrentPlaceOpeningStatus(placeDetail, nowUtc: nowUtcClosed),
          equals(OpeningStatus.closed));
    });

    test('10. Valid 24-hour Place', () {
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': [allDayPeriod],
        },
      };

      // Check multiple arbitrary days and times
      final mondayAfternoon = DateTime.utc(2026, 9, 7, 15, 30);
      final sundayMidnight = DateTime.utc(2026, 9, 6, 0, 0);

      expect(
          evaluateCurrentPlaceOpeningStatus(placeDetail,
              nowUtc: mondayAfternoon),
          equals(OpeningStatus.open));
      expect(
          evaluateCurrentPlaceOpeningStatus(placeDetail,
              nowUtc: sundayMidnight),
          equals(OpeningStatus.open));
    });

    test('11. Missing periods returns OpeningStatus.unknown', () {
      final placeDetail1 = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': <String, dynamic>{},
      };
      final placeDetail2 = {
        'utcOffsetMinutes': 0,
      };

      expect(evaluateCurrentPlaceOpeningStatus(placeDetail1),
          equals(OpeningStatus.unknown));
      expect(evaluateCurrentPlaceOpeningStatus(placeDetail2),
          equals(OpeningStatus.unknown));
      expect(evaluateCurrentPlaceOpeningStatus(null),
          equals(OpeningStatus.unknown));
    });

    test('12. Empty periods returns OpeningStatus.unknown', () {
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': <dynamic>[],
        },
      };

      expect(evaluateCurrentPlaceOpeningStatus(placeDetail),
          equals(OpeningStatus.unknown));
    });

    test(
        '13. Malformed periods do not crash and return unknown when no valid periods remain',
        () {
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': [
            'invalid string',
            12345,
            {'open': 'not a map'},
            {
              'open': {'day': 99, 'hour': 50}
            }, // Out-of-range
            null,
          ],
        },
      };

      expect(
        evaluateCurrentPlaceOpeningStatus(placeDetail),
        equals(OpeningStatus.unknown),
      );
    });

    test('14. Missing utcOffsetMinutes returns unknown', () {
      final placeDetail = {
        'regularOpeningHours': {
          'periods': [mondayPeriod],
        },
      };

      expect(evaluateCurrentPlaceOpeningStatus(placeDetail),
          equals(OpeningStatus.unknown));
    });

    test('15. Invalid utcOffsetMinutes returns unknown', () {
      final placeDetailString = {
        'utcOffsetMinutes': 'not an int',
        'regularOpeningHours': {
          'periods': [mondayPeriod],
        },
      };
      final placeDetailBool = {
        'utcOffsetMinutes': true,
        'regularOpeningHours': {
          'periods': [mondayPeriod],
        },
      };

      expect(evaluateCurrentPlaceOpeningStatus(placeDetailString),
          equals(OpeningStatus.unknown));
      expect(evaluateCurrentPlaceOpeningStatus(placeDetailBool),
          equals(OpeningStatus.unknown));
    });
  });

  group('PlaceOpeningStatusChip widget tests', () {
    final mondayPeriod = {
      'open': {'day': 1, 'hour': 9, 'minute': 0},
      'close': {'day': 1, 'hour': 17, 'minute': 0},
    };

    testWidgets(
        '16. Unknown status does not render a false Open Now or Closed Now chip',
        (tester) async {
      final placeDetailUnknown = {
        'utcOffsetMinutes': null, // causes unknown
        'regularOpeningHours': {
          'openNow': true, // cached stale flag must not trigger chip
          'periods': <dynamic>[],
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaceOpeningStatusChip(placeDetail: placeDetailUnknown),
          ),
        ),
      );

      expect(find.text('● Open Now'), findsNothing);
      expect(find.text('○ Closed Now'), findsNothing);
      expect(find.text('○ Closed'), findsNothing);
      expect(find.textContaining('Based on regular hours'), findsNothing);
    });

    testWidgets('17. Open status renders Open Now and regular hours note',
        (tester) async {
      // Monday 2026-09-07 11:00 UTC -> Open
      final nowUtc = DateTime.utc(2026, 9, 7, 11, 0);
      final placeDetailOpen = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'openNow': false, // Cache says false, but calculated is open
          'periods': [mondayPeriod],
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaceOpeningStatusChip(
              placeDetail: placeDetailOpen,
              nowUtc: nowUtc,
            ),
          ),
        ),
      );

      expect(find.text('● Open Now'), findsOneWidget);
      expect(find.textContaining('Based on regular hours'), findsOneWidget);
      expect(find.text('○ Closed Now'), findsNothing);
    });

    testWidgets('18. Closed status renders Closed Now and regular hours note',
        (tester) async {
      // Monday 2026-09-07 20:00 UTC -> Closed
      final nowUtc = DateTime.utc(2026, 9, 7, 20, 0);
      final placeDetailClosed = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'openNow': true, // Cache says true, but calculated is closed
          'periods': [mondayPeriod],
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaceOpeningStatusChip(
              placeDetail: placeDetailClosed,
              nowUtc: nowUtc,
            ),
          ),
        ),
      );

      expect(find.text('○ Closed Now'), findsOneWidget);
      expect(find.textContaining('Based on regular hours'), findsOneWidget);
      expect(find.text('● Open Now'), findsNothing);
    });

    testWidgets(
        '19. Production status UI indicates that result is based on regular hours',
        (tester) async {
      final nowUtc = DateTime.utc(2026, 9, 7, 11, 0);
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'periods': [mondayPeriod],
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaceOpeningStatusChip(
              placeDetail: placeDetail,
              nowUtc: nowUtc,
            ),
          ),
        ),
      );

      expect(find.text('· Based on regular hours'), findsOneWidget);
    });

    test('20. weekdayDescriptions remain available independently', () {
      final descriptions = [
        'Monday: 9:00 AM – 5:00 PM',
        'Tuesday: Closed',
      ];
      final placeDetail = {
        'utcOffsetMinutes': 0,
        'regularOpeningHours': {
          'openNow': true,
          'periods': [mondayPeriod],
          'weekdayDescriptions': descriptions,
        },
      };

      // Status calculation works without consuming/mutating weekdayDescriptions
      final status = evaluateCurrentPlaceOpeningStatus(
        placeDetail,
        nowUtc: DateTime.utc(2026, 9, 7, 11, 0),
      );
      expect(status, equals(OpeningStatus.open));

      // Descriptions remain untouched for accordion rendering
      final regularHours =
          placeDetail['regularOpeningHours'] as Map<String, dynamic>?;
      final extractedDescriptions =
          regularHours?['weekdayDescriptions'] as List?;
      expect(extractedDescriptions, equals(descriptions));
    });
  });
}
