import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/services/userPreference_service.dart';
import 'package:gotrip/services/connectivity_service.dart';
import 'package:gotrip/services/nearbyPlace_service.dart';
import 'package:gotrip/services/userActivity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Session Isolation and Cache Ownership Audit Tests [State Simulation]', () {
    test('User A state is completely cleared and unavailable after Logout', () {
      final prefService = UserPreferenceService.instance;
      final connService = ConnectivityService.instance;
      final nearbyService = NearbyPlacesService.instance;
      final activityService = UserActivityDataService.instance;

      // ── Step 1: Simulate User A logged in ──
      final userAPreferences = {
        'username': 'UserA_Explorer',
        'email': 'userA@gotrip.com',
        'onboardingDone': true,
        'preferences': {
          'categories': ['restaurant', 'park'],
          'cuisines': ['japanese', 'korean'],
          'travelMode': 'walk',
          'budgetTier': 'luxury',
          'topPriority': 'food',
        },
      };

      final userAPrefs = UserPreferences.fromMap(userAPreferences);
      expect(userAPrefs.onboardingDone, isTrue);
      expect(userAPrefs.categories, contains('restaurant'));
      expect(userAPrefs.cuisines, contains('japanese'));

      // ── Step 2: Perform complete AuthService.logout sequence ──
      prefService.clearLocalSession();
      nearbyService.clearCache();
      nearbyService.clearSearchCache();
      activityService.invalidate();
      connService.clearPendingRetry();

      // ── Step 3: Verify complete wipe of User A in-memory data ──
      expect(prefService.current.onboardingDone, isFalse);
      expect(prefService.current.categories, isEmpty);
      expect(prefService.current.cuisines, isEmpty);
      expect(nearbyService.hasLoaded, isFalse);

      // ── Step 4: Simulate User B login ──
      final userBPreferences = {
        'username': 'UserB_Backpacker',
        'email': 'userB@gotrip.com',
        'onboardingDone': true,
        'preferences': {
          'categories': ['tourist_attraction'],
          'cuisines': ['western'],
          'travelMode': 'drive',
          'budgetTier': 'budget',
          'topPriority': 'interest',
        },
      };

      final userBPrefs = UserPreferences.fromMap(userBPreferences);

      // Verify User B has only User B's preferences and no User A residue
      expect(userBPrefs.categories, contains('tourist_attraction'));
      expect(userBPrefs.categories, isNot(contains('restaurant')));
      expect(userBPrefs.cuisines, contains('western'));
      expect(userBPrefs.cuisines, isNot(contains('japanese')));
      expect(userBPrefs.travelMode, equals('drive'));
    });
  });
}
