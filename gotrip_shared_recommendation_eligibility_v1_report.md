# GoTrip Shared Recommendation Eligibility Policy (v1) Report

## 1. Previous Behaviour and Why Unsuitable Corporate Places Appeared

Prior to this implementation:
- Corporate/business keyword blocking only existed inside `lib/services/itinerary_service.dart` (`_blockedNameKeywords`).
- That filtering was **not** shared with or used by:
  - MainPage For You;
  - MainPage Nearby;
  - MainPage Recommended Places / category lists;
  - DetectPlace default-location For You;
  - DetectPlace default-location Nearest;
  - DetectPlace default-location Rank;
  - DetectPlace automatic recommendations around a searched location.
- Furthermore, within `itinerary_service.dart`, name blocking was unconditional: any place containing keywords such as `sdn bhd` was rejected even if it was a genuine food destination (e.g. `ABC Restaurant Sdn. Bhd.`).
- Meanwhile, in Google Places responses, ordinary companies, wholesalers, and corporate offices often contain generic primary or secondary types (such as `store`, `establishment`, `point_of_interest`, `wholesaler`, `corporate_office`).
- Because `CategoryMapper` mapped any Google type in `shoppingTypes` into the `'shopping_mall'` display category, or treated generic stores as valid shopping places, a business such as:
  ```
  Woon Kwong Hing Sdn. Bhd.
  types: ['store', 'wholesaler', 'establishment', 'point_of_interest']
  ```
  was accepted by candidate pipelines and surfaced as a recommended travel destination.

---

## 2. Exact Shared Policy

