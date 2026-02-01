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

  PlaceModel({
    required this.id, required this.name, this.address,
    this.lat, this.lng, this.rating, this.photoUrl,
    required this.source, this.primaryType, this.secondaryType,
  });

  factory PlaceModel.fromGoogle(Map<String, dynamic> g, {String? primary, String? secondary}) {
    return PlaceModel(
      id: g['id'] ?? '',
      name: g['displayName']?['text'] ?? '未知地点',
      address: g['formattedAddress'],
      lat: (g['location']?['latitude'] as num?)?.toDouble(),
      lng: (g['location']?['longitude'] as num?)?.toDouble(),
      rating: (g['rating'] as num?)?.toDouble(),
      // 这里的 photoUri 是你在 PlacesApiService 里已经拼好的 URL
      photoUrl: g['photos'] != null && g['photos'].isNotEmpty ? g['photos'][0]['photoUri'] : null,
      source: 'google',
      primaryType: primary,
      secondaryType: secondary,
    );
  }

  factory PlaceModel.fromFoursquare(Map<String, dynamic> f, {String? primary, String? secondary}) {
    final geoc = f['geocodes']?['main'];
    
    // 解析 Foursquare 图片逻辑
    String? fsPhoto;
    if (f['photos'] != null && (f['photos'] as List).isNotEmpty) {
      final p = f['photos'][0];
      fsPhoto = "${p['prefix']}300x300${p['suffix']}"; // 取 300x300 尺寸
    }

    return PlaceModel(
      id: f['fsq_id'] ?? '',
      name: f['name'] ?? '未知地点',
      address: f['location']?['formatted_address'],
      lat: (geoc?['latitude'] as num?)?.toDouble(),
      lng: (geoc?['longitude'] as num?)?.toDouble(),
      // Foursquare 是 10 分制，转成 5 分制
      rating: f['rating'] != null ? (f['rating'] as num).toDouble() / 2.0 : null,
      photoUrl: fsPhoto,
      source: 'foursquare',
      primaryType: primary,
      secondaryType: secondary,
    );
  }
}