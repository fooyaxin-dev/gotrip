import '../models/placeModel.dart';

enum OpeningStatus {
  open,
  closed,
  unknown,
}

class OpeningHoursEvaluator {
  static const int minutesPerDay = 1440;
  static const int minutesPerWeek = 10080;

  /// Evaluates whether a place is open for the entire planned visit duration.
  ///
  /// [visitWeekday]: 0 = Sunday, 1 = Monday, ..., 6 = Saturday (Google Places standard).
  /// [arrivalMinutes]: Minutes from local midnight (0..1439).
  /// [durationMinutes]: Planned visit duration in minutes (> 0).
  /// [periods]: List of regular weekly opening periods.
  static OpeningStatus evaluateVisit({
    required int visitWeekday,
    required int arrivalMinutes,
    required int durationMinutes,
    required List<OpeningHoursPeriod>? periods,
  }) {
    if (periods == null || periods.isEmpty) {
      return OpeningStatus.unknown;
    }

    // Filter out invalid or malformed periods
    final validPeriods = periods.where((p) => p.isValid).toList();
    if (validPeriods.isEmpty) {
      return OpeningStatus.unknown;
    }

    if (durationMinutes <= 0 ||
        visitWeekday < 0 ||
        visitWeekday > 6 ||
        arrivalMinutes < 0 ||
        arrivalMinutes >= minutesPerDay) {
      return OpeningStatus.closed;
    }

    // 24-hour venue check: valid 24-hour period (Sunday 00:00, no close)
    for (final period in validPeriods) {
      if (period.is24Hours) {
        return OpeningStatus.open;
      }
    }

    final visitStart = visitWeekday * minutesPerDay + arrivalMinutes;
    final visitEnd = visitStart + durationMinutes;

    for (final period in validPeriods) {
      if (period.close == null) {
        if (period.is24Hours) return OpeningStatus.open;
        continue;
      }

      final openMinute = period.open.day * minutesPerDay +
          period.open.hour * 60 +
          period.open.minute;

      final closeMinute = period.close!.day * minutesPerDay +
          period.close!.hour * 60 +
          period.close!.minute;

      // Normalize period span: if closeMinute <= openMinute, it spans across
      // Saturday -> Sunday week wrap.
      final normalizedClose = (closeMinute <= openMinute)
          ? closeMinute + minutesPerWeek
          : closeMinute;

      // Check across week offsets (-1 week, current week, +1 week) to seamlessly
      // cover all boundaries, overnight spans, and week wraps.
      for (int k = -1; k <= 1; k++) {
        final periodStart = openMinute + k * minutesPerWeek;
        final periodEnd = normalizedClose + k * minutesPerWeek;

        if (visitStart >= periodStart && visitEnd <= periodEnd) {
          return OpeningStatus.open;
        }
      }
    }

    return OpeningStatus.closed;
  }
}
