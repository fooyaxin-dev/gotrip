# GoTrip RealTime Detect Place Modes Restoration & Verification Report (v2.1)

**Timestamp:** 2026-09-04  
**Project:** GoTrip (Flutter / Dart)  
**Deliverable Version:** v2.1 (Correction & Hardening)  
**Scope:** Production fix in `detectPlacePage.dart`, test corrections and regression test in `realtime_detect_place_test.dart`, and honest coverage classification.

---

## 1. Executive Summary

This V2.1 delivery corrects the active category/subcategory candidate pool logic in `RealTimeDetectPage`, eliminates test overclaims by introducing an honest 5-tier coverage classification, replaces simulated tests with genuine production component and service tests, and provides an end-to-end regression test for origin-independent candidate selection.

### Key Corrections in V2.1
1. **Active Category/Subcategory Pool Fixed:**
   - Replaced the flawed branching (`if (_searchLocationName != null) pool = _searchPlaces; else if (...) pool = _landmarkPlaces;`) with `RealTimeDetectPage.getAvailableSubCategoriesForMode`.
   - Category and subcategory availability now strictly follows the current tab's Google candidate pool across all origins (normal GPS, search location, and landmark location):
     - **For You:** deduplicated DISTANCE + POPULARITY;
     - **Nearest:** DISTANCE only;
     - **Rank:** POPULARITY only.
   - Geoapify remains a supplemental source and is completely excluded from the Google Rank pool.
2. **Honest Test Alignment & Coverage Classification:**
   - **Test 1:** Uses production `RealTimeDetectPage.defaultSortMode` constant (classified as structural production coverage).
   - **Test 3:** Verifies `ensurePopularityRound` returns a non-blocking background Future; classifies automatic page triggering as unverified pending real-phone testing.
   - **Test 11:** Extracts and pumps the exact production component `RealTimeDetectPage.buildRankLoadingIndicator()` used inside `_buildPlaceListSheet` (classified as production component-widget coverage).
   - **Test 12:** Tests candidate pool resolution via `RealTimeDetectPage.getCandidatesForTab`; classifies UI scroll and filter preservation as unverified pending real-phone testing.
   - **Test 13:** Classifies async generation concurrency protection as source-reviewed structural analysis, noting the exact production guard (`if (!mounted || generation != _detectGeneration) return;`).
   - **Test 18:** Exercises real caching with injected mock HTTP client, proving both caches populate independently, hit on repeat requests, and do not cross-satisfy each other.
3. **Production-Connected Regression Test (Test 23):**
   - Exercises `RealTimeDetectPage.getAvailableSubCategoriesForMode` to prove that in Rank mode, only POPULARITY candidates determine subcategories; a subcategory existing only in DISTANCE does not appear in Rank; and a subcategory existing only in POPULARITY does appear in Rank.
4. **Verification Truth:**
   - Target static analysis: **0 errors, 4 warnings** (all 4 are pre-existing baseline warnings in `detectPlacePage.dart`).
   - Dedicated suite (`realtime_detect_place_test.dart`): **23/23 tests PASS**.
   - Full project test suite (`flutter test`): **FAIL** (due to pre-existing failure in `test/journal_photo_loading_test.dart`).

---

## 2. Baseline & Protected Files Invariant Proof

The 4 protected files remain completely untouched and verified via SHA256 checksums:

