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
  final String? osmId;   // ← 新增
  final String? osmType; // ← 新增
  final bool? isOpenNow;  

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
    this.osmId,   // ← 新增
    this.osmType, // ← 新增
    this.isOpenNow,
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
    final rawTypes = (g['types'] as List?)?.map((e) => e.toString()).toList() ?? [];

    final resolvedSource = sourceOverride
        ?? (g['source'] as String?)
        ?? 'google';

    int? priceLevel;
    final rawPrice = g['priceLevel'] as String?;
    switch (rawPrice) {
      case 'PRICE_LEVEL_INEXPENSIVE':    priceLevel = 1; break;
      case 'PRICE_LEVEL_MODERATE':       priceLevel = 2; break;
      case 'PRICE_LEVEL_EXPENSIVE':      priceLevel = 3; break;
      case 'PRICE_LEVEL_VERY_EXPENSIVE': priceLevel = 4; break;
      default: priceLevel = null;
    }

    return PlaceModel(
      id:               g['id'] ?? '',
      name:             g['displayName']?['text'] ?? 'Unknown',
      address:          g['formattedAddress'],
      lat:              (g['location']?['latitude']  as num?)?.toDouble(),
      lng:              (g['location']?['longitude'] as num?)?.toDouble(),
      rating:           (g['rating'] as num?)?.toDouble(),
      userRatingCount:  (g['userRatingCount'] as num?)?.toInt(),
      photoUrl:         g['photos'] != null && (g['photos'] as List).isNotEmpty
                            ? g['photos'][0]['photoUri']
                            : null,
      source:           resolvedSource,
      primaryType:      primary,
      secondaryType:    secondary,
      allTypes:         rawTypes,
      priceLevel:       priceLevel,
      geoapifyPlaceId:  g['geoapifyPlaceId'] as String?,
      osmId:            g['osmId']   as String?, // ← 新增
      osmType:          g['osmType'] as String?, // ← 新增
      isOpenNow:        g['isOpenNow'] as bool?, // ← 新增
    );
  }

  PlaceModel copyWith({List<String>? allTypes}) {
    return PlaceModel(
      id:              id,
      name:            name,
      address:         address,
      lat:             lat,
      lng:             lng,
      rating:          rating,
      userRatingCount: userRatingCount,
      photoUrl:        photoUrl,
      source:          source,
      primaryType:     primaryType,
      secondaryType:   secondaryType,
      allTypes:        allTypes ?? this.allTypes,
      priceLevel:      priceLevel,
      geoapifyPlaceId: geoapifyPlaceId,
      osmId:           osmId,
      osmType:         osmType,
      isOpenNow:       isOpenNow
    );
  }
  
}


