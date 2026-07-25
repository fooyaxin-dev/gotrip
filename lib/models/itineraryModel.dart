import 'package:cloud_firestore/cloud_firestore.dart';

// models/itinerary_model.dart

class ItineraryPlace {
  final String placeId;
  final String name;
  final String address;
  final String? photoUrl;
  final double? lat;
  final double? lng;
  final String? primaryType;
  final String suggestedTime;   // "09:00"
  final int durationMinutes;    // 建议停留时间
  final String? notes;          // AI 生成的备注
  final bool isVisited;         // ✅ 用户实际到访过
  final DateTime? visitedAt;    // ✅ 实际到访时间

  ItineraryPlace({
    required this.placeId,
    required this.name,
    required this.address,
    this.photoUrl,
    this.lat,
    this.lng,
    this.primaryType,
    required this.suggestedTime,
    required this.durationMinutes,
    this.notes,
    this.isVisited  = false,
    this.visitedAt,
  });

  factory ItineraryPlace.fromMap(Map<String, dynamic> m) => ItineraryPlace(
    placeId:         m['placeId']         ?? '',
    name:            m['name']            ?? '',
    address:         m['address']         ?? '',
    photoUrl:        m['photoUrl'],
    lat:             (m['lat']  as num?)?.toDouble(),
    lng:             (m['lng']  as num?)?.toDouble(),
    primaryType:     m['primaryType'],
    suggestedTime:   m['suggestedTime']   ?? '09:00',
    durationMinutes: (m['durationMinutes'] as num?)?.toInt() ?? 60,
    notes:           m['notes'],
    isVisited:       m['isVisited']       ?? false,
    visitedAt:       m['visitedAt'] != null
        ? (m['visitedAt'] as dynamic).toDate()
        : null,
  );

  Map<String, dynamic> toMap() => {
    'placeId':         placeId,
    'name':            name,
    'address':         address,
    'photoUrl':        photoUrl,
    'lat':             lat,
    'lng':             lng,
    'primaryType':     primaryType,
    'suggestedTime':   suggestedTime,
    'durationMinutes': durationMinutes,
    'notes':           notes,
    'isVisited':       isVisited,
    'visitedAt':       visitedAt,
  };

  ItineraryPlace copyWith({
    String?   suggestedTime,
    int?      durationMinutes,
    String?   notes,
    bool?     isVisited,
    DateTime? visitedAt,
    String?   photoUrl,   
  }) => ItineraryPlace(
    placeId:         placeId,
    name:            name,
    address:         address,
    photoUrl:        photoUrl          ?? this.photoUrl,
    lat:             lat,
    lng:             lng,
    primaryType:     primaryType,
    suggestedTime:   suggestedTime   ?? this.suggestedTime,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    notes:           notes           ?? this.notes,
    isVisited:       isVisited       ?? this.isVisited,
    visitedAt:       visitedAt       ?? this.visitedAt,
  );
}

// ─────────────────────────────────────────────────────────────────────────────

class ItineraryDay {
  final int dayNumber;
  final String date;
  final List<ItineraryPlace> places;
  final String? legsSignature;                 // 🆕
  final List<Map<String, dynamic>>? legsData;   // 🆕

  ItineraryDay({
    required this.dayNumber,
    required this.date,
    required this.places,
    this.legsSignature,                        // 🆕
    this.legsData,                             // 🆕
  });

  factory ItineraryDay.fromMap(Map<String, dynamic> m) => ItineraryDay(
    dayNumber: (m['dayNumber'] as num?)?.toInt() ?? 1,
    date:      m['date'] ?? '',
    places:    (m['places'] as List<dynamic>? ?? [])
        .map((p) => ItineraryPlace.fromMap(Map<String, dynamic>.from(p)))
        .toList(),
    legsSignature: m['legsSignature'],                                   // 🆕
    legsData: (m['legsData'] as List<dynamic>?)                          // 🆕
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
  );

