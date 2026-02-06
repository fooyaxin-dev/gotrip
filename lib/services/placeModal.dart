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
}