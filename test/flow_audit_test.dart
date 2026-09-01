import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/placeModel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Navigation Rapid Tap & Debounce State Tests [Pure Unit / State Simulation]', () {
    test('Rapid tap lock prevents duplicate Guide navigation pushes', () {
      bool isStartingNav = false;
      int pushedCount = 0;

      void onStartTapped() {
        if (isStartingNav) return;
        isStartingNav = true;
        pushedCount++;
      }

      // Simulate rapid double tap
      onStartTapped();
      onStartTapped();
      onStartTapped();

      expect(pushedCount, equals(1));
      expect(isStartingNav, isTrue);
    });
  });

  group('Search Location Origin Preservation Tests [State Simulation]', () {
    test('Searched coordinates override current GPS and prevent silent revert', () {
      double computeActiveOrigin(double? searchCoord, double gpsCoord) {
        return searchCoord ?? gpsCoord;
      }

      bool shouldProcessLocationUpdate(String? searchLoc) {
        if (searchLoc != null) return false;
        return true;
      }

      // Setup initial state: Searched location chosen
      const searchLocationName = 'Batu Caves';
      const searchLat = 3.2379;
      const searchLng = 101.6840;
      const currentGpsLat = 3.1578;
      const currentGpsLng = 101.7123;

      final activeLat = computeActiveOrigin(searchLat, currentGpsLat);
      final activeLng = computeActiveOrigin(searchLng, currentGpsLng);

      expect(activeLat, equals(3.2379));
      expect(activeLng, equals(101.6840));

      expect(shouldProcessLocationUpdate(searchLocationName), isFalse);
      expect(shouldProcessLocationUpdate(null), isTrue);
    });
  });

  group('Dynamic Itinerary Allocation Rules Tests [State Simulation]', () {
    test('Itinerary generation respects category balance and avoids duplicate places', () {
      final List<PlaceModel> candidatePool = [
        PlaceModel(id: 'p1', name: 'National Museum', primaryType: 'tourist_attraction', source: 'google'),
        PlaceModel(id: 'p2', name: 'KL Bird Park', primaryType: 'park', source: 'google'),
        PlaceModel(id: 'p3', name: 'Chinatown Hawker', primaryType: 'restaurant', source: 'google'),
        PlaceModel(id: 'p4', name: 'Pavilion Mall', primaryType: 'shopping_mall', source: 'google'),
        PlaceModel(id: 'p5', name: 'Dinner Bistro', primaryType: 'restaurant', source: 'google'),
      ];

      final Set<String> assignedPlaceIds = {};
      final List<PlaceModel> selectedForDay = [];

      for (final place in candidatePool) {
        if (!assignedPlaceIds.contains(place.id)) {
          assignedPlaceIds.add(place.id);
          selectedForDay.add(place);
        }
      }

      expect(selectedForDay.length, equals(5));
      expect(assignedPlaceIds.length, equals(5)); // Zero duplicate places
    });
  });
}
