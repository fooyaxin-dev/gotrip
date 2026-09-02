import 'package:cloud_firestore/cloud_firestore.dart';
import 'placeModel.dart';

// models/itinerary_model.dart

class ItineraryPlace {
  final String placeId;
  final String name;
  final String address;
  final String? photoUrl;
  final double? lat;
  final double? lng;
  final String? primaryType;
  final List<String> allTypes;
  final String suggestedTime; // "09:00"
  final int durationMinutes; // 建议停留时间
  final String? notes; // AI 生成的备注
  final bool isVisited; // ✅ 用户实际到访过
  final DateTime? visitedAt; // ✅ 实际到访时间
  final List<OpeningHoursPeriod>? regularOpeningPeriods; // 🆕 营业时间段

  ItineraryPlace({
    required this.placeId,
    required this.name,
    required this.address,
    this.photoUrl,
    this.lat,
    this.lng,
    this.primaryType,
    this.allTypes = const [],
    required this.suggestedTime,
    required this.durationMinutes,
    this.notes,
    this.isVisited = false,
    this.visitedAt,
    this.regularOpeningPeriods,
  });

  factory ItineraryPlace.fromMap(Map<String, dynamic> m) => ItineraryPlace(
        placeId: m['placeId'] ?? '',
        name: m['name'] ?? '',
        address: m['address'] ?? '',
        photoUrl: m['photoUrl'],
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
        primaryType: m['primaryType'],
        allTypes: (m['allTypes'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        suggestedTime: m['suggestedTime'] ?? '09:00',
        durationMinutes: (m['durationMinutes'] as num?)?.toInt() ?? 60,
        notes: m['notes'],
        isVisited: m['isVisited'] ?? false,
        visitedAt: m['visitedAt'] != null
            ? (m['visitedAt'] as dynamic).toDate()
            : null,
        regularOpeningPeriods: (m['regularOpeningPeriods'] as List<dynamic>?)
            ?.map((e) => OpeningHoursPeriod.fromJson(e))
            .whereType<OpeningHoursPeriod>()
            .toList(),
      );

  Map<String, dynamic> toMap() => {
        'placeId': placeId,
        'name': name,
        'address': address,
        'photoUrl': photoUrl,
        'lat': lat,
        'lng': lng,
        'primaryType': primaryType,
        if (allTypes.isNotEmpty) 'allTypes': allTypes,
        'suggestedTime': suggestedTime,
        'durationMinutes': durationMinutes,
        'notes': notes,
        'isVisited': isVisited,
        'visitedAt': visitedAt,
        if (regularOpeningPeriods != null)
          'regularOpeningPeriods':
              regularOpeningPeriods!.map((p) => p.toJson()).toList(),
      };

  ItineraryPlace copyWith({
    String? suggestedTime,
    int? durationMinutes,
    String? notes,
    bool? isVisited,
    DateTime? visitedAt,
    String? photoUrl,
    String? primaryType,
    List<String>? allTypes,
    List<OpeningHoursPeriod>? regularOpeningPeriods,
  }) =>
      ItineraryPlace(
        placeId: placeId,
        name: name,
        address: address,
        photoUrl: photoUrl ?? this.photoUrl,
        lat: lat,
        lng: lng,
        primaryType: primaryType ?? this.primaryType,
        allTypes: allTypes ?? this.allTypes,
        suggestedTime: suggestedTime ?? this.suggestedTime,
        durationMinutes: durationMinutes ?? this.durationMinutes,
        notes: notes ?? this.notes,
        isVisited: isVisited ?? this.isVisited,
        visitedAt: visitedAt ?? this.visitedAt,
        regularOpeningPeriods:
            regularOpeningPeriods ?? this.regularOpeningPeriods,
      );
}

// ─────────────────────────────────────────────────────────────────────────────

class ItineraryDay {
  final int dayNumber;
  final String date;
  final List<ItineraryPlace> places;
  final String? legsSignature; // 🆕
  final List<Map<String, dynamic>>? legsData; // 🆕

  ItineraryDay({
    required this.dayNumber,
    required this.date,
    required this.places,
    this.legsSignature, // 🆕
    this.legsData, // 🆕
  });

  factory ItineraryDay.fromMap(Map<String, dynamic> m) => ItineraryDay(
        dayNumber: (m['dayNumber'] as num?)?.toInt() ?? 1,
        date: m['date'] ?? '',
        places: (m['places'] as List<dynamic>? ?? [])
            .map((p) => ItineraryPlace.fromMap(Map<String, dynamic>.from(p)))
            .toList(),
        legsSignature: m['legsSignature'], // 🆕
        legsData: (m['legsData'] as List<dynamic>?) // 🆕
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );

  Map<String, dynamic> toMap() => {
        'dayNumber': dayNumber,
        'date': date,
        'places': places.map((p) => p.toMap()).toList(),
        'legsSignature': legsSignature, // 🆕
        'legsData': legsData, // 🆕
      };

  // 🔧 clearLegs=true 时强制把两个字段清空成 null（?? 模式没法主动置空）
  ItineraryDay copyWith({
    List<ItineraryPlace>? places,
    String? legsSignature,
    List<Map<String, dynamic>>? legsData,
    bool clearLegs = false, // 🆕
  }) =>
      ItineraryDay(
        dayNumber: dayNumber,
        date: date,
        places: places ?? this.places,
        legsSignature: clearLegs ? null : (legsSignature ?? this.legsSignature),
        legsData: clearLegs ? null : (legsData ?? this.legsData),
      );

  int get visitedCount => places.where((p) => p.isVisited).length;
  int get totalCount => places.length;
  bool get isCompleted => totalCount > 0 && visitedCount == totalCount;

  ItineraryPlace? get nextPlace => places.cast<ItineraryPlace?>().firstWhere(
        (p) => !p!.isVisited,
        orElse: () => null,
      );
}

// ─────────────────────────────────────────────────────────────────────────────

class ItineraryModel {
  final String id;
  final String title;
  final String startDate;
  final int totalDays;
  final List<ItineraryDay> days;
  final DateTime createdAt;
  final bool isOriginCurrentLocation;
  final double? originLat; // 🆕
  final double? originLng; // 🆕
  final String? originName; // 🆕
  final String travelMode; // 🆕 'walk' | 'motor' | 'drive' — 生成/上次编辑时用的出行方式
  final List<String> leftoverPlaceIds;
  final List<PlaceModel> leftoverPlaces;

  ItineraryModel({
    required this.id,
    required this.title,
    required this.startDate,
    required this.totalDays,
    required this.days,
    required this.createdAt,
    required this.isOriginCurrentLocation,
    this.originLat,
    this.originLng,
    this.originName,
    this.travelMode = 'walk', // 🆕 默认值，保证老代码里没传这个参数也能编译/运行
    this.leftoverPlaceIds = const [],
    this.leftoverPlaces = const [],
  });

  static Map<String, dynamic> _compactPlaceToMap(PlaceModel p) => {
        'placeId': p.id,
        'name': p.name,
        'address': p.address,
        'lat': p.lat,
        'lng': p.lng,
        'photoUrl': p.photoUrl,
        'rating': p.rating,
        'primaryType': p.primaryType,
        'allTypes': p.allTypes,
        'source': p.source,
      };

  static PlaceModel? _compactPlaceFromMap(dynamic raw) {
    if (raw is! Map) return null;
    try {
      final m = Map<String, dynamic>.from(raw);
      final id = (m['placeId'] ?? m['id'] ?? '').toString();
      if (id.isEmpty) return null;
      final name = (m['name'] ?? '').toString();
      final address = m['address'] as String?;
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lng'] as num?)?.toDouble();
      final photoUrl = m['photoUrl'] as String?;
      final rating = (m['rating'] as num?)?.toDouble();
      final primaryType = m['primaryType'] as String?;
      final allTypes = (m['allTypes'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [];
      final source = (m['source'] ?? 'google').toString();

      return PlaceModel(
        id: id,
        name: name.isNotEmpty ? name : 'Unknown',
        address: address,
        lat: lat,
        lng: lng,
        rating: rating,
        photoUrl: photoUrl,
        source: source,
        primaryType: primaryType,
        allTypes: allTypes,
      );
    } catch (_) {
      return null;
    }
  }

  factory ItineraryModel.fromMap(String id, Map<String, dynamic> m) {
    final seenPlaceIds = <String>{};
    final rawPlaces = (m['leftoverPlaces'] as List<dynamic>?) ?? const [];
    final loadedPlaces = <PlaceModel>[];
    for (final item in rawPlaces) {
      final p = _compactPlaceFromMap(item);
      if (p != null && seenPlaceIds.add(p.id)) {
        loadedPlaces.add(p);
      }
    }

    final rawIds = (m['leftoverPlaceIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const [];
    final loadedIds = <String>{};
    for (final rawId in rawIds) {
      if (rawId.isNotEmpty) loadedIds.add(rawId);
    }
    for (final p in loadedPlaces) {
      loadedIds.add(p.id);
    }

    return ItineraryModel(
      id: id,
      title: m['title'] ?? 'My Trip',
      startDate: m['startDate'] ?? '',
      totalDays: (m['totalDays'] as num?)?.toInt() ?? 1,
      days: (m['days'] as List<dynamic>? ?? [])
          .map((d) => ItineraryDay.fromMap(Map<String, dynamic>.from(d)))
          .toList(),
      createdAt: (m['createdAt'] as dynamic)?.toDate() ?? DateTime.now(),
      isOriginCurrentLocation: m['isOriginCurrentLocation'] ?? false,
      originLat: (m['originLat'] as num?)?.toDouble(),
      originLng: (m['originLng'] as num?)?.toDouble(),
      originName: m['originName'],
      travelMode: m['travelMode'] ?? 'walk',
      leftoverPlaceIds: loadedIds.toList(),
      leftoverPlaces: loadedPlaces,
    );
  }

  Map<String, dynamic> toMap() {
    final seenSnapshots = <String>{};
    final deduplicatedPlaces = <PlaceModel>[];
    for (final p in leftoverPlaces) {
      if (p.id.isNotEmpty && seenSnapshots.add(p.id)) {
        deduplicatedPlaces.add(p);
      }
    }
    final allIds = <String>{
      ...deduplicatedPlaces.map((p) => p.id),
      ...leftoverPlaceIds.where((id) => id.isNotEmpty),
    }.toList();

    return {
      'title': title,
      'startDate': startDate,
      'totalDays': totalDays,
      'days': days.map((d) => d.toMap()).toList(),
      'createdAt': Timestamp.fromDate(createdAt),
      'isOriginCurrentLocation': isOriginCurrentLocation,
      'originLat': originLat,
      'originLng': originLng,
      'originName': originName,
      'travelMode': travelMode,
      'leftoverPlaceIds': allIds,
      'leftoverPlaces': deduplicatedPlaces.map(_compactPlaceToMap).toList(),
    };
  }

  ItineraryModel copyWith({
    String? id,
    List<ItineraryDay>? days,
    String? title,
    bool? isOriginCurrentLocation,
    double? originLat,
    double? originLng,
    String? originName,
    String? travelMode, // 🆕
    List<String>? leftoverPlaceIds, // 🆕
    List<PlaceModel>? leftoverPlaces,
  }) =>
      ItineraryModel(
        id: id ?? this.id,
        title: title ?? this.title,
        startDate: startDate,
        totalDays: totalDays,
        days: days ?? this.days,
        createdAt: createdAt,
        isOriginCurrentLocation:
            isOriginCurrentLocation ?? this.isOriginCurrentLocation,
        originLat: originLat ?? this.originLat,
        originLng: originLng ?? this.originLng,
        originName: originName ?? this.originName,
        travelMode: travelMode ?? this.travelMode, // 🆕
        leftoverPlaceIds: leftoverPlaceIds ?? this.leftoverPlaceIds, // 🆕
        leftoverPlaces: leftoverPlaces ?? this.leftoverPlaces,
      );

  int get totalVisited => days.fold(0, (sum, d) => sum + d.visitedCount);
  int get totalPlaces => days.fold(0, (sum, d) => sum + d.totalCount);
  bool get isCompleted => totalPlaces > 0 && totalVisited == totalPlaces;
  bool get isStarted => totalVisited > 0;
}
