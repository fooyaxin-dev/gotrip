# V2.2 Minimal Corrective Edit Report — RealTime Detect Place Mode Invocations

**Repository:** `fooyaxin-dev/gotrip`  
**Date:** 2026-09-04  
**Deliverable Version:** V2.2  

---

## 1. Executive Summary

In V2.1, `_prefetchPopularityRound` was accidentally started twice along the landmark bootstrap path in [detectPlacePage.dart](file:///d:/gotrip/lib/modules/place/detectPlacePage.dart):
1. Inside the landmark bootstrap `if (widget.landmarkLat != null && widget.landmarkLng != null)` branch.
2. Inside the shared bootstrap block situated immediately after the `if/else` construct.

Because the shared bootstrap invocation at the end of `_bootstrap()` already triggers background POPULARITY prefetching for both normal GPS and landmark bootstrap paths, the call inside the landmark branch was redundant and caused duplicate network/caching requests.

### Minimal Corrective Action Applied:
- **Removed ONLY** the duplicate `_prefetchPopularityRound(...)` call inside the landmark branch of `_bootstrap()`.
- **Retained** the common `_prefetchPopularityRound(...)` call following the `if/else` construct.
- **Retained** the search-location `_prefetchPopularityRound(...)` call in `_selectSearchResult()` untouched.
- **No changes** made to `test/realtime_detect_place_test.dart` (the existing 23 tests remain valid and passing).
- **No changes** made to `userPreference_service.dart`, `mainpage.dart`, `placeModel.dart`, `category_mapper.dart`, `nearbyPlace_service.dart`, `placesAPI_service.dart`, or Geoapify logic.
- **No commits or pushes** made.

---

## 2. Source-Reviewed Invocation Sites

Running:
```powershell
rg -n "_prefetchPopularityRound\(" lib/modules/place/detectPlacePage.dart
```

Confirmed output (also captured in [evidence_v2_2/06_rg_prefetch_sites.txt](file:///d:/gotrip/evidence_v2_2/06_rg_prefetch_sites.txt)):
```text
405:  Future<void> _prefetchPopularityRound(
1336:    unawaited(_prefetchPopularityRound(
1493:      unawaited(_prefetchPopularityRound(
```

The codebase now contains exactly:
1. **Line 405:** One method declaration (`Future<void> _prefetchPopularityRound(...)`).
2. **Line 1336:** One shared GPS/landmark bootstrap invocation at the completion of `_bootstrap()`.
3. **Line 1493:** One search-location invocation inside `_selectSearchResult(...)`.

---

## 3. Strict Boundary & Protected Files Verification

The four protected files remain 100% byte-for-byte identical to their baseline:

| File Path | Expected SHA256 | Current SHA256 | Status |
|---|---|---|---|
| `lib/services/userPreference_service.dart` | `C71E8F1B94B4C8E18CA0E19AFD9522540460A62038A41AE2903B4E53BFBA46B3` | `C71E8F1B94B4C8E18CA0E19AFD9522540460A62038A41AE2903B4E53BFBA46B3` | MATCH |
| `lib/modules/main/mainpage.dart` | `5C3458DFC56654B9E6CB77F5971A5B7AC7FD13DDE2664AA9ECE6E61C2178BA57` | `5C3458DFC56654B9E6CB77F5971A5B7AC7FD13DDE2664AA9ECE6E61C2178BA57` | MATCH |
| `lib/models/placeModel.dart` | `A3CA1720A2F3A66578E84BCD2AB17D91C51229A25C14E8D7BF98B2ABB58E8076` | `A3CA1720A2F3A66578E84BCD2AB17D91C51229A25C14E8D7BF98B2ABB58E8076` | MATCH |
| `lib/services/category_mapper.dart` | `EC6795643EF26ABA00EF699F7E1B333D0C6E7B515A801A66E04E8CD2DF4EC44A` | `EC6795643EF26ABA00EF699F7E1B333D0C6E7B515A801A66E04E8CD2DF4EC44A` | MATCH |

---

## 4. Verification Truth & Raw Command Output Summary

### 4.1. Dart Format
- **Command:** `dart format lib/modules/place/detectPlacePage.dart`
- **Result:** Formatted 1 file (0 changed) in 0.03 seconds.
- **Evidence:** [evidence_v2_2/01_dart_format.txt](file:///d:/gotrip/evidence_v2_2/01_dart_format.txt)

### 4.2. Flutter Analyze
- **Command:** `flutter analyze lib/modules/place/detectPlacePage.dart lib/services/nearbyPlace_service.dart lib/services/placesAPI_service.dart test/realtime_detect_place_test.dart`
- **Result:** `0 errors, 4 warnings` (and 124 infos).
- **Warnings breakdown (all pre-existing in baseline `detectPlacePage.dart`):**
  - Line 362: `warning - The value of the field '_placeScores' isn't used - unused_field`
  - Line 2028: `warning - The declaration '_updateRouteTimesForTravelMode' isn't referenced - unused_element`
  - Line 2126: `warning - The declaration '_showErrorDialog' isn't referenced - unused_element`
  - Line 2141: `warning - The declaration '_showLocationDisabledDialog' isn't referenced - unused_element`
- **Evidence:** [evidence_v2_2/02_flutter_analyze.txt](file:///d:/gotrip/evidence_v2_2/02_flutter_analyze.txt)

### 4.3. Realtime Detect Place Mode Test Suite
- **Command:** `flutter test test/realtime_detect_place_test.dart`
- **Result:** **PASS** (23 passed, 0 failed in 00:00).
- **Evidence:** [evidence_v2_2/03_flutter_test_realtime.txt](file:///d:/gotrip/evidence_v2_2/03_flutter_test_realtime.txt)

### 4.4. Full Flutter Test Suite
- **Command:** `flutter test`
- **Result:** **FAIL** (302 passed, 1 failed in 00:14).
- **Failing test:** `test/journal_photo_loading_test.dart` line 302 (`Expected: false, Actual: <true>` on programmatic TOC jump).
- **Note:** This failure is pre-existing and completely unrelated to `RealTimeDetectPage` or `NearbyPlacesService`.
- **Evidence:** [evidence_v2_2/04_flutter_test_all.txt](file:///d:/gotrip/evidence_v2_2/04_flutter_test_all.txt)

### 4.5. Git Diff Check
- **Command:** `git diff --check -- lib/modules/place/detectPlacePage.dart test/realtime_detect_place_test.dart`
- **Result:** Exit code 0, no trailing whitespace or merge conflict markers detected.
- **Evidence:** [evidence_v2_2/05_git_diff_check.txt](file:///d:/gotrip/evidence_v2_2/05_git_diff_check.txt)

---

## 5. Honest 5-Tier Coverage Classification

To prevent overclaiming, verification coverage is strictly partitioned into 5 tiers:

### Tier 1: Full Production Widget Tests
- **Count:** 0.
- **Reason:** Pumping the full `RealTimeDetectPage` widget in a headless unit test fails on `GoogleMap` native platform view controllers. Full widget lifecycle tests are not practical in headless unit tests.

### Tier 2: Production Component-Widget Tests
- **Count:** 1 test.
- **Coverage:** Test 11 pumps `RealTimeDetectPage.buildRankLoadingIndicator()` directly to verify the exact loading indicator widget used by `_buildPlaceListSheet`.

### Tier 3: Production Helper & Service Tests
- **Count:** 20 tests.
- **Coverage:**
  - `RealTimeDetectPage.getCandidatesForTab` (Tests 2, 8, 12, 14, 15).
  - `RealTimeDetectPage.combineForYouPool` (Tests 2, 4, 14, 22).
  - `RealTimeDetectPage.getAvailableSubCategoriesForMode` (Test 23 regression test for GPS, search, landmark origin pool isolation).
  - `NearbyPlacesService` caching, isolated keys (`:DISTANCE:` vs `:POPULARITY:`), LRU eviction, and HTTP request payload validation (Tests 5, 6, 7, 9, 10, 16, 17, 18, 19, 20, 21).

### Tier 4: Source-Reviewed Structural Analysis
- **Count:** 2 tests / structural reviews.
  - Test 1: Verifies production constant `RealTimeDetectPage.defaultSortMode == SortMode.recommended` which initializes state.
  - Test 13: Verifies generation counter concurrency guard (`if (!mounted || generation != _detectGeneration) return;`) by static code audit.
  - V2.2 Invocation Audit: Confirmed via `rg -n "_prefetchPopularityRound\("` that exactly 1 shared bootstrap call and 1 search-location call exist.

### Tier 5: Real-Phone-Only Verification (Deferred to Device Testing)
- **Automatic page-level background invocation:** As stated honestly, headless tests cannot pump the entire Google Map page lifecycle; automatic background prefetching invocation upon page mount is verified by static source review and deferred to real-phone verification.
- **Map marker bitmap generation and rendering:** Headless test environments lack native bitmap descriptors.
- **Scroll offset and filter preservation:** Validated via seam helpers in unit tests; end-to-end scroll gesture persistence requires physical touch input on a device.

---

## 6. Deliverable Artifacts and Manifest

- Report: `gotrip_detect_place_modes_restore_v2_2_report.md`
- ZIP Bundle: `gotrip_detect_place_modes_restore_v2_2_output.zip`
- Checksum file: `SHA256SUMS_v2_2.txt`
- Raw Command Evidence Folder: `evidence_v2_2/`