| Protected File Path | Baseline SHA256 Hash | Ending SHA256 Hash | Status |
| :--- | :--- | :--- | :--- |
| `lib/services/userPreference_service.dart` | `C71E8F1B94B4C8E18CA0E19AFD9522540460A62038A41AE2903B4E53BFBA46B3` | `C71E8F1B94B4C8E18CA0E19AFD9522540460A62038A41AE2903B4E53BFBA46B3` | **MATCH (Untouched)** |
| `lib/modules/main/mainpage.dart` | `5C3458DFC56654B9E6CB77F5971A5B7AC7FD13DDE2664AA9ECE6E61C2178BA57` | `5C3458DFC56654B9E6CB77F5971A5B7AC7FD13DDE2664AA9ECE6E61C2178BA57` | **MATCH (Untouched)** |
| `lib/models/placeModel.dart` | `A3CA1720A2F3A66578E84BCD2AB17D91C51229A25C14E8D7BF98B2ABB58E8076` | `A3CA1720A2F3A66578E84BCD2AB17D91C51229A25C14E8D7BF98B2ABB58E8076` | **MATCH (Untouched)** |
| `lib/services/category_mapper.dart` | `EC6795643EF26ABA00EF699F7E1B333D0C6E7B515A801A66E04E8CD2DF4EC44A` | `EC6795643EF26ABA00EF699F7E1B333D0C6E7B515A801A66E04E8CD2DF4EC44A` | **MATCH (Untouched)** |

### Modified Files SHA256 Checksums
| Modified File Path | Ending SHA256 Hash | V2.1 Edit Scope |
| :--- | :--- | :--- |
| `lib/modules/place/detectPlacePage.dart` | `C03CDAE69EFBE0782DAA948B3317136D54281EADE2F272296E2F593E1010D63B` | Production Fixes Applied |
| `lib/services/nearbyPlace_service.dart` | `490B25E4F2E8DCCA5DF17C47B158F7A390892D892CAB1BFF23AC975CEAC55E40` | Intact from V2 |
| `lib/services/placesAPI_service.dart` | `6F396A0303EC8FD85207B40582AB10BF5769CFFD2A70213256147F1E06F57C0F` | Intact from V2 |
| `test/realtime_detect_place_test.dart` | `69E8D3C196705C42962B23A8F2C33C707834AB553959CD1370292C4E5C700B00` | Test Suite Corrected (23 Tests) |

---

## 3. Honest Coverage Classification

To prevent overclaiming, verification across all features is categorized into 5 explicit tiers:

### Tier 1: Full Production Widget Tests
- **Status:** Not applicable in headless testing.
- **Reason:** In standard headless `flutter test`, native platform views (`GoogleMap`) fail to instantiate because native Android/iOS view hierarchies and platform channels are absent. Full-page interaction must be verified on a physical device.

### Tier 2: Production Component-Widget Tests
- **Test 11:** Tests `RealTimeDetectPage.buildRankLoadingIndicator()`. Pumps the exact widget extracted from `_buildPlaceListSheet` and verifies `TravelLoadingIndicator` and `'Loading ranked places...'` text.

### Tier 3: Production Helper & Service Tests
- **Tests 2, 4, 6, 7, 8, 9, 10, 14, 15, 22, 23:** Exercise production static methods on `RealTimeDetectPage` (`combineForYouPool`, `sortNearestPlaces`, `sortRankPlaces`, `getCandidatesForTab`, `getAvailableSubCategories`, `getAvailableSubCategoriesForMode`).
- **Tests 5, 16, 17, 18, 19, 20, 21:** Exercise production service logic on `NearbyPlacesService`, `PlacesApiService`, and `UserPreferenceService` with injected mock HTTP clients.

### Tier 4: Source-Reviewed Structural Analysis
- **Test 1:** Verifies `RealTimeDetectPage.defaultSortMode` constant and initialization structure.
- **Test 13:** Verifies async generation concurrency guard structure in source code (`_prefetchPopularityRound`).

### Tier 5: Real-Phone-Only Verification (Unverified in Headless Suite)
- **Automatic page-level background trigger of Popularity after Distance:** Requires live GPS/location stream on a physical device or emulator.
- **Map marker icon updates and smooth camera fitting:** Requires OpenGL/Metal platform view rendering.
- **Preservation of scroll offset across asynchronous UI rebuilds:** Requires user gestures and live viewport rendering.

---

## 4. Active Category/Subcategory Pool Correction

