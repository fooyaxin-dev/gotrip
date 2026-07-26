import 'package:flutter/material.dart';
import '../../models/placeModel.dart';
import '../../services/route_service.dart';
import '../../services/userPreference_service.dart';
import '../../services/location_service.dart';
import '../../modules/place/placeDetailPage.dart';
import '../../modules/place/categoryImage_Helper.dart';

class AllRecommendedPlacesPage extends StatelessWidget {
  final List<PlaceModel> places;
  final Map<String, RouteResult> routeResults;

  const AllRecommendedPlacesPage({
    super.key,
    required this.places,
    required this.routeResults,
  });

  Future<void> _openPlaceDetail(BuildContext context, PlaceModel place) async {
    final pos = LocationService.instance.currentPosition;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceDetailPage(
          placeId: place.id,
          lat: place.lat,
          lng: place.lng,
          userLat: pos?.latitude,
          userLng: pos?.longitude,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8F6FF),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        title: Text('For You · ${places.length} places',
            style: const TextStyle(
                color: Colors.black87,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: places.isEmpty
          ? Center(
              child: Text('No recommended places right now',
                  style: TextStyle(color: Colors.grey[500])),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              itemCount: places.length,
              itemBuilder: (context, index) =>
                  _buildCard(context, places[index]),
            ),
    );
  }

  Widget _buildCard(BuildContext context, PlaceModel place) {
    final route = routeResults[place.id];
    final dist  = route != null ? (route.distanceMeters / 1000).toStringAsFixed(1) : null;
    final mins  = route != null ? (route.durationSeconds ~/ 60).toString() : null;

    final reason = UserPreferenceService.instance.getRecommendReason(
      primaryType: place.primaryType,
      allTypes:    place.allTypes,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: () => _openPlaceDetail(context, place),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 4))],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: place.photoUrl != null && place.photoUrl!.isNotEmpty
                    ? Image.network(
                        place.photoUrl!,
                        width: 76, height: 76, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(place),
                      )
                    : _placeholder(place),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    if (place.address != null)
                      Text(place.address!,
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Row(children: [
                      if (place.rating != null) ...[
                        const Icon(Icons.star_rounded, size: 14, color: Colors.orange),
                        const SizedBox(width: 2),
                        Text(place.rating!.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.orange)),
                        const SizedBox(width: 10),
                      ],
                      if (dist != null) ...[
                        Icon(Icons.near_me_rounded, size: 12, color: Colors.blue[300]),
                        const SizedBox(width: 3),
                        Text('$dist km', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                        const SizedBox(width: 10),
                      ],
                      if (mins != null) ...[
                        Icon(Icons.access_time_rounded, size: 12, color: Colors.grey[400]),
                        const SizedBox(width: 3),
                        Text('$mins min', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                      ],
                    ]),
                    if (reason != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7C4DFF).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(reason,
                            style: const TextStyle(fontSize: 10.5, color: Color(0xFF7C4DFF), fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.grey[300]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(PlaceModel place) => Container(
        width: 76, height: 76,
        color: Colors.grey[100],
        child: Image.asset(
          CategoryImageHelper.getAssetPath(place.primaryType, place.allTypes),
          fit: BoxFit.cover,
        ),
      );
}