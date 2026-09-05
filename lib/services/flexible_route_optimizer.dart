// services/flexible_route_optimizer.dart
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/itineraryModel.dart';
import '../models/placeModel.dart';
import 'route_service.dart';
import 'opening_hours_evaluator.dart';

enum PlaceRole {
  fullMeal,
  nonMeal,
  excluded,
}

class PlaceRoleClassifier {
  static const Set<String> fullMealTypes = {
    'restaurant',
    'fast_food_restaurant',
    'food_court',
    'chinese_restaurant',
    'malaysian_restaurant',
    'malay_restaurant',
    'indian_restaurant',
    'western_restaurant',
    'american_restaurant',
    'japanese_restaurant',
    'korean_restaurant',
    'thai_restaurant',
    'italian_restaurant',
    'vietnamese_restaurant',
    'seafood_restaurant',
    'vegetarian_restaurant',
    'buffet_restaurant',
    'steak_house',
    'sushi_restaurant',
    'pizza_restaurant',
    'ramen_restaurant',
  };

  static const Set<String> majorNonMealVenueTypes = {
    'amusement_park',
    'tourist_attraction',
    'museum',
    'shopping_mall',
    'movie_theater',
    'cinema',
    'bowling_alley',
    'video_arcade',
    'amusement_center',
    'zoo',
    'aquarium',
    'stadium',
    'park',
    'historical_landmark',
    'monument',
    'art_gallery',
    'national_park',
    'botanical_garden',
    'cafe',
    'coffee_shop',
    'bakery',
    'dessert_shop',
    'ice_cream_shop',
  };

  static const Set<String> excludedVenueTypes = {
    'meal_delivery',
    'bar',
    'night_club',
  };

  static PlaceRole classify({
    String? primaryType,
    List<String> allTypes = const [],
  }) {
    final types = {
      if (primaryType != null && primaryType.isNotEmpty) primaryType,
      ...allTypes,
    };

    if (types.any(majorNonMealVenueTypes.contains)) {
      return PlaceRole.nonMeal;
    }

    if (types.any(fullMealTypes.contains)) {
      return PlaceRole.fullMeal;
    }

    if (types.any(excludedVenueTypes.contains)) {
      return PlaceRole.excluded;
    }

    return PlaceRole.nonMeal;
  }
}

class EvaluatedVisit {
  final ItineraryPlace place;
  final PlaceRole role;
  final int arrivalMinutes;
  final int startMinutes;
  final int endMinutes;
  final OpeningStatus openingStatus;

  const EvaluatedVisit({
    required this.place,
    required this.role,
    required this.arrivalMinutes,
    required this.startMinutes,
    required this.endMinutes,
    required this.openingStatus,
  });
}

class EvaluatedLeg {
  final String fromPlaceId;
  final String fromName;
  final String toPlaceId;
  final String toName;
  final double distanceMeters;
  final int durationSeconds;
  final String source;

  const EvaluatedLeg({
    required this.fromPlaceId,
    required this.fromName,
    required this.toPlaceId,
    required this.toName,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.source,
  });
}

class PermutationOptimizationResult {
  final bool isFeasible;
  final List<ItineraryPlace> places;
  final List<int> originalIndices;
  final double totalRoadDistanceMeters;
  final int totalRoadDurationSeconds;
  final int waitingMinutes;
  final List<String> requiredMeals;
  final List<EvaluatedVisit> visits;
  final List<EvaluatedLeg> legs;
  final int permutationsEvaluated;
  final int feasiblePermutations;
  final int rejectedOpeningHours;
  final int rejectedMealWindow;
  final int rejectedDayEnd;
  final int rejectedInvalidRoute;