### 4.1 The Flaw in Previous Logic
In V2, `_getAvailableSubCategories()` contained:
```dart
if (_searchLocationName != null) {
  pool = _searchPlaces;
} else if (widget.landmarkLat != null && widget.landmarkLng != null) {
  pool = _landmarkPlaces;
} else {
  pool = _getCandidatesForTab(_sortMode);
}
```
This was flawed because:
- `_searchPlaces` and `_landmarkPlaces` contain mixed POIs from Geoapify and Distance, rather than honoring the active tab mode.
- In Rank mode under search or landmark location, it failed to use the POPULARITY pool!

### 4.2 The V2.1 Production Fix
`_distancePlaces` and `_popularityPlaces` represent the active origin (whether GPS, search, or landmark). Therefore, candidate availability must ALWAYS be derived from the active tab mode:

```dart
  static List<Map<String, dynamic>> getAvailableSubCategoriesForMode({
    required SortMode mode,
    required List<PlaceModel> distancePlaces,
    required List<PlaceModel> popularityPlaces,
    required String? selectedPrimary,
    required Map<String, List<Map<String, dynamic>>> subCategoriesConfig,
    Map<String, Set<String>>? specificTypesCache,
  }) {
    final pool = getCandidatesForTab(
      mode: mode,
      distancePlaces: distancePlaces,
      popularityPlaces: popularityPlaces,
    );
    return getAvailableSubCategories(
      selectedPrimary: selectedPrimary,
      activeCandidatePool: pool,
      subCategoriesConfig: subCategoriesConfig,
      specificTypesCache: specificTypesCache,
    );
  }
```

The page state calls this helper directly:
```dart
  List<Map<String, dynamic>> _getAvailableSubCategories() {
    return RealTimeDetectPage.getAvailableSubCategoriesForMode(
      mode: _sortMode,
      distancePlaces: _distancePlaces,
      popularityPlaces: _popularityPlaces,
      selectedPrimary: _selectedPrimary,
      subCategoriesConfig: subCategories,
      specificTypesCache: _specificTypesCache,
    );
  }
```

---

## 5. Corrections to Misleading Tests

1. **Test 1 (Default Mode):**
   - **Before:** Checked `SortMode.recommended` against itself.
   - **Now:** Asserts `RealTimeDetectPage.defaultSortMode == SortMode.recommended` and proves it initializes `_sortMode` in production state.
2. **Test 3 (Background Popularity Trigger):**
   - **Before:** Claimed manual calls proved automatic background triggering.
   - **Now:** Verifies the non-blocking Future contract of `ensurePopularityRound` and explicitly notes that automatic page-level trigger is unverified pending real-phone testing.
3. **Test 11 (Rank Loading Indicator):**
   - **Before:** Recreated a duplicate `Builder` hierarchy in the test file.
   - **Now:** Directly pumps `RealTimeDetectPage.buildRankLoadingIndicator()`, the exact component used inside `_buildPlaceListSheet`.
4. **Test 12 (State Preservation):**
   - **Before:** Asserted local variables `selectedPrimary` and `preserveScroll`.
   - **Now:** Focuses on candidate pool update via `getCandidatesForTab` and classifies scroll/filter preservation as unverified pending real-phone testing.
5. **Test 13 (Stale Response Protection):**
   - **Before:** Simulated a local integer generation counter.
   - **Now:** Documents the production guard `if (!mounted || generation != _detectGeneration) return;` and classifies runtime verification as unverified pending real-phone testing.
6. **Test 18 (Cache Isolation):**
   - **Before:** Only compared cache-key strings.
   - **Now:** Exercises real network requests with mock client, proving:
     - First DISTANCE request queries API; second DISTANCE request hits cache.
     - First POPULARITY request queries API (proving DISTANCE did not satisfy POPULARITY); second POPULARITY request hits popularity cache.

---

