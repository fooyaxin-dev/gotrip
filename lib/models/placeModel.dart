class OpeningHoursPoint {
  final int day; // 0 = Sunday, 1 = Monday, ..., 6 = Saturday
  final int hour; // 0..23
  final int minute; // 0..59

  const OpeningHoursPoint({
    required this.day,
    required this.hour,
    required this.minute,
  });

  bool get isSundayMidnight => day == 0 && hour == 0 && minute == 0;

  static OpeningHoursPoint? fromJson(dynamic json) {
    if (json is! Map) return null;
    final day = json['day'] as num?;
    final hour = json['hour'] as num?;
    final minute = json['minute'] as num?;
    if (day == null || hour == null || minute == null) return null;
    final d = day.toInt();
    final h = hour.toInt();
    final m = minute.toInt();
    if (d < 0 || d > 6 || h < 0 || h > 23 || m < 0 || m > 59) return null;
    return OpeningHoursPoint(day: d, hour: h, minute: m);
  }

  Map<String, dynamic> toJson() => {
        'day': day,
        'hour': hour,
        'minute': minute,
      };
}

class OpeningHoursPeriod {
  final OpeningHoursPoint open;
  final OpeningHoursPoint? close; // Nullable for 24-hour places

  const OpeningHoursPeriod({
    required this.open,
    this.close,
  });

  bool get is24Hours => close == null && open.isSundayMidnight;

  bool get isValid => close != null || (close == null && open.isSundayMidnight);

  static OpeningHoursPeriod? fromJson(dynamic json) {
    if (json is! Map) return null;
    final open = OpeningHoursPoint.fromJson(json['open']);
    if (open == null) return null;

    OpeningHoursPoint? close;
    if (json.containsKey('close') && json['close'] != null) {
      close = OpeningHoursPoint.fromJson(json['close']);
      if (close == null) return null;
    } else {
      // close is absent/null: Only valid if open is Sunday 00:00 (Google 24-hour representation).
      if (!open.isSundayMidnight) return null;
    }

    return OpeningHoursPeriod(open: open, close: close);
  }

  Map<String, dynamic> toJson() => {
        'open': open.toJson(),
        if (close != null) 'close': close!.toJson(),
      };
}

class PlaceModel {
  final String id;
  final String name;
  final String? address;
  final double? lat;
  final double? lng;
  final double? rating;
  final int? userRatingCount;
  final String? photoUrl;
  final String source;
  final String? primaryType;
  final String? secondaryType;
  final List<String> allTypes;
  final int? priceLevel;
  final String? geoapifyPlaceId;
  final String? osmId;
  final String? osmType;
  final bool? isOpenNow;
  final List<OpeningHoursPeriod>? regularOpeningPeriods;
  final int? utcOffsetMinutes;

  PlaceModel({
    required this.id,
    required this.name,
    this.address,
    this.lat,
    this.lng,
    this.rating,
    this.userRatingCount,
    this.photoUrl,
    required this.source,
    this.primaryType,
    this.secondaryType,
    this.allTypes = const [],
    this.priceLevel,
    this.geoapifyPlaceId,
    this.osmId,
    this.osmType,
    this.isOpenNow,
    this.regularOpeningPeriods,
    this.utcOffsetMinutes,
  });

  List<String> get types {
    final list = <String>[];
    if (primaryType != null) list.add(primaryType!);
    if (secondaryType != null) list.add(secondaryType!);
    return list;
  }

  bool get isGeoapify => source == 'geoapify';

  factory PlaceModel.fromGoogle(
    Map<String, dynamic> g, {
    String? primary,
    String? secondary,
    String? sourceOverride,
  }) {
    final rawTypes =
        (g['types'] as List?)?.map((e) => e.toString()).toList() ?? [];

    final resolvedSource =
        sourceOverride ?? (g['source'] as String?) ?? 'google';

    int? priceLevel;
    final rawPrice = g['priceLevel'] as String?;
    switch (rawPrice) {
      case 'PRICE_LEVEL_INEXPENSIVE':
        priceLevel = 1;
        break;
      case 'PRICE_LEVEL_MODERATE':
        priceLevel = 2;
        break;
      case 'PRICE_LEVEL_EXPENSIVE':
        priceLevel = 3;
        break;
      case 'PRICE_LEVEL_VERY_EXPENSIVE':
        priceLevel = 4;
        break;
      default:
        priceLevel = null;
    }

    final rawPeriods = (g['regularOpeningHours'] is Map)
        ? (g['regularOpeningHours']['periods'] as List?)
        : (g['periods'] as List?);
    final periods = rawPeriods
        ?.map((p) => OpeningHoursPeriod.fromJson(p))
        .whereType<OpeningHoursPeriod>()
        .toList();

    final utcOffset = (g['utcOffsetMinutes'] as num?)?.toInt();

    return PlaceModel(
      id: g['id'] ?? '',
      name: g['displayName']?['text'] ?? 'Unknown',
      address: g['formattedAddress'],
      lat: (g['location']?['latitude'] as num?)?.toDouble(),
      lng: (g['location']?['longitude'] as num?)?.toDouble(),
      rating: (g['rating'] as num?)?.toDouble(),
      userRatingCount: (g['userRatingCount'] as num?)?.toInt(),
      photoUrl: g['photos'] != null && (g['photos'] as List).isNotEmpty
          ? g['photos'][0]['photoUri']
          : null,
      source: resolvedSource,
      primaryType: primary,
      secondaryType: secondary,
      allTypes: rawTypes,
      priceLevel: priceLevel,
      geoapifyPlaceId: g['geoapifyPlaceId'] as String?,
      osmId: g['osmId'] as String?,
      osmType: g['osmType'] as String?,
      isOpenNow: g['isOpenNow'] as bool?,
      regularOpeningPeriods: periods,
      utcOffsetMinutes: utcOffset,
    );
  }

  PlaceModel copyWith({
    List<String>? allTypes,
    List<OpeningHoursPeriod>? regularOpeningPeriods,
    int? utcOffsetMinutes,
    bool? isOpenNow,
  }) {
    return PlaceModel(
      id: id,
      name: name,
      address: address,
      lat: lat,
      lng: lng,
      rating: rating,
      userRatingCount: userRatingCount,
      photoUrl: photoUrl,
      source: source,
      primaryType: primaryType,
      secondaryType: secondaryType,
      allTypes: allTypes ?? this.allTypes,
      priceLevel: priceLevel,
      geoapifyPlaceId: geoapifyPlaceId,
      osmId: osmId,
      osmType: osmType,
      isOpenNow: isOpenNow ?? this.isOpenNow,
      regularOpeningPeriods:
          regularOpeningPeriods ?? this.regularOpeningPeriods,
      utcOffsetMinutes: utcOffsetMinutes ?? this.utcOffsetMinutes,
    );
  }
}
