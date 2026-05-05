class PlaceModel {
  final String id;
  final String name;
  final String? address;
  final double? lat;
  final double? lng;
  final double? rating;
  final String? photoUrl;
  final String source; 
  final String? primaryType;
  final String? secondaryType;
  final List<String> allTypes;
  final int? priceLevel;

  PlaceModel({
    required this.id,
    required this.name,
    this.address,
    this.lat,
    this.lng,
    this.rating,
    this.photoUrl,
    required this.source,
    this.primaryType,
    this.secondaryType,
    this.allTypes = const [],
    this.priceLevel,
  });

  List<String> get types {
    final list = <String>[];
    if (primaryType != null) list.add(primaryType!);
    if (secondaryType != null) list.add(secondaryType!);
    return list;
  }

  // convert from Google Places API response to our PlaceModel
  factory PlaceModel.fromGoogle(
    Map<String, dynamic> g, {
    String? primary,
    String? secondary,
  }) {

    final rawTypes = (g['types'] as List?)?.map((e) => e.toString()).toList() ?? [];

    // Google returns priceLevel as a string enum:
    // "PRICE_LEVEL_FREE"         → 0 (treat as null, free places aren't price-filtered)
    // "PRICE_LEVEL_INEXPENSIVE"  → 1
    // "PRICE_LEVEL_MODERATE"     → 2
    // "PRICE_LEVEL_EXPENSIVE"    → 3
    // "PRICE_LEVEL_VERY_EXPENSIVE" → 4
    int? priceLevel;
    final rawPrice = g['priceLevel'] as String?;
    switch (rawPrice) {
      case 'PRICE_LEVEL_INEXPENSIVE':    priceLevel = 1; break;
      case 'PRICE_LEVEL_MODERATE':       priceLevel = 2; break;
      case 'PRICE_LEVEL_EXPENSIVE':      priceLevel = 3; break;
      case 'PRICE_LEVEL_VERY_EXPENSIVE': priceLevel = 4; break; 
      default: priceLevel = null; // FREE or unspecified 
    }

    return PlaceModel(
      id:            g['id'] ?? '',
      name:          g['displayName']?['text'] ?? '未知地点',
      address:       g['formattedAddress'],
      lat:           (g['location']?['latitude']  as num?)?.toDouble(),
      lng:           (g['location']?['longitude'] as num?)?.toDouble(),
      rating:        (g['rating'] as num?)?.toDouble(),
      photoUrl:      g['photos'] != null && (g['photos'] as List).isNotEmpty
                         ? g['photos'][0]['photoUri']
                         : null,
      source:        'google',
      primaryType:   primary,
      secondaryType: secondary,
      allTypes:      rawTypes,
      priceLevel:    priceLevel,
    );
  }

  
}