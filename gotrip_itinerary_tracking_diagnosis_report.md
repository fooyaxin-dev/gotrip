# GoTrip Production Itinerary Location-Tracking, Arrival Detection, Check-In & Completion Flow Diagnosis Report

**Diagnosis Date**: September 4, 2026  
**Target Module**: Dynamic Itinerary & Location Tracking  
**Analysis Scope**: Production Code Investigation & Flow Verification (Diagnosis Only)  
**Codebase Files Audited**:
- `lib/modules/itinerary/itineraryDetail.dart`
- `lib/services/location_service.dart`
- `lib/models/itineraryModel.dart`
- `lib/services/itinerary_service.dart`
- `android/app/src/main/AndroidManifest.xml`
- `test/arrival_and_dashboard_trace_test.dart`
- `test/location_refresh_test.dart`
- `test/itinerary_pdf_export_test.dart`

---

## Executive Summary & Verdict

### Verdict: **Partially Working with High-Risk Limitations & Edge-Case Bugs**

While the core happy-path flow (proximity threshold check, arrival dialog presentation, and atomic Firestore batch write for check-in) is structurally implemented and functions under ideal foreground conditions, the system suffers from **critical lifecycle leaks**, **missing initial position evaluation**, **lack of error handling on GPS streams**, and **complete absence of automated integration tests**.

| Flow Component | Status | Key Risk / Limitation |
| :--- | :---: | :--- |
| **A. Startup Flow** | ⚠️ Partial | Starts tracking on open only if today matches an itinerary day with unvisited places; does **not** evaluate current location on open (stalls if stationary). |
| **B. GPS Source & Freshness** | ⚠️ High Risk | `getPositionStream` with `distanceFilter: 10`, `high` accuracy; **no error callback**; accuracy value ignored; no background location. |
| **C. Watched Place Scope** | ⚠️ Partial | Watches only today's calendar day; tab switching does not alter tracking; duplicate `placeId` on same day causes collisions. |
| **D. Arrival Detection** | ⚠️ High Risk | 50m radius (Haversine); **zero** dwell time or accuracy guard; single noisy point triggers; no cooldown on "Not yet". |
| **E. Dialog & Visited State** | ⚠️ Partial | Requires user confirmation; atomic Firestore batch write; but Android back button bypasses rearm, and persistence failure locks place out. |
| **F. Completion Calculation** | ⚠️ Flawed | Purely dynamic getter (`totalVisited == totalPlaces`); empty days cause premature trip completion; no completion screen. |
| **G. Lifecycle & Resources** | ❌ Broken | `dispose()` does **not** clear `_watchedPlaces`; background `MainPage` stream silently consumes itinerary arrivals when page is closed. |
| **H. Test Coverage** | ❌ None | **0 tests** exist for itinerary location tracking, arrival triggering, dialog flow, persistence failure, or cleanup. |

---

## Detailed Production Code Trace & Answers (Sections A–H)

### A. Startup Flow

1. **Exact Call Chain from `ItineraryDetailPage.initState()`**:
   - `ItineraryDetailPage.initState()` (`lib/modules/itinerary/itineraryDetail.dart:47-55`):
     ```dart
     @override
     void initState() {
       super.initState();
       _itinerary = widget.itinerary;
       _tabController = TabController(
         length: _itinerary.days.length,
         vsync: this,
       );
       _refreshItineraryTracking();
     }
     ```
   - `_refreshItineraryTracking()` (`lib/modules/itinerary/itineraryDetail.dart:68-84`):
     ```dart
     void _refreshItineraryTracking() {
       final shouldTrack = LocationService.instance.watchItinerary(_itinerary);

       if (shouldTrack && !_didStartLocationTracking) {
         LocationService.instance.startTracking();
         _didStartLocationTracking = true;
         _arrivalSub ??= LocationService.instance.arrivalStream.listen(_onArrival);
         return;
       }

       if (!shouldTrack && _didStartLocationTracking) {
         LocationService.instance.stopTracking();
         _didStartLocationTracking = false;
         _arrivalSub?.cancel();
         _arrivalSub = null;
       }
     }
     ```

