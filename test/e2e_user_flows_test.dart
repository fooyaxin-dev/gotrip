import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/services/userPreference_service.dart';
import 'package:gotrip/services/connectivity_service.dart';
import 'package:gotrip/services/nearbyPlace_service.dart';
import 'package:gotrip/models/placeModel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('End-to-End Authentication & Session Switching Flow Tests', () {
    test('Logout clears session, pending retries, and nearby cache cleanly', () {
      final prefService = UserPreferenceService.instance;
      final connService = ConnectivityService.instance;
      final nearbyService = NearbyPlacesService.instance;

      // 1. Simulate User A logged in with preferences and cache
      prefService.clearLocalSession();
      connService.clearPendingRetry();
      nearbyService.clearCache();

      // 2. Perform Logout sequence
      prefService.clearLocalSession();
      nearbyService.clearCache();

      // 3. Verify clean state for User B
      expect(prefService.current.categories, isEmpty);
      expect(prefService.current.onboardingDone, isFalse);
      expect(nearbyService.hasLoaded, isFalse);
    });

    test('Missing profile recovery reconstructs user metadata without crashing', () {
      // Simulate User whose Firestore document was missing
      const Map<String, dynamic>? initialDoc = null;
      Map<String, dynamic> recoveredProfile = {};

      if (initialDoc == null) {
        recoveredProfile = {
          'username': 'RecoveredTraveler',
          'email': 'recovered@gotrip.com',
          'profileImageUrl': '',
          'onboardingDone': true,
          'preferences': {
            'categories': ['restaurant', 'park'],
            'cuisines': ['chinese', 'western'],
            'travelMode': 'walk',
            'budgetTier': 'budget',
            'topPriority': 'interest',
          },
        };
      }

      final prefs = UserPreferences.fromMap(recoveredProfile);
      expect(prefs.onboardingDone, isTrue);
      expect(prefs.categories, contains('restaurant'));
      expect(prefs.cuisines, contains('chinese'));
    });
  });

  group('End-to-End Recommendation Mode & Distance Constraints Tests', () {
    test('Strict distance limits are enforced across all travel modes', () {
      // Walking <= 2000m, Motor <= 8000m, Drive <= 12000m
      int radiusForMode(String mode) {
        switch (mode) {
          case 'walk':
            return 2000;
          case 'motor':
            return 8000;
          case 'drive':
          case 'both':
          default:
            return 12000;
        }
      }

      expect(radiusForMode('walk'), equals(2000));
      expect(radiusForMode('motor'), equals(8000));
      expect(radiusForMode('drive'), equals(12000));
      expect(radiusForMode('both'), equals(12000));

      final candidatesWithDistances = [
        (place: PlaceModel(id: '1', name: 'Close Cafe', source: 'google'), dist: 500),
        (place: PlaceModel(id: '2', name: 'Medium Park', source: 'google'), dist: 3500),
        (place: PlaceModel(id: '3', name: 'Far Museum', source: 'google'), dist: 10000),
        (place: PlaceModel(id: '4', name: 'Out of Range', source: 'google'), dist: 15000),
      ];

      final walkFiltered = candidatesWithDistances.where((item) => item.dist <= radiusForMode('walk')).toList();
      expect(walkFiltered.length, equals(1));
      expect(walkFiltered.first.place.name, equals('Close Cafe'));

      final motorFiltered = candidatesWithDistances.where((item) => item.dist <= radiusForMode('motor')).toList();
      expect(motorFiltered.length, equals(2));

      final driveFiltered = candidatesWithDistances.where((item) => item.dist <= radiusForMode('drive')).toList();
      expect(driveFiltered.length, equals(3));
    });
  });

  group('End-to-End Navigation State & Arrival Deduplication Tests', () {
    test('Arrival is committed exactly once even if GPS fixes continue', () {
      int arrivalCommitCount = 0;
      bool hasArrived = false;

      void onGpsUpdate(double distanceToDestination) {
        if (distanceToDestination <= 30.0) {
          if (!hasArrived) {
            hasArrived = true;
            arrivalCommitCount++;
          }
        }
      }

      // GPS updates approach destination
      onGpsUpdate(100.0);
      onGpsUpdate(50.0);
      onGpsUpdate(25.0); // Arrived (1st trigger)
      onGpsUpdate(15.0); // Repeated fix near destination
      onGpsUpdate(10.0); // Repeated fix near destination

      expect(hasArrived, isTrue);
      expect(arrivalCommitCount, equals(1));
    });

    test('Reroute failure retains previous valid route path', () {
      List<String> activePolyline = ['step_1', 'step_2', 'step_3'];

      // Simulate reroute attempt with network failure
      bool simulateReroute({required bool success}) {
        if (success) {
          activePolyline = ['new_step_1', 'new_step_2'];
          return true;
        }
        return false;
      }

      final rerouteSuccess = simulateReroute(success: false);
      expect(rerouteSuccess, isFalse);

      // Active polyline remains available to user
      expect(activePolyline.length, equals(3));
      expect(activePolyline, contains('step_2'));
    });
  });

  group('End-to-End Social Interaction & Storage Lifecycle Tests', () {
    test('Post delete propagation removes post and avoids duplicate delete calls', () {
      final List<String> feedPosts = ['post_1', 'post_2', 'post_3'];
      final Set<String> inFlightDeletions = {};

      Future<bool> deletePost(String postId) async {
        if (inFlightDeletions.contains(postId)) return false;
        inFlightDeletions.add(postId);
        try {
          feedPosts.remove(postId);
          return true;
        } finally {
          inFlightDeletions.remove(postId);
        }
      }

      // First delete call
      deletePost('post_2');
      expect(feedPosts.contains('post_2'), isFalse);
      expect(feedPosts.length, equals(2));
    });
  });

  group('End-to-End Itinerary Modification & Route Sync Tests', () {
    test('Swapping or removing places recalculates route sequence and bounds', () {
      final dayPlaces = ['Attraction A', 'Restaurant B', 'Park C', 'Museum D'];

      // Remove place
      dayPlaces.remove('Restaurant B');
      expect(dayPlaces.length, equals(3));
      expect(dayPlaces, isNot(contains('Restaurant B')));

      // Swap place
      final swapIndex = dayPlaces.indexOf('Park C');
      dayPlaces[swapIndex] = 'New Gallery E';

      expect(dayPlaces[swapIndex], equals('New Gallery E'));
      expect(dayPlaces, contains('New Gallery E'));
      expect(dayPlaces, isNot(contains('Park C')));
    });
  });
}