  const PermutationOptimizationResult({
    required this.isFeasible,
    required this.places,
    required this.originalIndices,
    required this.totalRoadDistanceMeters,
    required this.totalRoadDurationSeconds,
    required this.waitingMinutes,
    required this.requiredMeals,
    required this.visits,
    required this.legs,
    required this.permutationsEvaluated,
    required this.feasiblePermutations,
    required this.rejectedOpeningHours,
    required this.rejectedMealWindow,
    required this.rejectedDayEnd,
    required this.rejectedInvalidRoute,
  });
}

class FlexibleRouteOptimizer {
  static const int lunchStartMinutes = 11 * 60 + 30; // 11:30 (690)
  static const int lunchEndMinutes = 14 * 60 + 30; // 14:30 (870)
  static const int dinnerStartMinutes = 17 * 60 + 30; // 17:30 (1050)
  static const int dinnerEndMinutes = 20 * 60 + 30; // 20:30 (1230)
  static const int maxDayEndMinutes = 21 * 60 + 30; // 21:30 (1290)

  static int getDefaultDurationMinutes(String? primaryType) {
    return switch (primaryType ?? '') {
      'restaurant' => 75,
      'chinese_restaurant' => 75,
      'japanese_restaurant' => 75,
      'italian_restaurant' => 75,
      'indian_restaurant' => 75,
      'malaysian_restaurant' => 75,
      'seafood_restaurant' => 75,
      'steak_house' => 90,
      'buffet_restaurant' => 90,
      'tourist_attraction' => 120,
      'museum' => 120,
      'amusement_park' => 180,
      'shopping_mall' => 120,
      'movie_theater' || 'cinema' => 120,
      'bowling_alley' => 90,
      'park' => 90,
      'zoo' || 'aquarium' => 150,
      'cafe' || 'coffee_shop' || 'dessert_shop' || 'bakery' => 60,
      _ => 90,
    };
  }

  static String minutesToTimeString(int minutes) {
    final hh = (minutes ~/ 60) % 24;
    final mm = minutes % 60;
    return '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
  }

  static int parseTimeToMinutes(String? timeStr, {int fallback = 9 * 60}) {
    if (timeStr == null || timeStr.isEmpty) return fallback;
    try {
      final parts = timeStr.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    } catch (_) {
      return fallback;
    }
  }

