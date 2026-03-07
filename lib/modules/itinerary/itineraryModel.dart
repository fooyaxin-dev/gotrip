// models/itinerary_model.dart

class ItineraryPlace {
  final String placeId;
  final String name;
  final String address;
  final String? photoUrl;
  final double? lat;
  final double? lng;
  final String? primaryType;
  final String suggestedTime;  // "09:00"
  final int durationMinutes;   // 建议停留时间
  final String? notes;         // AI 生成的备注

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
  };

  ItineraryPlace copyWith({
    String? suggestedTime,
    int? durationMinutes,
    String? notes,
  }) => ItineraryPlace(
    placeId:         placeId,
    name:            name,
    address:         address,
    photoUrl:        photoUrl,
    lat:             lat,
    lng:             lng,
    primaryType:     primaryType,
    suggestedTime:   suggestedTime   ?? this.suggestedTime,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    notes:           notes           ?? this.notes,
  );
}

class ItineraryDay {
  final int dayNumber;
  final String date;         // "2026-03-07"
  final List<ItineraryPlace> places;

  ItineraryDay({
    required this.dayNumber,
    required this.date,
    required this.places,
  });

  factory ItineraryDay.fromMap(Map<String, dynamic> m) => ItineraryDay(
    dayNumber: (m['dayNumber'] as num?)?.toInt() ?? 1,
    date:      m['date'] ?? '',
    places:    (m['places'] as List<dynamic>? ?? [])
        .map((p) => ItineraryPlace.fromMap(Map<String, dynamic>.from(p)))
        .toList(),
  );

  Map<String, dynamic> toMap() => {
    'dayNumber': dayNumber,
    'date':      date,
    'places':    places.map((p) => p.toMap()).toList(),
  };

  ItineraryDay copyWith({List<ItineraryPlace>? places}) => ItineraryDay(
    dayNumber: dayNumber,
    date:      date,
    places:    places ?? this.places,
  );
}

class ItineraryModel {
  final String id;
  final String title;
  final String startDate;
  final int totalDays;
  final List<ItineraryDay> days;
  final DateTime createdAt;

  ItineraryModel({
    required this.id,
    required this.title,
    required this.startDate,
    required this.totalDays,
    required this.days,
    required this.createdAt,
  });

  factory ItineraryModel.fromMap(String id, Map<String, dynamic> m) => ItineraryModel(
    id:        id,
    title:     m['title']     ?? 'My Trip',
    startDate: m['startDate'] ?? '',
    totalDays: (m['totalDays'] as num?)?.toInt() ?? 1,
    days:      (m['days'] as List<dynamic>? ?? [])
        .map((d) => ItineraryDay.fromMap(Map<String, dynamic>.from(d)))
        .toList(),
    createdAt: (m['createdAt'] as dynamic)?.toDate() ?? DateTime.now(),
  );

  Map<String, dynamic> toMap() => {
    'title':     title,
    'startDate': startDate,
    'totalDays': totalDays,
    'days':      days.map((d) => d.toMap()).toList(),
    'createdAt': createdAt,
  };

  ItineraryModel copyWith({List<ItineraryDay>? days, String? title}) => ItineraryModel(
    id:        id,
    title:     title     ?? this.title,
    startDate: startDate,
    totalDays: totalDays,
    days:      days      ?? this.days,
    createdAt: createdAt,
  );
}