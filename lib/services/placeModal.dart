class PlaceModel {
  final String id;
  final String name;
  final String? address;
  final double? lat;
  final double? lng;
  final double? rating;
  final String? photoUrl;
  final String source; // 'google' | 'foursquare'
  final String? primaryType;
  final String? secondaryType;
  final List<String> allTypes;

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
  });

  List<String> get types {
    final list = <String>[];
    if (primaryType != null) list.add(primaryType!);
    if (secondaryType != null) list.add(secondaryType!);
    return list;
  }

  // ─────────────────────────────────────────────
  // Google Places API v2
  // ─────────────────────────────────────────────

  factory PlaceModel.fromGoogle(
    Map<String, dynamic> g, {
    String? primary,
    String? secondary,
  }) {
    final rawTypes = (g['types'] as List?)?.map((e) => e.toString()).toList() ?? [];

    return PlaceModel(
      id: g['id'] ?? '',
      name: g['displayName']?['text'] ?? '未知地点',
      address: g['formattedAddress'],
      lat: (g['location']?['latitude'] as num?)?.toDouble(),
      lng: (g['location']?['longitude'] as num?)?.toDouble(),
      rating: (g['rating'] as num?)?.toDouble(),
      photoUrl: g['photos'] != null && (g['photos'] as List).isNotEmpty
          ? g['photos'][0]['photoUri']
          : null,
      source: 'google',
      primaryType: primary,
      secondaryType: secondary,
      allTypes: rawTypes,
    );
  }

  // ─────────────────────────────────────────────
  // Foursquare Places API v3
  // ─────────────────────────────────────────────

  factory PlaceModel.fromFoursquare(Map<String, dynamic> f) {
    final geocodes = f['geocodes']?['main'];
    final lat = (geocodes?['latitude'] as num?)?.toDouble();
    final lng = (geocodes?['longitude'] as num?)?.toDouble();

    final location = f['location'];
    final address = location?['formatted_address'] ??
        [
          location?['address'],
          location?['locality'],
          location?['country'],
        ].where((e) => e != null).join(', ');

    // 照片：prefix + size + suffix
    String? photoUrl;
    final photos = f['photos'] as List?;
    if (photos != null && photos.isNotEmpty) {
      final photo = photos.first;
      photoUrl = '${photo['prefix']}300x300${photo['suffix']}';
    }

    // Foursquare 评分是 0-10，换算成 0-5
    final rawRating = (f['rating'] as num?)?.toDouble();
    final rating = rawRating != null
        ? double.parse((rawRating / 2).toStringAsFixed(1))
        : null;

    final categories = (f['categories'] as List?)
            ?.map((c) => c['name']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];

    return PlaceModel(
      id: 'fsq_${f['fsq_id']}',
      name: f['name'] ?? '未知地点',
      address: address,
      lat: lat,
      lng: lng,
      rating: rating,
      photoUrl: photoUrl,
      source: 'foursquare',
      allTypes: categories,
    );
  }
}