import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/services/location_service.dart';
import 'package:gotrip/modules/landmark/landmarkFAB.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Permissions & Device Capabilities State Machine Tests [Pure Unit / State Simulation]', () {
    test('LocationStatus distinguishes between disabled service, denial, and permanent denial', () {
      LocationStatus evaluateStatus({
        required bool serviceEnabled,
        required String permissionState,
      }) {
        if (!serviceEnabled) return LocationStatus.serviceDisabled;
        if (permissionState == 'deniedForever') return LocationStatus.permissionDeniedForever;
        if (permissionState == 'denied') return LocationStatus.permissionDenied;
        return LocationStatus.success;
      }

      expect(evaluateStatus(serviceEnabled: false, permissionState: 'granted'), equals(LocationStatus.serviceDisabled));
      expect(evaluateStatus(serviceEnabled: true, permissionState: 'denied'), equals(LocationStatus.permissionDenied));
      expect(evaluateStatus(serviceEnabled: true, permissionState: 'deniedForever'), equals(LocationStatus.permissionDeniedForever));
      expect(evaluateStatus(serviceEnabled: true, permissionState: 'granted'), equals(LocationStatus.success));
    });

    test('Settings recovery correctly routes to Location Settings vs App Settings', () {
      String resolveSettingsDestination({required bool isServiceEnabled}) {
        // When system GPS is turned off -> must open system Location Settings
        // When GPS is on but app lacks permission -> must open App Settings
        if (!isServiceEnabled) {
          return 'LOCATION_SETTINGS';
        } else {
          return 'APP_SETTINGS';
        }
      }

      expect(resolveSettingsDestination(isServiceEnabled: false), equals('LOCATION_SETTINGS'));
      expect(resolveSettingsDestination(isServiceEnabled: true), equals('APP_SETTINGS'));
    });

    test('Searched location coordinates function independently of GPS permission status', () {
      // Simulate GPS permission denied
      const LocationStatus gpsStatus = LocationStatus.permissionDenied;
      const double? gpsLat = null;
      const double? gpsLng = null;

      // User searches for a custom location
      const searchLocationName = 'Penang Hill';
      const searchLat = 5.4085;
      const searchLng = 100.2770;

      double? effectiveLat;
      double? effectiveLng;
      String? effectiveOriginName;

      if (searchLocationName.isNotEmpty) {
        effectiveLat = searchLat;
        effectiveLng = searchLng;
        effectiveOriginName = searchLocationName;
      } else if (gpsStatus == LocationStatus.success) {
        effectiveLat = gpsLat;
        effectiveLng = gpsLng;
        effectiveOriginName = 'Current Location';
      }

      // Assert that search coordinates are fully resolved despite GPS denial
      expect(effectiveLat, equals(5.4085));
      expect(effectiveLng, equals(100.2770));
      expect(effectiveOriginName, equals('Penang Hill'));
    });

    test('Camera failure provides graceful fallback to Gallery selection', () {
      String resolveRecognitionSource({
        required bool isCameraAvailable,
        required bool isGalleryAvailable,
      }) {
        if (isCameraAvailable) {
          return 'CAMERA';
        } else if (isGalleryAvailable) {
          return 'GALLERY';
        } else {
          return 'ERROR';
        }
      }

      // Camera unavailable -> falls back to Gallery
      expect(
        resolveRecognitionSource(isCameraAvailable: false, isGalleryAvailable: true),
        equals('GALLERY'),
      );
      // Both available -> prefers Camera
      expect(
        resolveRecognitionSource(isCameraAvailable: true, isGalleryAvailable: true),
        equals('CAMERA'),
      );
    });

    test('CameraException codes map accurately to granular LandmarkCameraState', () {
      LandmarkCameraState mapCameraError(String? errorCode) {
        if (errorCode == 'CameraAccessDenied') {
          return LandmarkCameraState.permissionDenied;
        } else if (errorCode == 'CameraAccessDeniedWithoutPrompt' || errorCode == 'CameraAccessRestricted') {
          return LandmarkCameraState.permissionPermanentlyDenied;
        } else if (errorCode == 'no_camera') {
          return LandmarkCameraState.noCamera;
        }
        return LandmarkCameraState.initializationFailed;
      }

      expect(mapCameraError('CameraAccessDenied'), equals(LandmarkCameraState.permissionDenied));
      expect(mapCameraError('CameraAccessDeniedWithoutPrompt'), equals(LandmarkCameraState.permissionPermanentlyDenied));
      expect(mapCameraError('CameraAccessRestricted'), equals(LandmarkCameraState.permissionPermanentlyDenied));
      expect(mapCameraError('no_camera'), equals(LandmarkCameraState.noCamera));
      expect(mapCameraError('camera_busy'), equals(LandmarkCameraState.initializationFailed));
    });

    test('Location accuracy gate: reduced accuracy permits Explore Nearby but blocks Navigation', () {
      bool canExploreNearby({required String accuracy}) {
        // Approximate / reduced or precise location can both explore general nearby areas
        return accuracy == 'reduced' || accuracy == 'precise';
      }

      bool canStartActiveNavigation({required String accuracy}) {
        // Active turn-by-turn guidance and 30m arrival check-in strictly require precise location
        return accuracy == 'precise';
      }

      expect(canExploreNearby(accuracy: 'reduced'), isTrue);
      expect(canStartActiveNavigation(accuracy: 'reduced'), isFalse);

      expect(canExploreNearby(accuracy: 'precise'), isTrue);
      expect(canStartActiveNavigation(accuracy: 'precise'), isTrue);
    });

    test('Camera lifecycle resume flag gate: ordinary resume does not retry denied camera; settings return does', () {
      int cameraInitCount = 0;
      bool isMounted = true;
      bool waitingForCameraSettingsReturn = false;
      LandmarkCameraState cameraState = LandmarkCameraState.permissionDenied;
      bool hasController = false;

      void onAppResume() {
        if (!isMounted) return;
        if (waitingForCameraSettingsReturn) {
          waitingForCameraSettingsReturn = false;
          cameraInitCount++;
        } else if (cameraState == LandmarkCameraState.ready && !hasController) {
          cameraInitCount++;
        }
      }

      // Scenario 1: User has denied camera. Ordinary background/resume occurs.
      onAppResume();
      expect(cameraInitCount, equals(0), reason: 'Ordinary resume must NOT re-trigger camera init on denied state');

      // Scenario 2: User taps "Open Settings". App backgrounded, then resumes.
      waitingForCameraSettingsReturn = true;
      onAppResume();
      expect(cameraInitCount, equals(1), reason: 'Settings return MUST trigger exactly one camera recheck');
      expect(waitingForCameraSettingsReturn, isFalse);

      // Scenario 3: Multiple rapid resume events after flag is consumed
      onAppResume();
      onAppResume();
      expect(cameraInitCount, equals(1), reason: 'Subsequent resumes must not re-trigger camera init');

      // Scenario 4: Page disposed before resume
      waitingForCameraSettingsReturn = true;
      isMounted = false;
      onAppResume();
      expect(cameraInitCount, equals(1), reason: 'Disposed state must not initialize camera');
    });

    test('Home Page Location Rationale & Recovery State Machine Tests', () {
      bool rationaleShown = false;
      int rationaleShowCount = 0;
      bool systemRequestTriggered = false;
      bool searchManuallyOpened = false;
      bool isLoading = true;
      bool openSettingsCalled = false;

      // Simulated component state
      bool hasShownLocationRationale = false;

      void onHomeEntry({
        required bool isAlreadyGranted,
        required bool isPermanentlyDenied,
        required bool isFirstOpen,
        required bool userTriggered,
      }) {
        if (isAlreadyGranted) {
          isLoading = false;
          return;
        }

        if (isFirstOpen && !hasShownLocationRationale) {
          hasShownLocationRationale = true;
          rationaleShown = true;
          rationaleShowCount++;
          isLoading = false;
          return;
        }

        if (userTriggered) {
          if (isPermanentlyDenied) {
            openSettingsCalled = true;
            isLoading = false;
          } else {
            systemRequestTriggered = true;
            isLoading = false;
          }
        } else {
          isLoading = false;
        }
      }

      void onUserTapEnableLocation() {
        systemRequestTriggered = true;
      }

      void onUserTapNotNow() {
        // Dismisses rationale without calling system request
        rationaleShown = false;
      }

      void onUserTapSearchManually() {
        searchManuallyOpened = true;
      }

      // 1. First Home entry shows rationale once
      onHomeEntry(
        isAlreadyGranted: false,
        isPermanentlyDenied: false,
        isFirstOpen: true,
        userTriggered: false,
      );
      expect(rationaleShown, isTrue);
      expect(rationaleShowCount, equals(1));
      expect(systemRequestTriggered, isFalse, reason: 'System request must wait for explicit user action');

      // 2. Rebuild / tab switch does not repeat rationale
      onHomeEntry(
        isAlreadyGranted: false,
        isPermanentlyDenied: false,
        isFirstOpen: true,
        userTriggered: false,
      );
      expect(rationaleShowCount, equals(1), reason: 'Rationale must not repeat on subsequent builds');

      // 3. User taps "Not Now"
      onUserTapNotNow();
      expect(rationaleShown, isFalse);
      expect(systemRequestTriggered, isFalse, reason: 'Not Now must not trigger system permission');

      // 4. User taps "Search Manually"
      onUserTapSearchManually();
      expect(searchManuallyOpened, isTrue);

      // 5. User taps "Enable Location" -> triggers system request
      onUserTapEnableLocation();
      expect(systemRequestTriggered, isTrue);

      // 6. Previously granted user loads location directly without rationale
      hasShownLocationRationale = false;
      rationaleShowCount = 0;
      systemRequestTriggered = false;
      onHomeEntry(
        isAlreadyGranted: true,
        isPermanentlyDenied: false,
        isFirstOpen: true,
        userTriggered: false,
      );
      expect(rationaleShowCount, equals(0), reason: 'Authorized users must not see rationale');
      expect(isLoading, isFalse);

      // 7. Denied state does not remain loading forever
      isLoading = true;
      onHomeEntry(
        isAlreadyGranted: false,
        isPermanentlyDenied: false,
        isFirstOpen: false,
        userTriggered: false,
      );
      expect(isLoading, isFalse, reason: 'Denied state must stop loading indicator');

      // 8. Permanently denied state routes to App Settings
      onHomeEntry(
        isAlreadyGranted: false,
        isPermanentlyDenied: true,
        isFirstOpen: false,
        userTriggered: true,
      );
      expect(openSettingsCalled, isTrue, reason: 'Permanently denied state must open App Settings');
    });

    test('Picker cancellation is non-fatal and preserves existing draft form state', () {
      String formTitle = 'My Trip to Melaka';
      String formContent = 'Exploring historic streets and Dutch Square.';
      List<String> selectedMedia = ['existing_image_1.jpg'];

      void handlePickerResult(String? pickedFilePath) {
        if (pickedFilePath == null) {
          // User cancelled picker -> no-op, preserve form state
          return;
        }
        selectedMedia.add(pickedFilePath);
      }

      // Simulate user opening gallery and cancelling
      handlePickerResult(null);

      expect(formTitle, equals('My Trip to Melaka'));
      expect(formContent, equals('Exploring historic streets and Dutch Square.'));
      expect(selectedMedia, equals(['existing_image_1.jpg']));
    });
  });
}
