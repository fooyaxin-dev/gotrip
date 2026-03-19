import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart'; 
import '../../services/placesAPI_service.dart';
import 'favouriteButton.dart';
import 'routePreviewPage.dart'; 

class PlaceDetailPage extends StatefulWidget {
  final String placeId;
  final double? lat;   // destination latitude
  final double? lng;   // destination longitude
  final double? userLat; // user current latitude
  final double? userLng; // user current longitude

  const PlaceDetailPage({
    super.key,
    required this.placeId,
    this.lat,
    this.lng,
    this.userLat,
    this.userLng,
  });

  @override
  State<PlaceDetailPage> createState() => _PlaceDetailPageState();
}

class _PlaceDetailPageState extends State<PlaceDetailPage> {
  Map<String, dynamic>? placeDetail;
  bool loading = true;
  String? error;
  int _currentPhotoIndex = 0;

  late PageController _pageController;
  Timer? _autoPlayTimer;
  bool _isUserInteracting = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 1.0);
    _fetchPlaceDetails();
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _fetchPlaceDetails() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final data = await PlacesApiService.getPlaceDetails(widget.placeId);
      setState(() {
        placeDetail = data;
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  void _startAutoPlay(int total) {
    _autoPlayTimer?.cancel();
    if (total <= 1) return;

    _autoPlayTimer = Timer.periodic(
      const Duration(seconds: 4),
      (timer) {
        if (_isUserInteracting) return;
        int nextPage = _currentPhotoIndex + 1;
        if (nextPage >= total) nextPage = 0;
        _pageController.animateToPage(
          nextPage,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutCubic,
        );
      },
    );
  }

  void _navigateToGuide(String name) async {
    if (widget.lat == null || widget.lng == null) return;

    double? startLat = widget.userLat;
    double? startLng = widget.userLng;

    if (startLat == null || startLng == null) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        startLat = pos.latitude;
        startLng = pos.longitude;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to get current location. Please check location permissions.')),
          );
        }
        return;
      }
    }

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePreviewPage(
          startLat: startLat!,
          startLng: startLng!,
          endLat: widget.lat!,
          endLng: widget.lng!,
          destinationName: name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Place Details')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text('Error: $error'))
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    final name = placeDetail?['displayName']?['text'] ?? 'Unknown';
    final address = placeDetail?['formattedAddress'] ?? 'No address';
    final rating = (placeDetail?['rating'] as num?)?.toDouble();
    final phone = placeDetail?['internationalPhoneNumber'];
    final website = placeDetail?['websiteUri'];
    final isOpen = placeDetail?['regularOpeningHours']?['openNow'];
    final photos = placeDetail?['photos'] as List?;

    final List<String> types = (placeDetail?['types'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    String? firstPhotoUrl;
    if (photos != null && photos.isNotEmpty) {
      firstPhotoUrl = PlacesApiService.buildPhotoUrl(
        photos[0]['name'],
        maxWidth: 400,
      );
    }

    List<String> photoUrls = [];
    if (photos != null && photos.isNotEmpty) {
      for (var photo in photos) {
        photoUrls.add(PlacesApiService.buildPhotoUrl(photo['name'], maxWidth: 800));
      }
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPhotoCarousel(photoUrls),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + Favourite button + Rating
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Row(
                      children: [
                        FavouriteButton(
                          placeId: widget.placeId,
                          name: name,
                          address: address,
                          rating: rating,
                          photoUrl: firstPhotoUrl,
                          lat: widget.lat,
                          lng: widget.lng,
                          types: types,
                          iconSize: 26,
                          activeColor: Colors.red,
                          inactiveColor: Colors.grey,
                          showBackground: false,
                        ),
                        if (rating != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange[50],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.star, color: Colors.orange, size: 18),
                                const SizedBox(width: 4),
                                Text(
                                  rating.toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, color: Colors.orange),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                if (isOpen != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isOpen ? Colors.green[50] : Colors.red[50],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isOpen ? "● Open Now" : "○ Closed",
                      style: TextStyle(
                        color: isOpen ? Colors.green[700] : Colors.red[700],
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),

                const SizedBox(height: 20),
                const Divider(),

                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildActionButton(Icons.phone, "Call", phone != null,
                        onTap: phone != null ? () => _launchPhone(phone) : null,
                      ),
                      _buildActionButton(Icons.public, "Website", website != null,
                        onTap: website != null ? () => _launchWebsite(website) : null,
                      ),
                      _buildActionButton(
                        Icons.directions,
                        "Directions",
                        widget.lat != null && widget.lng != null,
                        onTap: () => _navigateToGuide(name),
                      ),
                      _buildActionButton(Icons.share, "Share", true,
                        onTap: () => _sharePlace(name, address, website),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                const SizedBox(height: 20),

                _buildInfoSection(Icons.location_on, "Address", address),
                if (placeDetail?['regularOpeningHours']?['weekdayDescriptions'] != null)
                  _buildOpeningHours(
                      placeDetail!['regularOpeningHours']['weekdayDescriptions']),
                if (phone != null) _buildInfoSection(Icons.call, "Phone", phone),
                if (website != null) _buildInfoSection(Icons.language, "Website", website),

                const Divider(),
                const SizedBox(height: 10),
                const Text(
                  "Reviews",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                if (placeDetail?['reviews'] != null)
                  ...((placeDetail!['reviews'] as List).map((r) => _buildReviewItem(r)))
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text("No reviews yet", style: TextStyle(color: Colors.grey)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoCarousel(List<String> photoUrls) {
    if (photoUrls.isEmpty) {
      return Container(
        height: 250,
        color: Colors.grey[200],
        child: const Icon(Icons.image, size: 50),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startAutoPlay(photoUrls.length);
    });

    return Stack(
      children: [
        SizedBox(
          height: 250,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) _isUserInteracting = true;
              if (notification is ScrollEndNotification) _isUserInteracting = false;
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              itemCount: photoUrls.length,
              physics: const PageScrollPhysics(),
              onPageChanged: (index) => setState(() => _currentPhotoIndex = index),
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () => _showFullScreenPhoto(context, photoUrls, index),
                  child: Container(
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: NetworkImage(photoUrls[index]),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (photoUrls.length > 1)
          Positioned(
            bottom: 15,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(photoUrls.length, (index) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: _currentPhotoIndex == index ? 10 : 8,
                  height: _currentPhotoIndex == index ? 10 : 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _currentPhotoIndex == index
                        ? Colors.white
                        : Colors.white.withOpacity(0.4),
                  ),
                );
              }),
            ),
          ),
        if (photoUrls.length > 1)
          Positioned(
            top: 15,
            right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                '${_currentPhotoIndex + 1}/${photoUrls.length}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  void _showFullScreenPhoto(BuildContext context, List<String> photoUrls, int initialIndex) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: PageView.builder(
          controller: PageController(initialPage: initialIndex),
          itemCount: photoUrls.length,
          itemBuilder: (context, index) => InteractiveViewer(
            child: Center(child: Image.network(photoUrls[index], fit: BoxFit.contain)),
          ),
        ),
      ),
    ));
  }

  Widget _buildActionButton(IconData icon, String label, bool isAvailable,
      {VoidCallback? onTap}) {
    return Opacity(
      opacity: isAvailable ? 1.0 : 0.3,
      child: InkWell(
        onTap: isAvailable ? onTap : null,
        borderRadius: BorderRadius.circular(30),
        child: Column(
          children: [
            CircleAvatar(
              backgroundColor: Colors.blue[50],
              child: Icon(icon, color: Colors.blue[600]),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoSection(IconData icon, String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.grey[600], size: 20),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                const SizedBox(height: 4),
                Text(content, style: const TextStyle(fontSize: 15, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpeningHours(List<dynamic> weekdayDescriptions) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.access_time_filled, color: Colors.grey[600], size: 20),
          const SizedBox(width: 15),
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: const Text("Opening Hours",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 10),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: weekdayDescriptions.map((desc) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(desc.toString(),
                        style: TextStyle(color: Colors.grey[700], fontSize: 14)),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewItem(Map<String, dynamic> review) {
    final authorName = review['authorAttribution']?['displayName'] ?? 'Anonymous';
    final photoUrl = review['authorAttribution']?['photoUri'];
    final rating = review['rating'] ?? 0;
    final text = review['text']?['text'] ?? '';
    final timeDesc = review['relativePublishTimeDescription'] ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: Colors.blue[100],
                backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
                child: photoUrl == null
                    ? Text(authorName[0], style: const TextStyle(color: Colors.blue))
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(authorName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(timeDesc,
                        style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  ],
                ),
              ),
              Row(
                children: List.generate(5, (index) => Icon(
                  Icons.star,
                  size: 14,
                  color: index < rating ? Colors.orange : Colors.grey[300],
                )),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5),
          ),
        ],
      ),
    );
  }

  Future<void> _launchPhone(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to make a call')),
        );
      }
    }
  }

  Future<void> _launchWebsite(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open website')),
        );
      }
    }
  }

  void _sharePlace(String name, String address, String? website) {
    final text = website != null
        ? 'Check out this place: $name\nAddress: $address\n$website'
        : 'Check out this place: $name\nAddress: $address';
    Share.share(text);
  }
}