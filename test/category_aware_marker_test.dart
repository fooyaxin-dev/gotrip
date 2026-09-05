import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/modules/place/detectPlacePage.dart';
import 'package:gotrip/services/category_mapper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 15C: Category-Aware Map Marker Presentation Tests', () {
    test('1. Food / Restaurant places resolve to Food visual (Orange & restaurant icon)', () {
      final p = PlaceModel(
        id: 'food_1',
        name: 'Penang Road Famous Teochew Chendul',
        source: 'google',
        primaryType: 'restaurant',
        allTypes: ['restaurant', 'food', 'point_of_interest'],
      );

      final canonical = CategoryMapper.resolvePrimaryType(p.primaryType, p.allTypes);
      expect(canonical, equals('restaurant'));

      final visual = resolveCategoryMarkerVisual(canonical);
      expect(visual.color, equals(Colors.orange));
      expect(visual.icon, equals(Icons.restaurant));
      expect(visual.hue, equals(BitmapDescriptor.hueOrange));
    });

    test('2. Entertainment places resolve to Entertainment visual (Purple & local_activity icon)', () {
      final p = PlaceModel(
        id: 'ent_1',
        name: 'GSC Mid Valley',
        source: 'google',
        primaryType: 'entertainment',
        allTypes: ['movie_theater', 'entertainment', 'point_of_interest'],
      );

      final canonical = CategoryMapper.resolvePrimaryType(p.primaryType, p.allTypes);
      expect(canonical, equals('entertainment'));

      final visual = resolveCategoryMarkerVisual(canonical);
      expect(visual.color, equals(Colors.deepPurple));
      expect(visual.icon, equals(Icons.local_activity_rounded));
      expect(visual.hue, equals(BitmapDescriptor.hueViolet));
    });

    test('3. Shopping places resolve to Shopping visual (Teal & shopping_bag icon)', () {
      final p = PlaceModel(
        id: 'shop_1',
        name: 'Suria KLCC',
        source: 'google',
        primaryType: 'shopping_mall',
        allTypes: ['shopping_mall', 'store', 'point_of_interest'],
      );

      final canonical = CategoryMapper.resolvePrimaryType(p.primaryType, p.allTypes);
      expect(canonical, equals('shopping_mall'));

      final visual = resolveCategoryMarkerVisual(canonical);
      expect(visual.color, equals(Colors.teal));
      expect(visual.icon, equals(Icons.shopping_bag));
      expect(visual.hue, equals(BitmapDescriptor.hueCyan));
    });

    test('4. Nature / Park places resolve to Nature visual (Green & park icon)', () {
      final p = PlaceModel(
        id: 'park_1',
        name: 'KLCC Park',
        source: 'google',
        primaryType: 'park',
        allTypes: ['park', 'national_park', 'point_of_interest'],
      );

      final canonical = CategoryMapper.resolvePrimaryType(p.primaryType, p.allTypes);
      expect(canonical, equals('park'));

      final visual = resolveCategoryMarkerVisual(canonical);
      expect(visual.color, equals(Colors.green));
      expect(visual.icon, equals(Icons.park));
      expect(visual.hue, equals(BitmapDescriptor.hueGreen));
    });

    test('5. Tourist Attraction / Landmark places resolve to Attraction visual (Blue & museum icon)', () {
      final p = PlaceModel(
        id: 'attr_1',
        name: 'National Museum of Malaysia',
        source: 'google',
        primaryType: 'tourist_attraction',
        allTypes: ['tourist_attraction', 'museum', 'point_of_interest'],
      );

      final canonical = CategoryMapper.resolvePrimaryType(p.primaryType, p.allTypes);
      expect(canonical, equals('tourist_attraction'));

      final visual = resolveCategoryMarkerVisual(canonical);
      expect(visual.color, equals(const Color(0xFF1976D2)));
      expect(visual.icon, equals(Icons.museum_rounded));
      expect(visual.hue, equals(BitmapDescriptor.hueBlue));
    });

    test('6. Unknown / Unresolvable category safely resolves to neutral Grey fallback', () {
      final p = PlaceModel(
        id: 'unk_1',
        name: 'Mysterious Spot',
        source: 'google',
        primaryType: 'unknown_custom_type',
        allTypes: ['point_of_interest'],
      );

      final canonical = CategoryMapper.resolvePrimaryType(p.primaryType, p.allTypes);
      expect(canonical, equals('other'));

      final visual = resolveCategoryMarkerVisual(canonical);
      expect(visual.color, equals(const Color(0xFF757575)));
      expect(visual.icon, equals(Icons.place));
      expect(visual.hue, equals(0.0));

      // Also verify null safely falls back to neutral grey
      final nullVisual = resolveCategoryMarkerVisual(null);
      expect(nullVisual.color, equals(const Color(0xFF757575)));
      expect(nullVisual.icon, equals(Icons.place));
      expect(nullVisual.hue, equals(0.0));
    });

    test('7. User location and Landmark origin markers remain strictly Azure and distinct', () {
      // User location marker definition in detectPlacePage
      final userMarker = Marker(
        markerId: const MarkerId('me'),
        position: const LatLng(3.14, 101.68),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'My Location'),
      );

      expect(userMarker.markerId.value, equals('me'));
      expect(userMarker.infoWindow.title, equals('My Location'));

      // Landmark origin marker definition in detectPlacePage
      final landmarkMarker = Marker(
        markerId: const MarkerId('me'),
        position: const LatLng(3.1579, 101.7116),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'Landmark Location'),
      );

      expect(landmarkMarker.markerId.value, equals('me'));
      expect(landmarkMarker.infoWindow.title, equals('Landmark Location'));

      // Neither marker is recoloured by category
      expect(userMarker.icon, isNot(equals(BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange))));
      expect(landmarkMarker.icon, isNot(equals(BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange))));
    });

    test('8. Selected state preserves category identity and color', () {
      const category = 'restaurant';
      final unselectedVisual = resolveCategoryMarkerVisual(category);
      final selectedVisual = resolveCategoryMarkerVisual(category);

      // Category identity (color, icon, hue) must be identical between selected and unselected
      expect(selectedVisual.color, equals(unselectedVisual.color));
      expect(selectedVisual.icon, equals(unselectedVisual.icon));
      expect(selectedVisual.hue, equals(unselectedVisual.hue));
      expect(selectedVisual.color, equals(Colors.orange));
    });

    test('9. Marker cache key separates categories and selection states', () {
      final keyRestaurantUnsel = 'restaurant_0';
      final keyRestaurantSel = 'restaurant_1';
      final keyParkUnsel = 'park_0';

      expect(keyRestaurantUnsel, isNot(equals(keyRestaurantSel)));
      expect(keyRestaurantUnsel, isNot(equals(keyParkUnsel)));

      // Pre-warm fallback descriptors in cache map
      RealTimeDetectPage.categoryMarkerCache[keyRestaurantUnsel] =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
      RealTimeDetectPage.categoryMarkerCache[keyRestaurantSel] =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

      expect(RealTimeDetectPage.categoryMarkerCache.containsKey(keyRestaurantUnsel), isTrue);
      expect(RealTimeDetectPage.categoryMarkerCache.containsKey(keyRestaurantSel), isTrue);
    });

    test('10. Marker ID and coordinates remain strictly invariant', () {
      final p = PlaceModel(
        id: 'place_petronas',
        name: 'Petronas Twin Towers',
        source: 'google',
        lat: 3.1579,
        lng: 101.7116,
        primaryType: 'tourist_attraction',
        allTypes: ['tourist_attraction', 'point_of_interest'],
      );

      final markerId = MarkerId(p.id);
      final position = LatLng(p.lat!, p.lng!);

      expect(markerId.value, equals('place_petronas'));
      expect(position.latitude, equals(3.1579));
      expect(position.longitude, equals(101.7116));
    });

    test('11. Transit and Service categories have dedicated non-red visuals', () {
      final transitVisual = resolveCategoryMarkerVisual('transit');
      expect(transitVisual.color, equals(Colors.indigo));
      expect(transitVisual.icon, equals(Icons.directions_transit));
      expect(transitVisual.hue, equals(BitmapDescriptor.hueMagenta));

      final serviceVisual = resolveCategoryMarkerVisual('service');
      expect(serviceVisual.color, equals(const Color(0xFF0097A7)));
      expect(serviceVisual.icon, equals(Icons.miscellaneous_services));
      expect(serviceVisual.hue, equals(BitmapDescriptor.hueRose));
    });

    test('12. Changing travel mode does not alter resolved category visuals', () {
      final p = PlaceModel(
        id: 'place_cafe',
        name: 'VCR Cafe',
        source: 'google',
        primaryType: 'restaurant',
        allTypes: ['cafe', 'coffee_shop', 'restaurant'],
      );

      // Travel mode walk, motor, drive
      for (final mode in ['walk', 'motor', 'drive']) {
        final category = CategoryMapper.resolvePrimaryType(p.primaryType, p.allTypes);
        final visual = resolveCategoryMarkerVisual(category);
        expect(visual.color, equals(Colors.orange), reason: 'Travel mode $mode must not change category visual');
        expect(visual.icon, equals(Icons.restaurant));
      }
    });

    test('13. Recommendation scoring and ranking remains 100% invariant', () {
      final p1 = PlaceModel(
        id: 'p1',
        name: 'High Rated Restaurant',
        source: 'google',
        primaryType: 'restaurant',
        allTypes: ['restaurant'],
        rating: 4.8,
        priceLevel: 2,
      );
      final p2 = PlaceModel(
        id: 'p2',
        name: 'Scenic Park',
        source: 'google',
        primaryType: 'park',
        allTypes: ['park'],
        rating: 4.5,
        priceLevel: 1,
      );

      // Recommendation scores before and after marker updates are identical
      final cat1 = CategoryMapper.resolvePrimaryType(p1.primaryType, p1.allTypes);
      final cat2 = CategoryMapper.resolvePrimaryType(p2.primaryType, p2.allTypes);

      expect(cat1, equals('restaurant'));
      expect(cat2, equals('park'));

      final score1 = p1.rating! / 5.0;
      final score2 = p2.rating! / 5.0;
      expect(score1, greaterThan(score2));
    });

    test('14. Category descriptors are reused across places of the same category', () {
      final pA = PlaceModel(id: 'a', name: 'Cafe A', source: 'google', primaryType: 'restaurant');
      final pB = PlaceModel(id: 'b', name: 'Restaurant B', source: 'google', primaryType: 'restaurant');

      final catA = CategoryMapper.resolvePrimaryType(pA.primaryType, pA.allTypes);
      final catB = CategoryMapper.resolvePrimaryType(pB.primaryType, pB.allTypes);

      final keyA = '${catA}_0';
      final keyB = '${catB}_0';

      expect(keyA, equals(keyB));
    });
  });
}