2. **API Calls on Open**:
   - `watchItinerary()`: **YES**, called synchronously from `_refreshItineraryTracking()`.
   - `startTracking()`: **YES**, called if `shouldTrack == true` and `!_didStartLocationTracking`.
   - `getCurrentPosition()`: **NO**. Opening `ItineraryDetailPage` does **not** call `getCurrentPosition()` or `refreshCurrentLocation()`.
   - `getPositionStream()`: **YES**, invoked inside `LocationService.startTracking()` (`lib/services/location_service.dart:282-288`) **only if `_positionStream == null`**. If `MainPage` or `HomePage` has already started tracking, it simply increments reference count `_watcherCount++` and reuses the active subscription.

3. **Immediate vs. Conditional Start**:
   - Tracking starts immediately inside `initState()`, but is conditional on `watchItinerary(_itinerary)` returning `true`.

4. **Conditions for `watchItinerary()` Return Value**:
   - In `LocationService.watchItinerary(ItineraryModel itinerary)` (`location_service.dart:140-193`):
     - Parses `itinerary.days[].date` and compares to `today = DateTime(now.year, now.month, now.day)`.
     - Looks for `activeDayIndex`. If no day date equals today, prints `'📍 Arrival watch inactive: itinerary has no day scheduled for today.'` and returns `false`.
     - If today is found, filters `activeDay.places` where `!place.isVisited && place.lat != null && place.lng != null`.
     - Returns `_watchedPlaces.isNotEmpty`.
   - Therefore, returns `true` **only if** today matches a scheduled day in the itinerary that contains at least one unvisited place with valid coordinates.

5. **Itinerary State Matrix**:
   - **All places unvisited**: Tracks if scheduled for today. If scheduled for a future or past date, returns `false`.
   - **Some places visited**: Tracks if at least one place on today's day is unvisited.
   - **All places visited**: Returns `false`.
   - **Empty days**: Returns `false`.
   - **Future dates**: Returns `false`.
   - **Past dates**: Returns `false`.

6. **Interaction with PDF Export**:
   - **Zero interaction**. `_exportPdf()` strictly passes in-memory `_itinerary` to `ItineraryPdfService`. PDF export is purely read-only and never interacts with `LocationService` or `arrivalStream`.

---

### B. GPS Source and Freshness

1. **Exact Geolocator Method & Settings**:
   - In `LocationService.startTracking()` (`lib/services/location_service.dart:282-288`):
     ```dart
     Geolocator.getPositionStream(
       locationSettings: const LocationSettings(
         accuracy: LocationAccuracy.high,
         distanceFilter: 10,
       ),
     );
     ```

2. **Stream Characteristics**:
   - Continuous, distance-filtered stream.
   - It is **not** periodic (no timer interval).
   - It is **not** cached.
   - It is **not** one-shot on page entry.

3. **GPS Configurations & Permissions**:
   - **Accuracy**: `LocationAccuracy.high`.
   - **Distance Filter**: `10` metres (`distanceFilter: 10`).
   - **Update Interval**: Platform/hardware driven by the 10m displacement.
   - **Android Foreground / Background**:
     - Uses standard `LocationSettings` instead of `AndroidSettings(foregroundNotificationConfig: ...)`.
     - `AndroidManifest.xml` declares only `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, and `INTERNET`.
     - **No background location permissions** (`ACCESS_BACKGROUND_LOCATION`) and **no foreground service** (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`).
     - When the app is backgrounded or the screen is turned off, Android OS pauses/throttles location updates.
   - **Permission Handling in `startTracking()`**:
     - `startTracking()` calls `Geolocator.getPositionStream()` **directly without checking permissions or checking whether location services are enabled**.

4. **Freshness on Page Open**:
   - It does **neither**. It does not fetch a fresh location fix, nor does it evaluate existing `currentPosition` against `_watchedPlaces`. It passively listens for future stream events.