## 6. Regression Test for Active Candidate Pool (Test 23)

Test 23 in `test/realtime_detect_place_test.dart` exercises `RealTimeDetectPage.getAvailableSubCategoriesForMode`:
- Given `distanceOnlyCafe` (in Distance pool) and `popularityOnlyBar` (in Popularity pool):
  - In **Rank mode (`SortMode.rating`)**: returns `['bar']`; `cafe` is excluded.
  - In **Nearest mode (`SortMode.distance`)**: returns `['cafe']`; `bar` is excluded.
  - In **For You mode (`SortMode.recommended`)**: returns both `['cafe', 'bar']`.

---

## 7. Verification Truth & Raw Evidence

### 7.1 Static Analysis (`flutter analyze`)
Command:
```powershell
flutter analyze lib/modules/place/detectPlacePage.dart lib/services/nearbyPlace_service.dart lib/services/placesAPI_service.dart test/realtime_detect_place_test.dart
```

**Result: `0 errors, 4 warnings`**

The 4 warnings are pre-existing in baseline `detectPlacePage.dart`:
1. `warning - The value of the field '_placeScores' isn't used - lib\modules\place\detectplacepage.dart:362:23 - unused_field`
2. `warning - The declaration '_updateRouteTimesForTravelMode' isn't referenced - lib\modules\place\detectplacepage.dart:2036:8 - unused_element`
3. `warning - The declaration '_showErrorDialog' isn't referenced - lib\modules\place\detectplacepage.dart:2134:8 - unused_element`
4. `warning - The declaration '_showLocationDisabledDialog' isn't referenced - lib\modules\place\detectplacepage.dart:2149:16 - unused_element`

`nearbyPlace_service.dart`, `placesAPI_service.dart`, and `test/realtime_detect_place_test.dart` have **0 errors and 0 warnings**.

### 7.2 Dedicated Test Suite
Command:
```powershell
flutter test test/realtime_detect_place_test.dart
```

**Result: PASS (23/23 tests passed)**

```text
00:00 +1: Group 1: Mode Selection & Defaults 1. For You is the default mode (RealTimeDetectPage.defaultSortMode) upon initialization [Structural Production Coverage]
00:00 +2: Group 1: Mode Selection & Defaults 2. DISTANCE results are usable immediately without awaiting POPULARITY [Production Seam Coverage]
00:00 +3: Group 1: Mode Selection & Defaults 3. Background POPULARITY Future invocation [Service Async Boundary; Automatic Page Triggering Unverified Pending Real-Phone Testing]
00:00 +4: Group 2: For You Mode 4. For You candidate pool combines and deduplicates DISTANCE and POPULARITY preserving distance instance [Production Seam Coverage]
00:00 +5: Group 2: For You Mode 5. UserPreferenceService.instance.buildForYouList processes combined pool without altering ranking algorithm [Production Helper Coverage]
00:00 +6: Group 3: Nearest Mode 6. Nearest tab uses ONLY DISTANCE candidates and strictly excludes POPULARITY-only places [Production Seam Coverage]
00:00 +7: Group 3: Nearest Mode 7. Nearest sorts distance ascending and places with missing distance last [Production Seam Coverage]
00:00 +8: Group 4: Rank Mode 8. Rank tab uses ONLY POPULARITY candidates and strictly excludes DISTANCE-only places [Production Seam Coverage]
00:00 +9: Group 4: Rank Mode 9. Rank sorts rating descending and places with missing rating last [Production Seam Coverage]
00:00 +10: Group 4: Rank Mode 10. Equal-rating Rank results break ties using POPULARITY response order first, then distance [Production Seam Coverage]
00:00 +11: Group 4: Rank Mode 11. Rank displays honest loading indicator when POPULARITY is loading [Production Component-Widget Coverage]
00:00 +12: Group 4: Rank Mode 12. POPULARITY candidate pool integration [Service Seam Coverage; UI Scroll/Filter Preservation Unverified Pending Real-Phone Testing]
00:00 +13: Group 4: Rank Mode 13. Stale async response protection [Source-Reviewed Structural Analysis; Runtime Guard Unverified Pending Real-Phone Testing]
00:00 +14: Group 5: Category Filtering 14. Search-mode category filtering operates strictly on active candidate pool [Production Seam Coverage]
00:00 +15: Group 5: Category Filtering 15. Landmark-mode category filtering operates strictly on active candidate pool [Production Seam Coverage]
00:00 +16: Group 6: Google Places API & Cache Isolation 16. One failed Google type group retains successful groups without throwing away valid data [Production Service Coverage]
00:00 +17: Group 6: Google Places API & Cache Isolation 17. PlacesApiService sends correct rankPreference payload in DISTANCE and POPULARITY requests [Production Service Coverage]
00:00 +18: Group 6: Google Places API & Cache Isolation 18. DISTANCE and POPULARITY caches remain strictly isolated and do not cross-satisfy [Production Service Coverage]
00:00 +19: Group 6: Google Places API & Cache Isolation 19. Request inside an already fetched radius hits cache without refetching and filters to requested radius [Production Service Coverage]
00:00 +20: Group 6: Google Places API & Cache Isolation 20. LRU eviction removes actual stored cache entries and radius tracking [Production Service Coverage]
00:00 +21: Group 6: Google Places API & Cache Isolation 21. Missing-coordinate and out-of-radius results are rejected during production parsing and filtering [Production Service Coverage]
00:00 +22: Group 6: Google Places API & Cache Isolation 22. Geoapify candidates remain outside the Google Rank pool [Production Seam Coverage]
00:01 +23: Group 7: Active Origin Candidate Pool Regression 23. Active tab Google candidate pool dictates category/subcategory availability across normal, search, and landmark origins [Production Seam Coverage]
00:01 +23: All tests passed!
```