  static List<List<T>> generatePermutations<T>(List<T> list) {
    if (list.length <= 1) return [List<T>.from(list)];
    final result = <List<T>>[];
    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      final remaining = List<T>.from(list)..removeAt(i);
      for (final perm in generatePermutations(remaining)) {
        result.add([item, ...perm]);
      }
    }
    return result;
  }

  /// Optimizes a single day's stops using complete whole-day permutation search.
  static PermutationOptimizationResult optimizeDay({
    required int dayIndex,
    required String? dayDate,
    required List<ItineraryPlace> places,
    required double? originLat,
    required double? originLng,
    required String? originName,
    required TravelMode travelMode,
    required double Function(int fromIndex, int toIndex) getDistanceMeters,
    required int Function(int fromIndex, int toIndex) getDurationSeconds,
    Map<String, List<OpeningHoursPeriod>>? periodsByPlaceId,
    String roadMatrixSource = 'google_routes_api',
  }) {
    final bool hasOrigin = originLat != null &&
        originLng != null &&
        originLat.isFinite &&
        originLng.isFinite;
    final originType = hasOrigin ? 'real_origin' : 'day_start';

    if (hasOrigin) {
      debugPrint(
        '[FLEX_ROUTE][ORIGIN] day=$dayIndex originLat=$originLat originLng=$originLng originName=${originName ?? "Origin"} originSource=shared_trip_origin',
      );
    }

    debugPrint(
      '[FLEX_ROUTE][INPUT] day=$dayIndex originType=$originType places=[${places.map((p) => p.placeId).join(', ')}] travelMode=${travelMode.name}',
    );

    if (places.isEmpty) {
      return const PermutationOptimizationResult(
        isFeasible: true,
        places: [],
        originalIndices: [],
        totalRoadDistanceMeters: 0,
        totalRoadDurationSeconds: 0,
        waitingMinutes: 0,
        requiredMeals: [],
        visits: [],
        legs: [],
        permutationsEvaluated: 0,
        feasiblePermutations: 0,
        rejectedOpeningHours: 0,
        rejectedMealWindow: 0,
        rejectedDayEnd: 0,
        rejectedInvalidRoute: 0,
      );
    }

    final int weekday = dayDate != null && dayDate.isNotEmpty
        ? ((DateTime.tryParse(dayDate)?.weekday ?? 1) % 7)
        : 1;

    // Nominal day starting time
    final int nominalStartMinutes;
    if (places.length == 1) {
      final role = PlaceRoleClassifier.classify(
        primaryType: places.first.primaryType,
        allTypes: places.first.allTypes,
      );
      nominalStartMinutes = role == PlaceRole.fullMeal ? 12 * 60 : 9 * 60;
    } else if (places.length <= 3) {
      nominalStartMinutes = 9 * 60; // 09:00
    } else {
      nominalStartMinutes = 8 * 60; // 08:00
    }

    final placeIndices = List.generate(places.length, (i) => i);
    final allPermutations = generatePermutations(placeIndices);

    int permutationsEvaluated = 0;
    int feasiblePermutations = 0;
    int rejectedOpeningHours = 0;
    int rejectedMealWindow = 0;
    int rejectedDayEnd = 0;
    int rejectedInvalidRoute = 0;

    ({
      List<int> perm,
      double cost,
      double roadDist,
      int roadDurSec,
      int waitMin,
      List<String> meals,
      List<EvaluatedVisit> visits,
      List<EvaluatedLeg> legs,
      bool isFeasible,
    })? bestCandidate;

    for (final perm in allPermutations) {
      permutationsEvaluated++;

      int cursorMinutes = nominalStartMinutes;
      int totalWaitingMinutes = 0;
      double totalDist = 0.0;
      int totalDurSec = 0;
      bool hasLunch = false;
      bool hasDinner = false;
      bool isPermValid = true;

      final evaluatedVisits = <EvaluatedVisit>[];
      final evaluatedLegs = <EvaluatedLeg>[];

      for (int step = 0; step < perm.length; step++) {
        final currentIdx = perm[step];
        final currentPlace = places[currentIdx];
        final role = PlaceRoleClassifier.classify(
          primaryType: currentPlace.primaryType,
          allTypes: currentPlace.allTypes,
        );

        // Calculate travel leg from previous point
        final double legDist;
        final int legDurSec;
        final String fromId;
        final String fromName;

        if (step == 0) {
          if (hasOrigin) {
            fromId = 'ORIGIN';
            fromName = originName ?? 'Origin';
            // Index 0 in matrix represents origin when hasOrigin is true
            legDist = getDistanceMeters(0, currentIdx + 1);
            legDurSec = getDurationSeconds(0, currentIdx + 1);
          } else {
            // Day 2+: Starts directly at the first stop (day_start)
            fromId = currentPlace.placeId;
            fromName = currentPlace.name;
            legDist = 0.0;
            legDurSec = 0;
          }
        } else {
          final prevIdx = perm[step - 1];
          final prevPlace = places[prevIdx];
          fromId = prevPlace.placeId;
          fromName = prevPlace.name;
          final offset = hasOrigin ? 1 : 0;
          legDist = getDistanceMeters(prevIdx + offset, currentIdx + offset);
          legDurSec = getDurationSeconds(prevIdx + offset, currentIdx + offset);
        }

        if (legDist.isInfinite || legDurSec < 0) {
          isPermValid = false;
          rejectedInvalidRoute++;
          break;
        }

        if (step > 0 || hasOrigin) {
          totalDist += legDist;
          totalDurSec += legDurSec;
          evaluatedLegs.add(EvaluatedLeg(
            fromPlaceId: fromId,
            fromName: fromName,
            toPlaceId: currentPlace.placeId,
            toName: currentPlace.name,
            distanceMeters: legDist,
            durationSeconds: legDurSec,
            source: roadMatrixSource,
          ));
        }

        final int travelMinutes = (legDurSec / 60.0).ceil();
        final int arrivalMinutes = cursorMinutes + travelMinutes;
        final int durationMinutes = currentPlace.durationMinutes > 0
            ? currentPlace.durationMinutes
            : getDefaultDurationMinutes(currentPlace.primaryType);

        int visitStart = arrivalMinutes;

        // Meal placement validation
        if (role == PlaceRole.fullMeal) {
          if (arrivalMinutes <= lunchEndMinutes && !hasLunch) {
            visitStart = math.max(arrivalMinutes, lunchStartMinutes);
            if (visitStart > lunchEndMinutes) {
              isPermValid = false;
              rejectedMealWindow++;
              break;
            }
            hasLunch = true;
          } else if (arrivalMinutes <= dinnerEndMinutes) {
            visitStart = math.max(arrivalMinutes, dinnerStartMinutes);
            if (visitStart > dinnerEndMinutes) {
              isPermValid = false;
              rejectedMealWindow++;
              break;
            }
            hasDinner = true;
          } else {
            isPermValid = false;
            rejectedMealWindow++;
            break;
          }
        }

        // Opening hours evaluation
        final periods = periodsByPlaceId?[currentPlace.placeId] ??
            currentPlace.regularOpeningPeriods;
        var status = OpeningHoursEvaluator.evaluateVisit(
          visitWeekday: weekday,
          arrivalMinutes: visitStart,
          durationMinutes: durationMinutes,
          periods: periods,
        );

        if (status == OpeningStatus.closed &&
            periods != null &&
            periods.isNotEmpty) {
          int? nextOpen;
          for (final p in periods) {
            if (p.open.day == weekday) {
              final openMin = p.open.hour * 60 + p.open.minute;
              if (openMin >= visitStart) {
                if (nextOpen == null || openMin < nextOpen) {
                  nextOpen = openMin;
                }
              }
            }
          }
          if (nextOpen != null && nextOpen - visitStart <= 180) {
            final delayedStatus = OpeningHoursEvaluator.evaluateVisit(
              visitWeekday: weekday,
              arrivalMinutes: nextOpen,
              durationMinutes: durationMinutes,
              periods: periods,
            );
            if (delayedStatus == OpeningStatus.open) {
              visitStart = nextOpen;
              status = OpeningStatus.open;
            }
          }
        }

        if (status == OpeningStatus.closed) {
          isPermValid = false;
          rejectedOpeningHours++;
          break;
        }

        final int wait = math.max(0, visitStart - arrivalMinutes);
        totalWaitingMinutes += wait;
        final int visitEnd = visitStart + durationMinutes;

        if (visitEnd > maxDayEndMinutes) {
          isPermValid = false;
          rejectedDayEnd++;
          break;
        }

        evaluatedVisits.add(EvaluatedVisit(
          place: currentPlace,
          role: role,
          arrivalMinutes: arrivalMinutes,
          startMinutes: visitStart,
          endMinutes: visitEnd,
          openingStatus: status,
        ));

        cursorMinutes = visitEnd;
      }

      // Day-level meal requirement check: at least 1 full meal required if input contains a full meal
      final hasAnyFullMeal =
          evaluatedVisits.any((v) => v.role == PlaceRole.fullMeal);
      final inputContainsMeal = places.any((p) =>
          PlaceRoleClassifier.classify(
            primaryType: p.primaryType,
            allTypes: p.allTypes,
          ) ==
          PlaceRole.fullMeal);
      if (isPermValid && inputContainsMeal && !hasAnyFullMeal) {
        isPermValid = false;
        rejectedMealWindow++;
      }

      // If day naturally extends into dinner window and user has 2+ meals in the day, require dinner
      if (isPermValid && cursorMinutes >= dinnerStartMinutes && !hasDinner) {
        final candidateMeals = places.where((p) =>
            PlaceRoleClassifier.classify(
              primaryType: p.primaryType,
              allTypes: p.allTypes,
            ) ==
            PlaceRole.fullMeal);
        if (candidateMeals.length >= 2) {
          isPermValid = false;
          rejectedMealWindow++;
        }
      }

      // Cost Calculation
      final meals = <String>[
        if (hasLunch) 'lunch',
        if (hasDinner) 'dinner',
      ];

      double excessiveGapPenalty = 0.0;
      for (int k = 1; k < evaluatedVisits.length; k++) {
        final gap =
            evaluatedVisits[k].startMinutes - evaluatedVisits[k - 1].endMinutes;
        if (gap > 90) {
          excessiveGapPenalty += (gap - 90) * 1.5;
        }
      }

      final double totalCost = totalDurSec.toDouble() +
          (totalWaitingMinutes * 60.0 * 1.5) +
          (excessiveGapPenalty * 60.0) +
          (isPermValid ? 0.0 : 1e7);

      if (isPermValid) feasiblePermutations++;

      final bool isBetter;
      if (bestCandidate == null) {
        isBetter = true;
      } else if (isPermValid && !bestCandidate.isFeasible) {
        isBetter = true;
      } else if (!isPermValid && bestCandidate.isFeasible) {
        isBetter = false;
      } else if (totalCost < bestCandidate.cost - 0.001) {
        isBetter = true;
      } else if ((totalCost - bestCandidate.cost).abs() <= 0.001) {
        // Tie breaking
        if (totalDurSec < bestCandidate.roadDurSec) {
          isBetter = true;
        } else if (totalWaitingMinutes < bestCandidate.waitMin) {
          isBetter = true;
        } else {
          // Lexical Place ID order
          final currentIds = perm.map((i) => places[i].placeId).join(',');
          final bestIds =
              bestCandidate.perm.map((i) => places[i].placeId).join(',');
          isBetter = currentIds.compareTo(bestIds) < 0;
        }
      } else {
        isBetter = false;
      }

      if (isBetter) {
        bestCandidate = (
          perm: perm,
          cost: totalCost,
          roadDist: totalDist,
          roadDurSec: totalDurSec,
          waitMin: totalWaitingMinutes,
          meals: meals,
          visits: evaluatedVisits,
          legs: evaluatedLegs,
          isFeasible: isPermValid,
        );
      }
    }

    debugPrint(
      '[FLEX_ROUTE][SEARCH] day=$dayIndex permutationsEvaluated=$permutationsEvaluated feasiblePermutations=$feasiblePermutations rejectedOpeningHours=$rejectedOpeningHours rejectedMealWindow=$rejectedMealWindow rejectedDayEnd=$rejectedDayEnd rejectedInvalidRoute=$rejectedInvalidRoute',
    );

    if (feasiblePermutations == 0 ||
        bestCandidate == null ||
        !bestCandidate.isFeasible) {
      debugPrint(
        '[FLEX_ROUTE][INFEASIBLE] day=$dayIndex rejectedOpeningHours=$rejectedOpeningHours rejectedMealWindow=$rejectedMealWindow rejectedDayEnd=$rejectedDayEnd rejectedInvalidRoute=$rejectedInvalidRoute action=replacement_attempt/preserve_previous',
      );
      return PermutationOptimizationResult(
        isFeasible: false,
        places: places,
        originalIndices: placeIndices,
        totalRoadDistanceMeters: 0,
        totalRoadDurationSeconds: 0,
        waitingMinutes: 0,
        requiredMeals: const [],
        visits: const [],
        legs: const [],
        permutationsEvaluated: permutationsEvaluated,
        feasiblePermutations: 0,
        rejectedOpeningHours: rejectedOpeningHours,
        rejectedMealWindow: rejectedMealWindow,
        rejectedDayEnd: rejectedDayEnd,
        rejectedInvalidRoute: rejectedInvalidRoute,
      );
    }

    final selectedPerm = bestCandidate.perm;
    final selectedVisits = bestCandidate.visits;
    final selectedLegs = bestCandidate.legs;
    final selectedRoadDist = bestCandidate.roadDist;
    final selectedRoadDurSec = bestCandidate.roadDurSec;
    final selectedWaitMin = bestCandidate.waitMin;
    final selectedMeals = bestCandidate.meals;

    final orderedPlaces = <ItineraryPlace>[];
    for (int i = 0; i < selectedPerm.length; i++) {
      final origIdx = selectedPerm[i];
      final p = places[origIdx];
      final visit = i < selectedVisits.length ? selectedVisits[i] : null;
      final timeStr = visit != null
          ? minutesToTimeString(visit.startMinutes)
          : (p.suggestedTime.isNotEmpty ? p.suggestedTime : '09:00');
      final duration = visit != null
          ? (visit.endMinutes - visit.startMinutes)
          : p.durationMinutes;

      orderedPlaces.add(p.copyWith(
        suggestedTime: timeStr,
        durationMinutes: duration,
      ));
    }

    debugPrint(
      '[FLEX_ROUTE][SELECTED] day=$dayIndex order=[${orderedPlaces.map((p) => '${p.placeId}:${p.name}').join(', ')}] roadDurationSeconds=$selectedRoadDurSec roadDistanceMeters=${selectedRoadDist.toStringAsFixed(1)} waitingMinutes=$selectedWaitMin requiredMeals=[${selectedMeals.join(', ')}]',
    );

    for (int pos = 0; pos < orderedPlaces.length; pos++) {
      final p = orderedPlaces[pos];
      final visit = pos < selectedVisits.length ? selectedVisits[pos] : null;
      final arrivalStr = visit != null
          ? minutesToTimeString(visit.arrivalMinutes)
          : p.suggestedTime;
      final startStr = visit != null
          ? minutesToTimeString(visit.startMinutes)
          : p.suggestedTime;
      final endStr = visit != null
          ? minutesToTimeString(visit.endMinutes)
          : minutesToTimeString(
              parseTimeToMinutes(p.suggestedTime) + p.durationMinutes);
      final roleStr = visit?.role.name ?? 'nonMeal';
      final statusStr = visit?.openingStatus.name ?? 'open';

      debugPrint(
        '[FLEX_ROUTE][VISIT] day=$dayIndex position=$pos placeId=${p.placeId} name="${p.name}" role=$roleStr arrival=$arrivalStr start=$startStr end=$endStr openingStatus=$statusStr',
      );
    }

    for (int legIdx = 0; legIdx < selectedLegs.length; legIdx++) {
      final leg = selectedLegs[legIdx];
      debugPrint(
        '[FLEX_ROUTE][LEG] day=$dayIndex legIndex=$legIdx from=${leg.fromPlaceId} to=${leg.toPlaceId} distanceMeters=${leg.distanceMeters.toStringAsFixed(1)} durationSeconds=${leg.durationSeconds} source=${leg.source}',
      );
    }

    return PermutationOptimizationResult(
      isFeasible: true,
      places: orderedPlaces,
      originalIndices: selectedPerm,
      totalRoadDistanceMeters: selectedRoadDist,
      totalRoadDurationSeconds: selectedRoadDurSec,
      waitingMinutes: selectedWaitMin,
      requiredMeals: selectedMeals,
      visits: selectedVisits,
      legs: selectedLegs,
      permutationsEvaluated: permutationsEvaluated,
      feasiblePermutations: feasiblePermutations,
      rejectedOpeningHours: rejectedOpeningHours,
      rejectedMealWindow: rejectedMealWindow,
      rejectedDayEnd: rejectedDayEnd,
      rejectedInvalidRoute: rejectedInvalidRoute,
    );
  }
}