5. **Stale Position Impact**:
   - **Delay**: If a user is already at the destination when opening the page, arrival will **never trigger while the user remains stationary**. The user must move $\ge 10$m to force a hardware stream event.
   - **False Trigger**: If the platform location provider emits an old cached position as the first event, `LocationService.isPositionFresh()` is **not** called in `_checkProximity()`, potentially triggering arrival based on a stale reading.

6. **Error Conditions**:
   - **Permission Denied / Denied Forever / Location Services Disabled**:
     - `Geolocator.getPositionStream` throws or emits a stream error.
     - `_positionStream = stream.listen(...)` has **no `onError:` handler**, causing an unhandled zone exception.
   - **Poor Location Accuracy**:
     - `pos.accuracy` is completely ignored. If GPS accuracy degrades to 100m–500m indoors, any reading whose center falls within 50m of a venue triggers arrival immediately.

---

### C. Watched Places and Itinerary Scope

1. **Watched Subset**:
   - **Only today's scheduled day**: Matches `activeDayIndex` where `day.date == today`.
   - Only unvisited places (`!place.isVisited`) with non-null `lat` and `lng`.
   - Future and past itinerary days are excluded.

2. **Day Tab Switching**:
   - Switching tabs in the UI via `_tabController` does **nothing** to tracking. The tracker continues watching today's calendar day.

3. **Future-Day Places**:
   - Ineligible. Never added to `_watchedPlaces`.

4. **Already Visited Places**:
   - Excluded during `watchItinerary()` construction (`if (!place.isVisited && ...)`).

5. **Itinerary Editing / Reordering**:
   - When edited via `_editItinerary()` (`itineraryDetail.dart:1128`), `_refreshItineraryTracking()` is called with the updated itinerary.
   - When returning from guide navigation (`itineraryDetail.dart:1304`), `_refreshItineraryTracking()` is called.
   - Remote Firestore edits do not update tracking because there is no live Firestore snapshot listener on `_itinerary`.

6. **Place Matching Identity**:
   - `_checkProximity()` matches against `_WatchedPlace.lat` and `lng`.
   - On match, emits `PlaceArrivalEvent(placeId: watched.placeId, placeName: watched.placeName, dayIndex: watched.dayIndex, placeIndex: watched.placeIndex)`.
   - `_onArrival()` re-resolves the target place in `_itinerary.days` by searching `place.placeId == event.placeId`.

7. **Duplicate Place ID Collisions**:
   - If an itinerary includes the same place twice on the same day:
     - `_alreadyArrived` tracks by `placeId`. Once the first stop arrives, `_alreadyArrived.add(placeId)` suppresses the second stop from ever triggering.
     - In `_onArrival()`, `_itinerary.days[d].places.indexWhere((p) => p.placeId == event.placeId)` always returns the first matching index.
     - Firestore history doc ID `${itinerary.id}_$safePlaceId` collides, overwriting the first visit record.

---

### D. Arrival Detection Algorithm

1. **Exact Distance Calculation**:
   - Haversine formula implemented in `LocationService._distanceMetres` (`location_service.dart:357-364`):
     $$\text{dist} = 2 R \arcsin \sqrt{\sin^2\left(\frac{\Delta \text{lat}}{2}\right) + \cos(\text{lat}_1)\cos(\text{lat}_2)\sin^2\left(\frac{\Delta \text{lng}}{2}\right)}$$
     where $R = 6,371,000$ metres.

2. **Exact Arrival Radius**:
   - `static const double _arrivalRadiusMetres = 50;` (50 metres; condition `dist <= 50`).

3. **GPS Accuracy Filtering**:
   - **None**. `pos.accuracy` is never inspected.

4. **Dwell Time, Consecutive Readings, Debounce, Cooldown & Hysteresis**:
   - **Dwell Time**: None.
   - **Consecutive Readings**: None (single fix triggers).
   - **Debounce / Hysteresis**: None.
   - **Cooldown**: None. When dismissed via "Not yet", `rearmArrival()` is called immediately. If the user remains within 50m, the very next GPS event immediately re-triggers the dialog.

5. **Single Noisy Reading**:
   - **Yes**. A single momentary GPS jump $\le 50$m triggers the arrival dialog.

