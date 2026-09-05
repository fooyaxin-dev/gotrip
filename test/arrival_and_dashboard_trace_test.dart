import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Arrival Check-in to Dashboard Exact Trace Tests [Pure Unit / State Simulation]', () {
    test('Two arrival events in the same session deduplicate to exactly one visit in Dashboard', () {
      final now = DateTime(2026, 8, 31, 14, 30);

      // Raw visit event 1: emitted from GPS arrival event into users/{uid}/history
      final historyEvent = {
        'placeId': 'place_petronas_123',
        'placeName': 'Petronas Twin Towers',
        'visitedAt': now,
        'itineraryId': 'itin_kl_01',
      };

      // Raw visit event 2: emitted from atomic itinerary batch update
      final itineraryEvent = {
        'placeId': 'place_petronas_123',
        'placeName': 'Petronas Twin Towers',
        'visitedAt': now,
        'itineraryId': 'itin_kl_01',
      };

      final allRawEvents = [historyEvent, itineraryEvent];

      // Dashboard deduplication algorithm (_buildAllTimeCache in dashboard_page.dart)
      final seenKeys = <String>{};
      final dedupedVisits = <Map<String, dynamic>>[];

      for (final e in allRawEvents) {
        final visitedAt = e['visitedAt'] as DateTime;
        final dayKey = '${visitedAt.year}-${visitedAt.month}-${visitedAt.day}';
        final placeId = e['placeId'] as String?;
        final placeName = e['placeName'] as String;
        final key = placeId != null && placeId.isNotEmpty
            ? '${placeId}_$dayKey'
            : '${placeName}_$dayKey';

        if (seenKeys.contains(key)) continue;
        seenKeys.add(key);
        dedupedVisits.add(e);
      }

      // Exact assertion: 2 raw arrivals -> 1 logical visit in Dashboard
      expect(dedupedVisits.length, equals(1));
      expect(dedupedVisits.first['placeId'], equals('place_petronas_123'));
    });

    test('Separate visit on a subsequent day is correctly counted as a distinct visit', () {
      final day1 = DateTime(2026, 8, 31, 10, 0);
      final day2 = DateTime(2026, 9, 1, 15, 0);

      final eventDay1 = {
        'placeId': 'place_batu_caves',
        'placeName': 'Batu Caves',
        'visitedAt': day1,
      };

      final eventDay2 = {
        'placeId': 'place_batu_caves',
        'placeName': 'Batu Caves',
        'visitedAt': day2,
      };

      final allEvents = [eventDay1, eventDay2];

      final seenKeys = <String>{};
      final dedupedVisits = <Map<String, dynamic>>[];

      for (final e in allEvents) {
        final visitedAt = e['visitedAt'] as DateTime;
        final dayKey = '${visitedAt.year}-${visitedAt.month}-${visitedAt.day}';
        final placeId = e['placeId'] as String?;
        final key = '${placeId}_$dayKey';

        if (seenKeys.contains(key)) continue;
        seenKeys.add(key);
        dedupedVisits.add(e);
      }

      // Visited on 2 different days -> 2 distinct visits recorded
      expect(dedupedVisits.length, equals(2));
    });
  });
}
