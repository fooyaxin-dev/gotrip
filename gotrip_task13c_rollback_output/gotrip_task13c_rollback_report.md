# TASK 13C REPORT — SAFE ROLLBACK TO STABLE PRE-TASK-13 ITINERARY CORE

## 1. Executive Summary & Rollback Scope

In accordance with Task 13C directives, the experimental Task 13 multi-day optimizer additions (Task 13B, 13B1, and 13B2R) have been completely removed and the codebase has been safely restored to the proven, stable pre-Task-13 generation pipeline from Task 11G2.

### Exact Actions Executed
1. **Restored `lib/services/itinerary_service.dart` Byte-for-Byte**:
   - Source: `gotrip_task11g2_output.zip`.
   - Verified SHA-256: `58055DDB22FE5A1B8C94F85A95B439B5C86D3AB26DA48D4DC4654B6891A1D29C` (exact match).
2. **Restored `lib/modules/itinerary/itineraryGeneratePage.dart`**:
   - Restored from Task 11G2 baseline (`82C130A24EC5E1F13B1CAE65E22B13DA09861CF50989D445F143427E9BCE46CA`).
   - Applied only the approved UI adjustment: places-per-day minimum `2` → `1`, singular suffix `place` when value is 1, otherwise `places`.
   - Formatted with `dart format` (Ending SHA-256: `ABBE4AC3E73A994F9F40AC0C1C5E4CCE14CC4ABA601F3909B02C9DDC53166BE9`).
3. **Restored `lib/services/nearbyPlace_service.dart`**:
   - Restored to exact Git baseline (`HEAD:lib/services/nearbyPlace_service.dart`).
   - Verified SHA-256: `347E0848737F55157BA84E1B59EB9FC17BDC29EA1AF0AA72EEBCBAA2EE083D1E`.
4. **Deleted Task 13-Only Files**:
   - `lib/services/multi_day_itinerary_optimizer.dart` (Deleted)
   - `lib/services/route_matrix_snapshot.dart` (Deleted)
   - `test/itinerary_multi_day_global_test.dart` (Deleted)
   - `test/itinerary_preference_retrieval_test.dart` (Deleted)
5. **Preserved Intact**:
   - Protected Task 12B persistence: `lib/models/itineraryModel.dart`, `lib/modules/place/routeOptimizerPage.dart`, `lib/modules/itinerary/itineraryDetail.dart`.
   - All unrelated modules (Landmark, Favourite, Navigation, Dashboard, Profile, Journal, Auth, Firestore rules).

---

## 2. Verification Hashes

### Starting Baseline Hashes (Task 13B2R State)
| File | Starting SHA-256 | Status |
| :--- | :--- | :--- |
| `lib/services/itinerary_service.dart` | `F5D00428678ADD76609370DE7B6F8B8CE42AFB4CABA280BFB86BE3A0561CE5F7` | Verified |
| `lib/services/multi_day_itinerary_optimizer.dart` | `E4C300A9F7165DCE56C64E8C3523658C62F89359177E73E9852B6E5C1066ABC6` | Verified (Deleted) |
| `lib/services/route_matrix_snapshot.dart` | `4F705C49B33F1C70BA4EE82663244BD05DC3664E581AB2D0D5EAE525EC9E59EE` | Verified (Deleted) |

### Protected Task 12B Hashes (Untouched & Invariant)
| File | Required SHA-256 | Current SHA-256 | Status |
| :--- | :--- | :--- | :--- |
| `lib/models/itineraryModel.dart` | `6C6B5BD8E4CD6D6921B3FC4AFCCF89DE7ACFC5F40C7E7D90C18C9477FCC1423A` | `6C6B5BD8E4CD6D6921B3FC4AFCCF89DE7ACFC5F40C7E7D90C18C9477FCC1423A` | **MATCH** |
| `lib/modules/place/routeOptimizerPage.dart` | `44D61039C2E289490DA3B98B53A7C2F7B016FAECEFEC3CE12C313CAF4B6E7BA5` | `44D61039C2E289490DA3B98B53A7C2F7B016FAECEFEC3CE12C313CAF4B6E7BA5` | **MATCH** |
| `lib/modules/itinerary/itineraryDetail.dart` | `873617D5271C901DB7CD0F4EFE2D527FB80A145F14277BD046439C9BED0D2127` | `873617D5271C901DB7CD0F4EFE2D527FB80A145F14277BD046439C9BED0D2127` | **MATCH** |