6. **Multiple Arrivals for the Same Place**:
   - Prevented by `_alreadyArrived.contains(watched.placeId)` until rearmed.

7. **Simultaneous Dialog Prevention**:
   - Guarded by `bool _isArrivalDialogOpen` in `ItineraryDetailPage`.
   - If `_isArrivalDialogOpen == true` when an event arrives:
     - `LocationService.instance.rearmArrival(event.placeId);`
     - The incoming arrival is discarded for now so dialogs do not stack.

8. **Overlapping Events**:
   - The secondary event is discarded, but rearmed so that subsequent GPS fixes can trigger it after the current dialog closes.

9. **Multiple Nearby Places ($\le 50$m apart)**:
   - Both match in the `_checkProximity` loop. Place A triggers the dialog. Place B arrives while `_isArrivalDialogOpen == true`, is rearmed, and suppressed until another GPS update occurs after Place A's dialog closes.

---

### E. Arrival Dialog and Visited State

1. **Exact Execution Sequence**:
   - GPS Position $\to$ `_checkProximity()` $\to$ Haversine $\le 50$m $\to$ `_alreadyArrived.add(placeId)` $\to$ `_arrivalController.add(PlaceArrivalEvent)` $\to$ `ItineraryDetailPage._onArrival(event)` $\to$ `showDialog(_ArrivedDialog)` $\to$ user taps "Yes, I'm here!" $\to$ `_markVisited(resolvedDayIndex, resolvedPlaceIndex)`.

2. **User Confirmation Requirement**:
   - **Strictly required**. A place is never marked visited automatically without user confirmation in `_ArrivedDialog`.

3. **Available Dialog Actions**:
   - **"Not yet" (`onDismiss`)**: Calls `Navigator.pop(context)` and `LocationService.instance.rearmArrival(event.placeId)`. Place remains unvisited.
   - **"Yes, I'm here!" (`onConfirm`)**: Calls `Navigator.pop(context)` and `_markVisited(...)`.
   - **System Back Button**: `_ArrivedDialog` is **not** wrapped in `PopScope`. If the user presses the Android back button, the dialog dismisses, but neither `onDismiss` nor `onConfirm` runs. `rearmArrival()` is **bypassed**, leaving the place permanently locked in `_alreadyArrived`!

4. **Re-arm on Dismissal**:
   - Tapping "Not yet" re-arms the place.
   - Android back button dismisses without re-arming.

5. **Visited Confirmation Flow & Persistence**:
   - **Model Update**:
     ```dart
     final visited = places[placeIndex].copyWith(
       isVisited: true,
       visitedAt: DateTime.now(),
     );
     ```
   - **Persistence Method**:
     `ItineraryService.instance.commitCheckIn(itinerary: updatedItinerary, visitedPlace: visited);`
   - **Firestore Paths**:
     - Itinerary Doc: `users/{uid}/itineraries/{itinerary.id}`
     - History Doc: `users/{uid}/history/{itinerary.id}_{safePlaceId}`
     - Performed atomically via `_db.batch()`:
       `batch.update(itineraryDoc, itinerary.toMap());`
       `batch.set(historyDoc, historyData);`
       `await batch.commit();`
   - **UI Update Timing**:
     - `setState(() => _itinerary = updatedItinerary)` occurs **only after** `await batch.commit()` resolves successfully.

6. **Persistence Failure Handling**:
   - Error caught in `catch (e)`.
   - `ErrorHandler.showError(context, message: 'Check-in could not be saved. Please check your connection and try again.')` is displayed.
   - `setState` does not run.
   - `_checkInProgress.remove(placeId)` executes in `finally`.
   - **Bug**: `rearmArrival(placeId)` is **not** called on failure. The place remains stuck in `LocationService._alreadyArrived`.

7. **UI vs. Firestore Discrepancy**:
   - UI cannot show visited if Firestore fails, because `setState` is strictly gated behind successful commit.

8. **`visitedAt` Timestamp**:
   - Set to `DateTime.now()` (device local time).

---