  Map<String, dynamic> toMap() => {
    'dayNumber': dayNumber,
    'date':      date,
    'places':    places.map((p) => p.toMap()).toList(),
    'legsSignature': legsSignature,   // 🆕
    'legsData':      legsData,        // 🆕
  };

  // 🔧 clearLegs=true 时强制把两个字段清空成 null（?? 模式没法主动置空）
  ItineraryDay copyWith({
    List<ItineraryPlace>? places,
    String? legsSignature,
    List<Map<String, dynamic>>? legsData,
    bool clearLegs = false,           // 🆕
  }) => ItineraryDay(
    dayNumber: dayNumber,
    date:      date,
    places:    places ?? this.places,
    legsSignature: clearLegs ? null : (legsSignature ?? this.legsSignature),
    legsData:      clearLegs ? null : (legsData      ?? this.legsData),
  );

  int get visitedCount   => places.where((p) => p.isVisited).length;
  int get totalCount     => places.length;
  bool get isCompleted   => totalCount > 0 && visitedCount == totalCount;

  ItineraryPlace? get nextPlace =>
      places.cast<ItineraryPlace?>().firstWhere(
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
  final double? originLat;      // 🆕
  final double? originLng;      // 🆕
  final String? originName;     // 🆕
  final String travelMode;      // 🆕 'walk' | 'motor' | 'drive' — 生成/上次编辑时用的出行方式

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
    this.travelMode = 'walk',     // 🆕 默认值，保证老代码里没传这个参数也能编译/运行
  });

  factory ItineraryModel.fromMap(String id, Map<String, dynamic> m) =>
      ItineraryModel(
        id:        id,
        title:     m['title']     ?? 'My Trip',
        startDate: m['startDate'] ?? '',
        totalDays: (m['totalDays'] as num?)?.toInt() ?? 1,
        days:      (m['days'] as List<dynamic>? ?? [])
            .map((d) => ItineraryDay.fromMap(Map<String, dynamic>.from(d)))
            .toList(),
        createdAt: (m['createdAt'] as dynamic)?.toDate() ?? DateTime.now(),
        isOriginCurrentLocation: m['isOriginCurrentLocation'] ?? false,
        originLat:  (m['originLat'] as num?)?.toDouble(),
        originLng:  (m['originLng'] as num?)?.toDouble(),
        originName: m['originName'],
        travelMode: m['travelMode'] ?? 'walk',   // 🆕 老数据没存过就退回 walk
      );

  Map<String, dynamic> toMap() => {
    'title':     title,
    'startDate': startDate,
    'totalDays': totalDays,
    'days':      days.map((d) => d.toMap()).toList(),
    'createdAt': Timestamp.fromDate(createdAt),
    'isOriginCurrentLocation': isOriginCurrentLocation,
    'originLat':  originLat,
    'originLng':  originLng,
    'originName': originName,
    'travelMode': travelMode,   // 🆕
  };

  ItineraryModel copyWith({
    String? id,
    List<ItineraryDay>? days,
    String? title,
    bool? isOriginCurrentLocation,
    double? originLat,
    double? originLng,
    String? originName,
    String? travelMode,          // 🆕
  }) => ItineraryModel(
    id:        id        ?? this.id,
    title:     title     ?? this.title,
    startDate: startDate,
    totalDays: totalDays,
    days:      days      ?? this.days,
    createdAt: createdAt,
    isOriginCurrentLocation: isOriginCurrentLocation ?? this.isOriginCurrentLocation,
    originLat:  originLat  ?? this.originLat,
    originLng:  originLng  ?? this.originLng,
    originName: originName ?? this.originName,
    travelMode: travelMode ?? this.travelMode,   // 🆕
  );

  int get totalVisited => days.fold(0, (sum, d) => sum + d.visitedCount);
  int get totalPlaces  => days.fold(0, (sum, d) => sum + d.totalCount);
  bool get isCompleted => totalPlaces > 0 && totalVisited == totalPlaces;
  bool get isStarted   => totalVisited > 0;
}