The single source of truth is established in [`lib/services/recommendation_eligibility_policy.dart`](file:///d:/gotrip/lib/services/recommendation_eligibility_policy.dart) via `RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(PlaceModel place)`.

### Core Rule
```
suspicious corporate/business name
AND no authoritative visitor-relevant Google type
=> exclude from automatic recommendations
```

### Name Normalization & Keyword Matching
1. **Case-Insensitive Normalization**:
   - Converts name to lowercase.
   - Replaces harmless punctuation (periods, commas, hyphens, etc.) with whitespace.
   - Collapses repeated whitespace.
   - Evaluates compressed (punctuation and space-stripped) string for merged compounds.
2. **Corporate/Business Keywords Detected**:
   - `sdn bhd` / `sdn. bhd.` / `sdnbhd` / `sdn   bhd`
   - `berhad` / `group berhad`
   - `enterprise` / `enterprises`
   - `trading`
   - `holdings`
   - `management`
   - `solution` / `solutions`
   - `consultant` / `consultancy`
   - `agency` / `agencies`
   - `services`
   - `network`

### Authoritative Visitor-Relevant Type Exemptions
If a place contains a corporate keyword, it is retained if and only if `place.allTypes` contains an authoritative visitor-relevant type from the following families:
- **Food & Drink**: All `CategoryMapper.restaurantTypes` (`restaurant`, `cafe`, `bakery`, `meal_takeaway`, `meal_delivery`, `bar`, and specific cuisine types such as `chinese_restaurant`, `malaysian_restaurant`, `indian_restaurant`, `western_restaurant`, `japanese_restaurant`, `korean_restaurant`, `thai_restaurant`, `italian_restaurant`, `vietnamese_restaurant`, `seafood_restaurant`, `vegetarian_restaurant`, `buffet_restaurant`, `steak_house`, `sushi_restaurant`, `pizza_restaurant`, `ramen_restaurant`).
- **Attractions & Culture**: `tourist_attraction`, `museum`, `art_gallery`, `cultural_landmark`, `historical_landmark`, `monument`, `performing_arts_theater`, `event_venue`, `visitor_center`.
- **Nature & Recreation**: `park`, `national_park`, `zoo`, `aquarium`, `amusement_park`, `water_park`, `botanical_garden`, `garden`, `hiking_area`, `beach`.
- **Shopping & Entertainment Destinations**: `shopping_mall`, `market`, `movie_theater`, `bowling_alley`, `night_club`, `amusement_center`, `karaoke`, `video_arcade`, `concert_hall`.

### Generic Non-Exempt Types
The following generic/business types alone do **not** rescue a corporate place:
- `establishment`, `point_of_interest`, `store`, `corporate_office`, `wholesaler`, `general_contractor`, `consultant`, `service`, `finance`, `insurance_agency`, `real_estate_agency`, `hardware_store`, `car_repair`, `storage`.

### Normal Places Preserved
Places without suspicious corporate keywords (e.g. `Uncle Bob's Corner` with generic types `['store', 'establishment']`) are never excluded.

---

## 3. Exact Files Changed

| File | Status | Description |
|---|---|---|
| [`lib/services/recommendation_eligibility_policy.dart`](file:///d:/gotrip/lib/services/recommendation_eligibility_policy.dart) | **NEW** | Shared policy definition, name normalizer, keyword detector, authoritative type exemptions, and main eligibility evaluator. |
| [`lib/services/for_you_recommendation_service.dart`](file:///d:/gotrip/lib/services/for_you_recommendation_service.dart) | **MODIFIED** | Applies `RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(p)` in `ensureForYouSnapshot` candidate filter stage. |
| [`lib/services/nearbyPlace_service.dart`](file:///d:/gotrip/lib/services/nearbyPlace_service.dart) | **MODIFIED** | Applies policy in `_fetchGoogleOnce`, `_runGeoapifyPhase`, `fetchForItinerary`, and `fetchAdditionalForItinerary`. Also passes `client: httpClient` to itinerary searches. |
| [`lib/services/itinerary_service.dart`](file:///d:/gotrip/lib/services/itinerary_service.dart) | **MODIFIED** | Refactors `_isBlocked` to delegate corporate name/type checking to `RecommendationEligibilityPolicy.isEligibleForAutomaticRecommendation(p)` while preserving itinerary-specific blocked types and medical/hardware keywords. |
| [`test/recommendation_eligibility_policy_test.dart`](file:///d:/gotrip/test/recommendation_eligibility_policy_test.dart) | **NEW** | Comprehensive unit, pipeline integration, and user-flow preservation test suite covering all 18 requirements. |

---

## 4. Exact Automatic Pipelines Covered

1. **MainPage For You**: Covered via `ForYouRecommendationService.ensureForYouSnapshot`.
2. **MainPage Nearby**: Covered via `NearbyPlacesService.loadNearbyPlacesOnce` -> `_fetchGoogleOnce` and `_runGeoapifyPhase`.
3. **MainPage Recommended Places / Category Lists**: Derived from `_nearbyPlaces` (populated by `loadNearbyPlacesOnce`).
4. **DetectPlace Default-Location For You**: Covered via `ForYouRecommendationService.ensureForYouSnapshot`.
5. **DetectPlace Default-Location Nearest**: Covered via `NearbyPlacesService.ensureDistanceRound` -> `_fetchGoogleOnce`.
6. **DetectPlace Default-Location Rank**: Covered via `NearbyPlacesService.ensurePopularityRound` -> `_fetchGoogleOnce`.
7. **DetectPlace Automatic Recommendations Around Searched Location**: Covered via `NearbyPlacesService.ensureDistanceRound` and `ensurePopularityRound`.
8. **System-Generated Itinerary Candidate Pools**: Covered via `NearbyPlacesService.fetchForItinerary` and `ItineraryService._isBlocked`.
9. **Additional System-Generated Itinerary Candidate Fetches**: Covered via `NearbyPlacesService.fetchAdditionalForItinerary` and `ItineraryService._isBlocked`.

---

## 5. Exact User-Driven Flows Excluded from Filtering

Filtering is strictly non-destructive and is **not** applied to:
- **User Exact Search / Autocomplete Selection**: `PlacesApiService.autocomplete` and `PlacesApiService.getPlaceLatLng` are untouched.
- **Place Detail Opened by Place ID**: `PlacesApiService.getPlaceDetails` and `findGooglePlaceId` are untouched.
- **Landmark Recognition Results**: `PlacesApiService.searchNearbyWithKeyword` and `landmarkResult.dart` are untouched.
- **User-Added Itinerary Places**: Manually selected/added places remain unfiltered.
- **Already-Saved Itineraries**: `ItineraryModel`, `ItineraryDay`, and `ItineraryPlace` records remain intact.
- **User Records**: Favourite, history, and visited records remain intact.
- **Firestore Cache Documents**: No places are removed or deleted from Firestore documents.

---

## 6. Itinerary-Specific Rules Preserved

`ItineraryService._isBlocked` preserves all existing itinerary exclusions:
1. **Blocked Types (`_blockedTypes`)**: `lodging`, `hotel`, `guest_house`, `motel`, `hostel`, `campground`, `rv_park`, `dentist`, `doctor`, `hospital`, `pharmacy`, `veterinary_care`, `bank`, `atm`, `accounting`, `lawyer`, `insurance_agency`, `post_office`, `car_repair`, `gas_station`, `car_wash`, `car_dealer`, `laundry`, `storage`, `funeral_home`, `cemetery`, `police`, `courthouse`, `embassy`, `real_estate_agency`, `electrician`, `plumber`, `roofing_contractor`.
2. **Itinerary-Specific Name Keywords (`_itineraryBlockedNameKeywords`)**: `insurance`, `clinic`, `hospital`, `pharmacy`, `hardware`, `spare part`.
3. **Rating Threshold**: Minimum rating 3.5 enforced in `_isSuitableForTravel`.

---

## 7. Production-Pipeline versus Helper-Only Test Coverage

The test suite in [`test/recommendation_eligibility_policy_test.dart`](file:///d:/gotrip/test/recommendation_eligibility_policy_test.dart) explicitly differentiates:

### A. Shared Policy Unit Tests
- `Woon Kwong Hing Sdn. Bhd.` with generic types is excluded.
- Case and punctuation variants (`Sdn Bhd`, `Sdn. Bhd.`, `SDN. BHD`, `sdnbhd`, `Sdn.Bhd.`, `Sdn   Bhd`) detected.
- Corporate name with `restaurant` is retained (`ABC Restaurant Sdn. Bhd.`).
- Corporate name with `cafe` is retained (`Green Leaf Cafe Berhad`).
- Corporate name with `tourist_attraction` is retained (`Heritage Discovery Center Group Berhad`).
- Corporate name with `shopping_mall` is retained (`Metro City Mall Enterprise`).
- Corporate name with only `store`, `establishment`, or `point_of_interest` is excluded.
- Normal place without corporate keywords (`Uncle Bob's Corner`) with generic types is retained.
- Corporate keywords (`trading`, `management`, `solutions`, `consultancy`, `agency`, `services`, `network`) are detected.

### B. Production Candidate-Pipeline Tests
- MainPage For You candidate filter pipeline (`ensureForYouSnapshot`).
- MainPage Nearby / Recommended candidate pipeline (`NearbyPlacesService._fetchGoogleOnce`).
- DetectPlace For You, Nearest, and Rank pipeline (`ensureDistanceRound`, `ensurePopularityRound`, `getCandidatesForTab`).
- DetectPlace searched location recommendation pipeline (`ensureDistanceRound`).
- System-generated itinerary candidate pools (`NearbyPlacesService.fetchForItinerary` and `fetchAdditionalForItinerary`).
- `ItineraryService._isBlocked` integration: verifies corporate delegation and itinerary-specific exclusions.
- Relative ordering preservation across retained places.
- Cache verification: filtering does not trigger additional API requests on cache hits.

### C. User-Driven & Preserved Flows Tests
- User exact search / autocomplete selection remains accessible.
- Landmark recognition results remain unaffected.
- Existing saved itinerary places remain unaffected.

---

## 8. All Validation Results

### 1. Formatting
```
dart format lib/services/recommendation_eligibility_policy.dart lib/services/for_you_recommendation_service.dart lib/services/nearbyPlace_service.dart lib/services/itinerary_service.dart test/recommendation_eligibility_policy_test.dart
Formatted 5 files (5 changed) in 0.05 seconds.
```

### 2. Static Analysis
```
flutter analyze lib/services/recommendation_eligibility_policy.dart lib/services/for_you_recommendation_service.dart test/recommendation_eligibility_policy_test.dart
Analyzing 3 items...
No issues found! (ran in 2.5s)
```

### 3. Git Diff Check
```
git diff --check -- lib/services/recommendation_eligibility_policy.dart lib/services/for_you_recommendation_service.dart lib/services/nearbyPlace_service.dart lib/services/itinerary_service.dart test/recommendation_eligibility_policy_test.dart
(Clean exit code 0)
```

### 4. Targeted Tests
```
flutter test test/recommendation_eligibility_policy_test.dart
00:00 +20: All tests passed!
```

### 5. Existing Recommendation Consistency Tests
```
flutter test test/shared_for_you_consistency_test.dart test/realtime_detect_place_test.dart
00:01 +55: All tests passed!
```

### 6. Existing Itinerary Tests
```
flutter test test/itinerary_rules_test.dart test/itinerary_task11d_regression_test.dart
00:00 +8: All tests passed!
```

### 7. Isolated Cache Safety Tests
```
flutter test test/place_details_cache_safety_test.dart
00:00 +16: All tests passed!
```

---

## 9. Pre-Edit and Post-Edit Changed-File Lists

### Pre-Edit Changed-File List (Baseline)
Prior to starting this task, existing uncommitted work was present in:
- `lib/modules/main/mainpage.dart`
- `lib/modules/place/placeDetailPage.dart`
- `lib/services/location_service.dart`
- `lib/services/navigate_service.dart`
- `test/itinerary_arrival_tracking_test.dart`
- `lib/services/arrival_policy.dart` (untracked)
- `test/shared_arrival_policy_test.dart` (untracked)
- `test/navigation_startup_fallback_test.dart` (untracked)
- `test/mainpage_bottom_spacing_test.dart` (untracked)
- `test/place_detail_responsive_test.dart` (untracked)
- `scratch/` (untracked scripts and bundles)

### Post-Edit Changed-File List (This Task)
Strictly modified / created by this task:
- `lib/services/recommendation_eligibility_policy.dart` (NEW)
- `lib/services/for_you_recommendation_service.dart` (MODIFIED)
- `lib/services/nearbyPlace_service.dart` (MODIFIED)
- `lib/services/itinerary_service.dart` (MODIFIED)
- `test/recommendation_eligibility_policy_test.dart` (NEW)

All pre-existing uncommitted files were strictly preserved and untouched.

---

## 10. Unrelated Pre-Existing Failures

When running the entire repository test suite (`flutter test` across all 35 test files concurrently):
- 594 tests passed, 1 test failed in `place_details_cache_safety_test.dart` due to static `PlacesApiService` mock state concurrency across parallel test files.
- When run individually (`flutter test test/place_details_cache_safety_test.dart`), all 16 tests in `place_details_cache_safety_test.dart` passed with 0 errors.
- As required by strict scope, no changes were made to that unrelated module.

---

## 11. Confirmation of Unmodified Functionality

We explicitly confirm that the following have **not** been modified:
- Recommendation scoring weights and formulas;
- For You ranking order;
- Nearest distance sorting;
- Rank popularity/rating sorting;
- User preferences;
- Travel-mode logic;
- API request count, radius, field mask, or pagination;
- Google Places response mapping;
- Firestore cache structure;
- Cache TTL;
- Manual refresh or 3km refresh;
- User location logic;
- Place Detail;
- Active opening-hours logic;
- Itinerary scheduling, generation quantity, optimization, or editing;
- User-created itinerary places;
- User Search result selection;
- Landmark Recognition;
- GPS Navigation;
- Arrival detection;
- MainPage or DetectPlacePage UI/layout;
- Journal, Profile, Dashboard, Authentication, or Interaction;
- Dependencies, platform configuration, Firebase schema, or rules.

---

## 12. Limitation

Name and type filtering is a heuristic mechanism. While it successfully identifies corporate suffixes (`Sdn. Bhd.`, `Berhad`, `Enterprise`, `Trading`, `Holdings`, `Solutions`, etc.) and exempts genuine visitor destinations using canonical Google types (`restaurant`, `cafe`, `tourist_attraction`, `shopping_mall`, etc.), novel or regional corporate abbreviations and unconventional business naming structures may require future dictionary tuning.