### F. Completion Behaviour

1. **Exact Code Implementation**:
   - `ItineraryDay.isCompleted` (`lib/models/itineraryModel.dart:233`):
     ```dart
     int get visitedCount => places.where((p) => p.isVisited).length;
     int get totalCount => places.length;
     bool get isCompleted => totalCount > 0 && visitedCount == totalCount;
     ```
   - `ItineraryModel.isCompleted` (`lib/models/itineraryModel.dart:425`):
     ```dart
     int get totalVisited => days.fold(0, (sum, d) => sum + d.visitedCount);
     int get totalPlaces => days.fold(0, (sum, d) => sum + d.totalCount);
     bool get isCompleted => totalPlaces > 0 && totalVisited == totalPlaces;
     ```

2. **All-Place Requirement**:
   - Requires every place across all days in the itinerary to be visited (`totalVisited == totalPlaces`).

3. **Empty Day Handling**:
   - An empty day has `totalCount == 0`, contributing `0` to both `totalVisited` and `totalPlaces`.
   - **Bug**: If a 3-day trip has places on Day 1, but Days 2 and 3 are empty, completing Day 1 marks the entire 3-day itinerary as `isCompleted == true`.

4. **Immediate Aftermath of Final Check-in**:
   - `_markVisited` runs `_refreshItineraryTracking()`.
   - `watchItinerary()` finds 0 remaining unvisited places for today, returning `false`.
   - `stopTracking()` is called; `_arrivalSub` is cancelled.
   - Edit button on the detail page becomes disabled (`_itinerary.isCompleted ? null : _editItinerary`).

5. **Completion UX & Navigation**:
   - **No completion dialog**.
   - **No automatic navigation**.
   - `AchievementService.instance.checkForNewUnlocks()` evaluates if a general badge (e.g. Explorer) is earned, but there is no itinerary-specific completion modal.

6. **Persistence of `isCompleted`**:
   - `isCompleted` is **not** stored as a field in Firestore (`toMap()` does not write `isCompleted`). It is evaluated dynamically upon model deserialization.

7. **False Completion Scenarios**:
   - Empty scheduled days cause multi-day itineraries to complete early.
   - Duplicate `placeId` entries do not cause false completion because `totalPlaces` counts raw array length.

---

### G. Lifecycle and Resource Safety

1. **Page Exit Behavior**:
   - `ItineraryDetailPage.dispose()` (`itineraryDetail.dart:58-66`):
     ```dart
     @override
     void dispose() {
       _arrivalSub?.cancel();
       if (_didStartLocationTracking) {
         LocationService.instance.stopTracking();
         _didStartLocationTracking = false;
       }
       _tabController.dispose();
       super.dispose();
     }
     ```

2. **Stream & Subscription Cleanup**:
   - `_arrivalSub` is cancelled.
   - `LocationService.stopTracking()` decrements `_watcherCount`.
   - If `_watcherCount == 0`, `_positionStream?.cancel()` runs.

3. **Global Tracking After Page Closes**:
   - `MainPage` (`mainpage.dart:200`) and `HomePage` (`homepage.dart:102`) both call `startTracking()`.
   - Because `MainPage` remains mounted underneath `ItineraryDetailPage`, `_watcherCount` was already $\ge 1$.
   - When `ItineraryDetailPage` closes, `_watcherCount` decrements to 1. **The GPS stream continues running**.

4. **Critical Lifecycle Leak (`_watchedPlaces` Retention)**:
   - `ItineraryDetailPage.dispose()` **never calls `LocationService.instance.pauseItineraryProximity()`**.
   - `_watchedPlaces` remains populated with the closed itinerary's places while the user browses `MainPage`!
   - As the user moves, `LocationService._checkProximity()` continues testing GPS fixes against the closed itinerary places.
   - If the user passes within 50m of a venue, `_alreadyArrived.add(placeId)` is called in the background.
   - When the user later re-opens that same itinerary, `watchItinerary()` does not clear `_alreadyArrived` because `_watchedItineraryId == itinerary.id`.
   - **Result**: The venue is permanently blocked from triggering arrival detection in that session.

