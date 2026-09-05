import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/services/opening_hours_evaluator.dart';

void main() {
  group('OpeningHoursEvaluator Pure Unit Tests', () {
    // 0 = Sunday, 1 = Monday, 2 = Tuesday, 3 = Wednesday, 4 = Thursday, 5 = Friday, 6 = Saturday

    test('1. Open throughout visit', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 1, hour: 9, minute: 0),
          close: OpeningHoursPoint(day: 1, hour: 18, minute: 0),
        ),
      ];

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 1, // Monday
        arrivalMinutes: 10 * 60, // 10:00
        durationMinutes: 120, // 2 hours -> departure 12:00
        periods: periods,
      );

      expect(status, equals(OpeningStatus.open));
    });

    test('2. Opens after arrival', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 1, hour: 11, minute: 30),
          close: OpeningHoursPoint(day: 1, hour: 21, minute: 0),
        ),
      ];

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 1, // Monday
        arrivalMinutes: 10 * 60, // 10:00
        durationMinutes: 60, // Departure 11:00
        periods: periods,
      );

      expect(status, equals(OpeningStatus.closed));
    });

    test('3. Closes during visit', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 1, hour: 11, minute: 0),
          close: OpeningHoursPoint(day: 1, hour: 14, minute: 0),
        ),
      ];

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 1, // Monday
        arrivalMinutes: 13 * 60 + 30, // 13:30
        durationMinutes: 75, // Departure 14:45
        periods: periods,
      );

      expect(status, equals(OpeningStatus.closed));
    });

    test('4. Closed weekday', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 2, hour: 9, minute: 0),
          close: OpeningHoursPoint(day: 2, hour: 18, minute: 0),
        ),
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 3, hour: 9, minute: 0),
          close: OpeningHoursPoint(day: 3, hour: 18, minute: 0),
        ),
      ];

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 1, // Monday (closed)
        arrivalMinutes: 10 * 60,
        durationMinutes: 60,
        periods: periods,
      );

      expect(status, equals(OpeningStatus.closed));
    });

    test('5. Same-day interval exact containment', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 3, hour: 8, minute: 30),
          close: OpeningHoursPoint(day: 3, hour: 17, minute: 30),
        ),
      ];

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 3, // Wednesday
        arrivalMinutes: 8 * 60 + 30, // Exact open time 08:30
        durationMinutes: 60,
        periods: periods,
      );

      expect(status, equals(OpeningStatus.open));
    });

    test('6. Overnight interval (Friday evening to Saturday morning)', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 5, hour: 18, minute: 0), // Friday 18:00
          close:
              OpeningHoursPoint(day: 6, hour: 3, minute: 0), // Saturday 03:00
        ),
      ];

      // Arrival on Friday night
      final statusFriday = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 5,
        arrivalMinutes: 22 * 60, // Friday 22:00
        durationMinutes: 90, // Departure 23:30
        periods: periods,
      );
      expect(statusFriday, equals(OpeningStatus.open));
    });

    test(
        '7. Previous-day overnight spillover (Saturday early morning from Friday opening)',
        () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 5, hour: 18, minute: 0), // Friday 18:00
          close:
              OpeningHoursPoint(day: 6, hour: 3, minute: 0), // Saturday 03:00
        ),
      ];

      // Arrival on Saturday early morning
      final statusSaturday = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 6, // Saturday
        arrivalMinutes: 1 * 60, // Saturday 01:00
        durationMinutes: 90, // Departure Saturday 02:30
        periods: periods,
      );
      expect(statusSaturday, equals(OpeningStatus.open));
    });

    test('8. Saturday-to-Sunday week wrap', () {
      final periods = [
        const OpeningHoursPeriod(
          open:
              OpeningHoursPoint(day: 6, hour: 20, minute: 0), // Saturday 20:00
          close: OpeningHoursPoint(day: 0, hour: 4, minute: 0), // Sunday 04:00
        ),
      ];

      // Visit on Sunday early morning (week wrap 6 -> 0)
      final statusSunday = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 0, // Sunday
        arrivalMinutes: 1 * 60 + 30, // Sunday 01:30
        durationMinutes: 60, // Departure Sunday 02:30
        periods: periods,
      );
      expect(statusSunday, equals(OpeningStatus.open));

      // Visit late Saturday night
      final statusSaturday = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 6, // Saturday
        arrivalMinutes: 23 * 60, // Saturday 23:00
        durationMinutes: 120, // Departure Sunday 01:00
        periods: periods,
      );
      expect(statusSaturday, equals(OpeningStatus.open));
    });

    test('9. Always-open period with missing close', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 0, hour: 0, minute: 0),
          close: null, // Google Places 24-hour representation
        ),
      ];

      final statusMon = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 1, // Monday
        arrivalMinutes: 14 * 60,
        durationMinutes: 180,
        periods: periods,
      );
      expect(statusMon, equals(OpeningStatus.open));

      final statusSunNight = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 0, // Sunday
        arrivalMinutes: 23 * 60,
        durationMinutes: 120,
        periods: periods,
      );
      expect(statusSunNight, equals(OpeningStatus.open));
    });

    test('10. Missing periods -> unknown', () {
      expect(
        OpeningHoursEvaluator.evaluateVisit(
          visitWeekday: 1,
          arrivalMinutes: 10 * 60,
          durationMinutes: 60,
          periods: null,
        ),
        equals(OpeningStatus.unknown),
      );

      expect(
        OpeningHoursEvaluator.evaluateVisit(
          visitWeekday: 1,
          arrivalMinutes: 10 * 60,
          durationMinutes: 60,
          periods: const [],
        ),
        equals(OpeningStatus.unknown),
      );
    });

    test('11. Malformed period does not crash and handles safely', () {
      final validPoint =
          OpeningHoursPoint.fromJson({'day': 1, 'hour': 9, 'minute': 0});
      expect(validPoint, isNotNull);

      // Missing fields return null safely
      expect(OpeningHoursPoint.fromJson({'day': 1, 'hour': 9}), isNull);
      expect(OpeningHoursPoint.fromJson(null), isNull);
      expect(OpeningHoursPeriod.fromJson({'open': null}), isNull);
      expect(OpeningHoursPeriod.fromJson('invalid'), isNull);

      // Out of range parameters
      expect(
        OpeningHoursEvaluator.evaluateVisit(
          visitWeekday: 7, // invalid weekday
          arrivalMinutes: 500,
          durationMinutes: 60,
          periods: [
            const OpeningHoursPeriod(
              open: OpeningHoursPoint(day: 1, hour: 9, minute: 0),
              close: OpeningHoursPoint(day: 1, hour: 17, minute: 0),
            ),
          ],
        ),
        equals(OpeningStatus.closed),
      );
    });

    test('12. Exact closing boundary is valid', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 2, hour: 9, minute: 0),
          close: OpeningHoursPoint(day: 2, hour: 17, minute: 0),
        ),
      ];

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 2, // Tuesday
        arrivalMinutes: 15 * 60, // 15:00
        durationMinutes: 120, // Departure exactly 17:00
        periods: periods,
      );

      expect(status, equals(OpeningStatus.open));
    });

    test('13. Visit extending past closing is closed', () {
      final periods = [
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 2, hour: 9, minute: 0),
          close: OpeningHoursPoint(day: 2, hour: 17, minute: 0),
        ),
      ];

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 2, // Tuesday
        arrivalMinutes: 16 * 60, // 16:00
        durationMinutes: 75, // Departure 17:15 (15m past close)
        periods: periods,
      );

      expect(status, equals(OpeningStatus.closed));
    });

    test('14. Multiple opening periods on one day (lunch and dinner shifts)',
        () {
      final periods = [
        // Lunch: 11:30 to 14:30
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 4, hour: 11, minute: 30),
          close: OpeningHoursPoint(day: 4, hour: 14, minute: 30),
        ),
        // Dinner: 17:30 to 22:00
        const OpeningHoursPeriod(
          open: OpeningHoursPoint(day: 4, hour: 17, minute: 30),
          close: OpeningHoursPoint(day: 4, hour: 22, minute: 0),
        ),
      ];

      // Lunch visit
      final statusLunch = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 4, // Thursday
        arrivalMinutes: 12 * 60, // 12:00
        durationMinutes: 60, // Departure 13:00
        periods: periods,
      );
      expect(statusLunch, equals(OpeningStatus.open));

      // Break between lunch and dinner
      final statusBreak = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 4, // Thursday
        arrivalMinutes: 15 * 60, // 15:00
        durationMinutes: 60, // Departure 16:00
        periods: periods,
      );
      expect(statusBreak, equals(OpeningStatus.closed));

      // Dinner visit
      final statusDinner = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 4, // Thursday
        arrivalMinutes: 18 * 60, // 18:00
        durationMinutes: 90, // Departure 19:30
        periods: periods,
      );
      expect(statusDinner, equals(OpeningStatus.open));
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Task 11F-B1.1 Specific Tests for Null-Close & Malformed Period Handling
    // ─────────────────────────────────────────────────────────────────────────

    test('15. Valid Sunday 00:00 with no close -> open', () {
      final parsed = OpeningHoursPeriod.fromJson({
        'open': {'day': 0, 'hour': 0, 'minute': 0},
      });

      expect(parsed, isNotNull);
      expect(parsed!.is24Hours, isTrue);
      expect(parsed.isValid, isTrue);

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 3, // Wednesday
        arrivalMinutes: 12 * 60,
        durationMinutes: 90,
        periods: [parsed],
      );

      expect(status, equals(OpeningStatus.open));
    });

    test('16. Monday 09:00 with no close -> not 24-hour; result unknown', () {
      // Noncanonical missing close: fromJson returns null
      final parsed = OpeningHoursPeriod.fromJson({
        'open': {'day': 1, 'hour': 9, 'minute': 0},
      });

      expect(parsed, isNull);

      // Direct construction of noncanonical period is marked invalid
      const noncanonical = OpeningHoursPeriod(
        open: OpeningHoursPoint(day: 1, hour: 9, minute: 0),
        close: null,
      );
      expect(noncanonical.is24Hours, isFalse);
      expect(noncanonical.isValid, isFalse);

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 1,
        arrivalMinutes: 10 * 60,
        durationMinutes: 60,
        periods: [noncanonical],
      );

      expect(status, equals(OpeningStatus.unknown));
    });

    test('17. JSON contains malformed close -> parser returns null', () {
      final parsed = OpeningHoursPeriod.fromJson({
        'open': {'day': 1, 'hour': 9, 'minute': 0},
        'close': 'invalid_string_instead_of_map',
      });

      expect(parsed, isNull);
    });

    test(
        '18. JSON contains valid open but invalid close values -> parser returns null',
        () {
      final parsed = OpeningHoursPeriod.fromJson({
        'open': {'day': 1, 'hour': 9, 'minute': 0},
        'close': {'day': 8, 'hour': 25, 'minute': 70}, // out of bounds
      });

      expect(parsed, isNull);
    });

    test('19. Only malformed periods -> unknown', () {
      const malformed1 = OpeningHoursPeriod(
        open: OpeningHoursPoint(day: 2, hour: 10, minute: 0),
        close: null, // noncanonical
      );
      const malformed2 = OpeningHoursPeriod(
        open: OpeningHoursPoint(day: 5, hour: 14, minute: 0),
        close: null, // noncanonical
      );

      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 2,
        arrivalMinutes: 11 * 60,
        durationMinutes: 60,
        periods: [malformed1, malformed2],
      );

      expect(status, equals(OpeningStatus.unknown));
    });

    test('20. Malformed period plus valid closed period -> closed', () {
      const malformed = OpeningHoursPeriod(
        open: OpeningHoursPoint(day: 2, hour: 10, minute: 0),
        close: null, // noncanonical
      );
      const validMondayOnly = OpeningHoursPeriod(
        open: OpeningHoursPoint(day: 1, hour: 9, minute: 0),
        close: OpeningHoursPoint(day: 1, hour: 17, minute: 0),
      );

      // Visit on Wednesday (Monday period is closed on Wednesday, malformed is ignored)
      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 3, // Wednesday
        arrivalMinutes: 11 * 60,
        durationMinutes: 60,
        periods: [malformed, validMondayOnly],
      );

      expect(status, equals(OpeningStatus.closed));
    });

    test('21. Malformed period plus valid matching period -> open', () {
      const malformed = OpeningHoursPeriod(
        open: OpeningHoursPoint(day: 2, hour: 10, minute: 0),
        close: null, // noncanonical
      );
      const validWedPeriod = OpeningHoursPeriod(
        open: OpeningHoursPoint(day: 3, hour: 9, minute: 0),
        close: OpeningHoursPoint(day: 3, hour: 17, minute: 0),
      );

      // Visit on Wednesday during validWedPeriod
      final status = OpeningHoursEvaluator.evaluateVisit(
        visitWeekday: 3, // Wednesday
        arrivalMinutes: 11 * 60,
        durationMinutes: 60,
        periods: [malformed, validWedPeriod],
      );

      expect(status, equals(OpeningStatus.open));
    });
  });
}
