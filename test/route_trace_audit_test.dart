import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/itineraryModel.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/modules/place/routeOptimizerPage.dart';
import 'package:gotrip/services/route_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Task 14A Route Order and Map Synchronization Trace Audit',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 4 stops in George Town in a specific geographical layout
    // Stop 1: Fort Cornwallis (North East) - (5.4204, 100.3438)
    // Stop 2: Penang State Museum (Far West) - (5.4215, 100.3385)
    // Stop 3: Khoo Kongsi (South West) - (5.4148, 100.3372)
    // Stop 4: Chew Jetty (South East) - (5.4129, 100.3398)

    final testPlaces = [
      ItineraryPlace(
        placeId: 'stop_1_fort_cornwallis',
        name: 'Fort Cornwallis',
        address: 'Jalan Tun Syed Sheh Barakbah, George Town',
        lat: 5.4204,
        lng: 100.3438,
        primaryType: 'tourist_attraction',
        suggestedTime: '09:00',
        durationMinutes: 90,
      ),
      ItineraryPlace(
        placeId: 'stop_2_state_museum',
        name: 'Penang State Museum',
        address: 'Farquhar Street, George Town',
        lat: 5.4215,
        lng: 100.3385,
        primaryType: 'tourist_attraction',
        suggestedTime: '11:00',
        durationMinutes: 60,
      ),
      ItineraryPlace(
        placeId: 'stop_3_khoo_kongsi',
        name: 'Khoo Kongsi',
        address: 'Cannon Square, George Town',
        lat: 5.4148,
        lng: 100.3372,
        primaryType: 'tourist_attraction',
        suggestedTime: '13:00',
        durationMinutes: 60,
      ),
      ItineraryPlace(
        placeId: 'stop_4_chew_jetty',
        name: 'Chew Jetty',
        address: 'Weld Quay, George Town',
        lat: 5.4129,
        lng: 100.3398,
        primaryType: 'tourist_attraction',
        suggestedTime: '15:00',
        durationMinutes: 60,
      ),
    ];

    final testItinerary = ItineraryModel(
      id: 'test_itin_14a',
      title: 'George Town Cultural Heritage',
      startDate: '2026-09-02',
      totalDays: 1,
      createdAt: DateTime(2026, 9, 2),
      isOriginCurrentLocation: true,
      originLat: 5.4164,
      originLng: 100.3327,
      originName: 'Komtar George Town',
      travelMode: 'walk',
      days: [
        ItineraryDay(
          dayNumber: 1,
          date: '2026-09-02',
          places: testPlaces,
        ),
      ],
      leftoverPlaces: [
        PlaceModel(
          id: 'leftover_daddy_cafe',
          name: 'Daddy Cafe',
          address: 'Beach Rd',
          primaryType: 'restaurant',
          lat: 5.4170,
          lng: 100.3350,
          source: 'google',
        ),
      ],
    );

    // Build RouteOptimizerPage in test
    await tester.pumpWidget(
      MaterialApp(
        home: RouteOptimizerPage(
          itinerary: testItinerary,
          startLat: 5.4164,
          startLng: 100.3327,
          startLocationName: 'Komtar George Town',
          travelMode: TravelMode.walk,
          leftoverCandidates: const [],
          preserveGeneratedSchedule: true,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify page rendered
    expect(find.byType(RouteOptimizerPage), findsOneWidget);

    // Tap Day 1 tab to trigger single-day view and overlay traces
    final day1Tab = find.text('Day 1');
    if (day1Tab.evaluate().isNotEmpty) {
      await tester.tap(day1Tab.first);
      await tester.pumpAndSettle();
    }

    // Tap Re-optimize button to trace optimizer execution and order synchronization
    final reOptimizeBtn = find.text('Re-optimize');
    if (reOptimizeBtn.evaluate().isNotEmpty) {
      await tester.tap(reOptimizeBtn.first);
      await tester.pumpAndSettle();
    }

    expect(find.text('Fort Cornwallis'), findsWidgets);
    expect(find.text('Penang State Museum'), findsWidgets);
    expect(find.text('Khoo Kongsi'), findsWidgets);
    expect(find.text('Chew Jetty'), findsWidgets);
  });
}