5. **App Backgrounding and Resuming**:
   - No `WidgetsBindingObserver` in `ItineraryDetailPage`.
   - On background, Android freezes GPS stream without a foreground service.
   - On resume, stream passively unfreezes, but no fresh location is requested.

6. **Android Foreground Service Status**:
   - Completely absent. No background tracking capability.

7. **Battery Drain**:
   - Continuous `LocationAccuracy.high` with `distanceFilter: 10` kept alive by `MainPage` causes sustained battery drain during all foreground app usage.

---

### H. Existing Test Quality & Gap Analysis

An exhaustive search across the entire `test/` directory reveals **zero automated tests** for the production itinerary location tracking and arrival flow.

| Flow Area | Test Coverage Status | Existing Test Details / Missing Tests |
| :--- | :---: | :--- |
| **Tracking Startup on Open** | ❌ Not Covered | Only printed to console as side effect during widget tests in `itinerary_pdf_export_test.dart`. No assertions. |
| **Fresh / Live GPS Positions** | ❌ Not Covered | `location_refresh_test.dart` tests only movement baselines for `MainPage`, not arrival detection. |
| **Distance Boundary (49m vs 51m)** | ❌ Not Covered | No boundary tests exist for `_arrivalRadiusMetres = 50`. |
| **Inaccurate / Noisy GPS Filter** | ❌ Not Covered | No tests checking `pos.accuracy` behavior. |
| **Duplicate Arrival Suppression** | ⚠️ Injected Unit Only | `arrival_and_dashboard_trace_test.dart` simulates map deduplication for dashboard, but never tests `LocationService`. |
| **Dismissed Dialog Re-arm** | ❌ Not Covered | No test for `rearmArrival()` or dialog "Not yet" action. |
| **Simultaneous Nearby Places** | ❌ Not Covered | No test for multiple places $\le 50$m apart. |
| **Itinerary Reorder While Tracking**| ❌ Not Covered | No test verifying index resolution after drag-and-drop reorder. |
| **Persistence Success (`commitCheckIn`)** | ❌ Not Covered | No unit or integration test for batch commit of itinerary + history. |
| **Persistence Failure & Rollback** | ❌ Not Covered | No test for handling Firestore failure during check-in. |
| **Last-Place Completion** | ❌ Not Covered | No test verifying tracking shutdown upon final place check-in. |
| **Dispose Cleanup & Leak Prevention** | ❌ Not Covered | No test verifying `_watchedPlaces` cleanup upon page disposal. |
| **Permission / GPS Disabled Cases** | ❌ Not Covered | No test for `startTracking()` handling denied permissions or service off. |

---

## Ranked Risk & Bug Matrix