### 7.3 Full Project Test Suite (`flutter test`)
Command:
```powershell
flutter test
```

**Result: FAIL (Exit code 1)**
- Passed: 302 tests
- Failed: 1 test (`test/journal_photo_loading_test.dart: Programmatic TOC jump updates visible page, counter, active window, and renders destination content`)
- As required by Section 5 instructions, the full suite is reported strictly as **FAIL**.

### 7.4 Git Cleanliness & Diff Stats
- `git diff --check`: 0 whitespace errors or conflict markers.
- `git diff --stat`:
```text
 lib/modules/place/detectPlacePage.dart | 3048 ++++++++++++++++++++++----------
 lib/services/nearbyPlace_service.dart  |  900 ++++++----
 lib/services/placesAPI_service.dart    |   25 +-
 3 files changed, 2707 insertions(+), 1266 deletions(-)
```

---

## 8. Deliverables & Checksums

### Files in `gotrip_detect_place_modes_restore_v2_1_output.zip`:
1. `lib/modules/place/detectPlacePage.dart`
2. `lib/services/nearbyPlace_service.dart`
3. `lib/services/placesAPI_service.dart`
4. `test/realtime_detect_place_test.dart`
5. `gotrip_detect_place_modes_restore_v2_1_report.md`
6. `evidence_v2_1/01_dart_format.txt`
7. `evidence_v2_1/02_flutter_analyze.txt`
8. `evidence_v2_1/03_flutter_test_realtime.txt`
9. `evidence_v2_1/04_flutter_test_all.txt`
10. `evidence_v2_1/05_git_diff_check.txt`
11. `evidence_v2_1/06_git_status.txt`
12. `evidence_v2_1/07_git_diff_stat.txt`
13. `evidence_v2_1/08_sha256_hashes.txt`

---

## 9. Conclusion

All misleading tests have been corrected, candidate pool availability has been strictly unified with the active tab mode across all origins, real cache isolation has been verified, and all evidence has been preserved in plain-text output files.