### Restored & Modified Files Hashes
| File | Final SHA-256 | Description |
| :--- | :--- | :--- |
| `lib/services/itinerary_service.dart` | `58055DDB22FE5A1B8C94F85A95B439B5C86D3AB26DA48D4DC4654B6891A1D29C` | Byte-for-byte Task 11G2 restore |
| `lib/modules/itinerary/itineraryGeneratePage.dart` | `ABBE4AC3E73A994F9F40AC0C1C5E4CCE14CC4ABA601F3909B02C9DDC53166BE9` | Task 11G2 + approved 1 place/day UI adjustment |
| `lib/services/nearbyPlace_service.dart` | `347E0848737F55157BA84E1B59EB9FC17BDC29EA1AF0AA72EEBCBAA2EE083D1E` | Restored Git baseline |
| `test/itinerary_rollback_regression_test.dart` | `5294532F425A96E94EBA1135F9A72B6A12C7AAD0998949E609A2AF1C580E255C` | New comprehensive regression suite |

---

## 3. Stable Behavior Restored

1. **Demand Formulation**:
   - `requestedTotal = totalDays * placesPerDay`
   - `minRestaurantsPerDay = _requiredRestaurantsPerDay(placesPerDay)` (1 for $\le 2$, 2 for $\le 4$, 3 for $\ge 5$).
   - `targetAttractionsPerDay = onlyFoodRequested ? 0 : placesPerDay - minRestaurantsPerDay`.
2. **Deterministic Candidate Balancing**:
   - Single broad category retrieval with configured travel mode radius (`walk`: 2000m, `motor`: 8000m, `drive`: 12000m).
   - Conditional category deepening for specific shortfalls.
   - Selected candidate pool and preserved separate leftover pool for More Places / swapping.
3. **Multi-Day Distribution**:
   - Generates itineraries for 1 to 7 days and 1 to 6 places per day.
   - Distinct Place IDs across days (no intra-trip duplicates).
   - Zero Route Matrix API calls during candidate generation.
4. **Task 12B Compatibility**:
   - Preserves `ItineraryModel.leftoverPlaces` embedded compact snapshots across saving and reopening.

---

## 4. Test Verification Results

### Regression Test Suite (`test/itinerary_rollback_regression_test.dart`)
- **Combination Matrix (1x1, 1x2..6, 2x4, 3x4, 3x5, 4x2, 5x3, 6x1, 7x6)**:
  - Exact total stops assertions verified (`actualTotal == requestedTotal`).
  - Strict day place count equality verified (`day.places.length == placesPerDay`).
  - Zero duplicate Place IDs across all days.
  - Leftover pool verified non-empty.
- **Travel Mode Radii & String Conversion**:
  - `walk` (2000m), `motor` (8000m), `drive` (12000m), `both` (12000m).
- **Multi-Region Geographies**:
  - George Town, Pangkor Island, Kuala Lumpur, Kuching, Kota Kinabalu verified.
- **Preference Modes**:
  - Food-only requests schedule exclusively food places without forced dummy attractions.
- **Task 12B Leftover Serialization & Reopening**:
  - `ItineraryModel.toMap()` and `ItineraryModel.fromMap()` preserve `leftoverPlaces` snapshot list intact.

### Full Workspace Test Suite
```
flutter test
00:13 +139: All tests passed!
```
All 139 tests across all test suites in the workspace passed with **100% success rate**.

---

## 5. Limitations & Future Roadmap

1. **Opening Hours Awareness**: The restored Task 11G2 pipeline does not check opening hours during generation. Any future opening hours integration should be added as a lightweight validation without introducing complex beam search or network-heavy matrix loops.
2. **Single-Day Heuristic Loop**: Multi-day distribution operates via the stable daily loop. Isolated spatial clustering improvements can be explored incrementally with proven regression benchmarks.

---

## 6. Deliverable ZIP Archive Contents

`gotrip_task13c_rollback_output.zip`:
- `lib/services/itinerary_service.dart`
- `lib/modules/itinerary/itineraryGeneratePage.dart`
- `lib/services/nearbyPlace_service.dart`
- `test/itinerary_rollback_regression_test.dart`
- `gotrip_task13c_rollback_report.md`