| Rank | Severity | Issue Description | File & Line Reference |
| :---: | :---: | :--- | :--- |
| **1** | **CRITICAL** | **Ghost Arrival Consumption on Page Exit**: `dispose()` does not clear `LocationService._watchedPlaces`. Since `MainPage` keeps the GPS stream running, walking near a place while outside the itinerary detail page silently adds it to `_alreadyArrived`, permanently locking out arrival detection upon return. | `itineraryDetail.dart:58-66`<br>`location_service.dart:135,148,346` |
| **2** | **CRITICAL** | **Unhandled Exception on Stream Error**: `LocationService.startTracking()` invokes `Geolocator.getPositionStream()` without checking permissions or location service status, and `stream.listen()` has no `onError` handler. Disabling GPS or revoking permission causes an unhandled zone crash or silent failure. | `location_service.dart:282-295` |
| **3** | **HIGH** | **Stationary Arrival Deadlock on Open**: Opening `ItineraryDetailPage` does not check current location or request a fresh position. If the user arrives at a destination and opens the app while stationary, arrival detection never triggers because `distanceFilter: 10` requires $\ge 10$m of movement. | `itineraryDetail.dart:68-84`<br>`location_service.dart:140-193,278-295` |
| **4** | **HIGH** | **Android Back Button Bypasses Re-arm**: `_ArrivedDialog` lacks `PopScope`. Dismissing the dialog via the system back button or swipe gesture pops the dialog without invoking `onDismiss` (`rearmArrival`), permanently locking the place as arrived. | `itineraryDetail.dart:149-175,1482-1565` |
| **5** | **HIGH** | **Permanent Lockout on Network Check-In Failure**: When `commitCheckIn()` fails (offline/timeout), `_markVisited()` catches the error, but never calls `rearmArrival()`. The place was already added to `_alreadyArrived`, so the user can never check in via GPS again. | `itineraryDetail.dart:287-302` |
| **6** | **HIGH** | **No Background Location / Service Declarations**: App lacks `ACCESS_BACKGROUND_LOCATION` and `FOREGROUND_SERVICE` declarations. When the phone is pocketed or screen turned off during transit, tracking stops completely. | `AndroidManifest.xml:8-12`<br>`location_service.dart:282-288` |
| **7** | **MEDIUM** | **Absence of Dwell Time & Accuracy Guard**: A single GPS jump or indoor triangulation with 200m accuracy instantly triggers arrival if the point falls within 50m of a venue. | `location_service.dart:334-355` |
| **8** | **MEDIUM** | **Duplicate `placeId` Collision on Same Day**: If a venue is scheduled twice on the same day, the second stop can never trigger arrival, and `_onArrival` `indexWhere` always targets the first stop. | `itineraryDetail.dart:114-124`<br>`location_service.dart:143-150,336` |
| **9** | **MEDIUM** | **No Cooldown on "Not Yet" Dismissal**: Rejecting check-in via "Not yet" re-arms immediately without a cooldown timer or distance hysteresis. The dialog re-pops immediately on the next GPS pulse. | `itineraryDetail.dart:167`<br>`location_service.dart:206-208` |
| **10** | **LOW** | **Premature Trip Completion from Empty Days**: An itinerary with empty trailing days marks the entire trip completed as soon as Day 1 places are visited. | `itineraryModel.dart:423-425` |

---

## Minimal Proposed Fix Plan (Diagnosis Only — No Changes Made)

1. **Fix Lifecycle Leak in `ItineraryDetailPage.dispose()`**:
   - Call `LocationService.instance.pauseItineraryProximity()` in `dispose()` to clear `_watchedPlaces` whenever the user navigates away from the itinerary.
2. **Add Initial Location Check on Open**:
   - In `_refreshItineraryTracking()`, check `LocationService.instance.currentPosition` or call `refreshCurrentLocation()`. If valid and fresh, run `_checkProximity()` immediately so stationary users get the arrival dialog upon opening the page.
3. **Guard Stream Listen with `onError`**:
   - Provide an `onError: (err) => debugPrint(...)` handler in `LocationService.startTracking()` to prevent unhandled stream crashes.
4. **Wrap `_ArrivedDialog` in `PopScope`**:
   - Ensure hardware back gestures invoke `LocationService.instance.rearmArrival(event.placeId)` so the place is not permanently lost.
5. **Re-arm on Check-In Failure**:
   - In `_markVisited()`, add `LocationService.instance.rearmArrival(currentPlace.placeId)` inside the `catch (e)` block if persistence fails.
6. **Implement Cooldown / Debounce for "Not Yet"**:
   - When "Not yet" is tapped, record a 5-minute cooldown timestamp for that `placeId` before allowing `_checkProximity` to trigger again.
7. **Filter by GPS Accuracy**:
   - In `_checkProximity(pos)`, require `pos.accuracy <= 65` (or `pos.accuracy <= _arrivalRadiusMetres + 15`) before declaring arrival.

---

## Verification & Workspace Status

- **Zero Source Files Modified**: Checked via `git status --short`. All existing source files, test files, and configs remain untouched.
- **No Fixes Implemented**: This task was diagnosis only.
- **Deliverables Prepared**:
  - `gotrip_itinerary_tracking_diagnosis_report.md`
  - `gotrip_itinerary_tracking_diagnosis_bundle.zip`
  - `SHA256SUMS_itinerary_tracking_diagnosis.txt`
