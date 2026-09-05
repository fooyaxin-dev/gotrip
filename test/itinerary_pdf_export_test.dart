// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:file/file.dart' as pkg_file;
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/models/itineraryModel.dart';
import 'package:gotrip/models/placeModel.dart';
import 'package:gotrip/modules/itinerary/itineraryDetail.dart';
import 'package:gotrip/services/itinerary_pdf_service.dart';
import 'package:pdf/widgets.dart' as pw;

class FakeDiskCacheManager implements BaseCacheManager {
  final Map<String, pkg_file.File> files;
  final Set<String> requestedUrls = {};
  int lookupCount = 0;
  final bool shouldThrow;

  FakeDiskCacheManager({
    this.files = const {},
    this.shouldThrow = false,
  });

  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    requestedUrls.add(key);
    lookupCount++;
    if (shouldThrow) {
      throw const io.FileSystemException('Disk lookup failure');
    }
    final file = files[key];
    if (file == null) return null;
    return FileInfo(file, FileSource.Cache, DateTime.now(), key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 1-pixel transparent PNG bytes for testing image embedding
  final dummyPngBytes = Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  late io.Directory tempTestDir;

  setUpAll(() {
    tempTestDir = io.Directory.systemTemp.createTempSync('gotrip_pdf_test_');
  });

  tearDownAll(() {
    if (tempTestDir.existsSync()) {
      tempTestDir.deleteSync(recursive: true);
    }
  });

  ItineraryPlace createPlace({
    required String id,
    required String name,
    required String suggestedTime,
    int durationMinutes = 60,
    String address = '123 Test Street, City',
    double? lat = 5.4164,
    double? lng = 100.3327,
    String? primaryType = 'tourist_attraction',
    List<String> allTypes = const ['tourist_attraction', 'point_of_interest'],
    double? rating = 4.5,
    int? userRatingCount = 100,
    String? phoneNumber = '+60123456789',
    String? website = 'https://gotrip.example.com',
    String? description = 'A wonderful cultural destination.',
    String? notes = 'Visit in the morning.',
    String? photoUrl,
    bool isVisited = false,
    List<OpeningHoursPeriod>? openingPeriods,
  }) {
    return ItineraryPlace(
      placeId: id,
      name: name,
      address: address,
      lat: lat,
      lng: lng,
      primaryType: primaryType,
      allTypes: allTypes,
      suggestedTime: suggestedTime,
      durationMinutes: durationMinutes,
      rating: rating,
      userRatingCount: userRatingCount,
      phoneNumber: phoneNumber,
      website: website,
      description: description,
      notes: notes,
      photoUrl: photoUrl,
      isVisited: isVisited,
      regularOpeningPeriods: openingPeriods,
    );
  }

  ItineraryModel createItinerary({
    required String title,
    required List<ItineraryDay> days,
    String travelMode = 'walk',
    String? originName = 'Georgetown, Penang',
    double? originLat = 5.4141,
    double? originLng = 100.3288,
    List<PlaceModel> leftoverPlaces = const [],
    List<String> leftoverPlaceIds = const [],
  }) {
    return ItineraryModel(
      id: 'itin_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      startDate: '2026-09-04',
      totalDays: days.length,
      days: days,
      createdAt: DateTime(2026, 9, 1),
      isOriginCurrentLocation: false,
      originName: originName,
      originLat: originLat,
      originLng: originLng,
      travelMode: travelMode,
      leftoverPlaces: leftoverPlaces,
      leftoverPlaceIds: leftoverPlaceIds,
    );
  }

  group('Itinerary PDF Export - Unit & Content Verification Tests', () {
    test(
        'Filename sanitization works for simple, complex, and malicious titles',
        () {
      expect(
        ItineraryPdfService.sanitizeFilename('Penang Vacation 2026'),
        equals('Penang_Vacation_2026_Itinerary.pdf'),
      );

      // Slashes, path traversal, colons, quotes
      expect(
        ItineraryPdfService.sanitizeFilename('../../../etc/passwd : "Trip"?'),
        equals('etc_passwd_Trip_Itinerary.pdf'),
      );

      // Multiple consecutive symbols and spaces
      expect(
        ItineraryPdfService.sanitizeFilename('  Tokyo  //  Japan *** <Best>  '),
        equals('Tokyo_Japan_Best_Itinerary.pdf'),
      );

      // Empty or symbols only
      expect(
        ItineraryPdfService.sanitizeFilename('   '),
        equals('Itinerary_Itinerary.pdf'),
      );

      expect(
        ItineraryPdfService.sanitizeFilename(':::***???'),
        equals('Itinerary_Itinerary.pdf'),
      );

      // Long titles (> 50 chars) are capped safely
      final veryLong = 'A' * 100;
      final sanitizedLong = ItineraryPdfService.sanitizeFilename(veryLong);
      expect(sanitizedLong.startsWith('A'), isTrue);
      expect(sanitizedLong.endsWith('_Itinerary.pdf'), isTrue);
      expect(sanitizedLong.length, lessThanOrEqualTo(70));
    });

    test(
        '1. A saved system-generated itinerary with all places unvisited can export',
        () async {
      final days = [
        ItineraryDay(
          dayNumber: 1,
          date: '2026-09-04',
          places: [
            createPlace(
              id: 'sys_p1',
              name: 'Penang Hill',
              suggestedTime: '09:00',
              notes: 'AI generated: Best morning view',
              isVisited: false,
            ),
            createPlace(
              id: 'sys_p2',
              name: 'Kek Lok Si Temple',
              suggestedTime: '11:00',
              notes: 'AI generated: Largest Buddhist temple',
              isVisited: false,
            ),
          ],
        ),
      ];

      final systemItinerary = createItinerary(
        title: 'System Generated 1-Day Trip',
        days: days,
        originName: 'System Start Point',
      );

      expect(systemItinerary.isCompleted, isFalse);
      expect(systemItinerary.totalVisited, equals(0));
      expect(systemItinerary.totalPlaces, equals(2));

      final service = ItineraryPdfService();
      final doc = await service.buildDocument(systemItinerary);
      final bytes = await service.generatePdf(systemItinerary);

      expect(bytes.isNotEmpty, isTrue);
      expect(String.fromCharCodes(bytes.sublist(0, 5)), equals('%PDF-'));
      expect(doc.document.pdfPageList.pages.isNotEmpty, isTrue);
    });

    test(
        '2. A saved user-generated itinerary with all places unvisited can export',
        () async {
      final days = [
        ItineraryDay(
          dayNumber: 1,
          date: '2026-09-04',
          places: [
            createPlace(
              id: 'user_p1',
              name: 'Clan Jetties',
              suggestedTime: '10:00',
              notes: 'User custom note: Meet friend here',
              isVisited: false,
            ),
          ],
        ),
        ItineraryDay(
          dayNumber: 2,
          date: '2026-09-05',
          places: [
            createPlace(
              id: 'user_p2',
              name: 'Cheong Fatt Tze Mansion',
              suggestedTime: '14:00',
              notes: 'User custom note: Booked guided tour',
              isVisited: false,
            ),
          ],
        ),
      ];

      final userItinerary = createItinerary(
        title: 'My Custom Penang Trip',
        days: days,
        originName: 'Hotel Jen George Town',
      );

      expect(userItinerary.isCompleted, isFalse);
      expect(userItinerary.totalVisited, equals(0));
      expect(userItinerary.totalPlaces, equals(2));

      final service = ItineraryPdfService();
      final bytes = await service.generatePdf(userItinerary);

      expect(bytes.isNotEmpty, isTrue);
      expect(String.fromCharCodes(bytes.sublist(0, 5)), equals('%PDF-'));
    });

    test('3. A completed itinerary can export', () async {
      final days = [
        ItineraryDay(
          dayNumber: 1,
          date: '2026-09-04',
          places: [
            createPlace(
              id: 'comp_p1',
              name: 'Fort Cornwallis',
              suggestedTime: '09:00',
              isVisited: true,
            ),
            createPlace(
              id: 'comp_p2',
              name: 'State Museum',
              suggestedTime: '11:00',
              isVisited: true,
            ),
          ],
        ),
      ];

      final completedItinerary = createItinerary(
        title: 'Completed Tour',
        days: days,
      );

      expect(completedItinerary.isCompleted, isTrue);
      expect(completedItinerary.totalVisited, equals(2));

      final service = ItineraryPdfService();
      final bytes = await service.generatePdf(completedItinerary);

      expect(bytes.isNotEmpty, isTrue);
      expect(String.fromCharCodes(bytes.sublist(0, 5)), equals('%PDF-'));
    });

    test('4. Export eligibility does not depend on isCompleted', () async {
      // Both an incomplete itinerary (0/2 visited) and completed itinerary (2/2 visited)
      // produce valid PDF documents through the exact same pipeline.
      final incompleteDay = ItineraryDay(
        dayNumber: 1,
        date: '2026-09-04',
        places: [
          createPlace(
              id: 'p1',
              name: 'Stop 1',
              suggestedTime: '09:00',
              isVisited: false),
          createPlace(
              id: 'p2',
              name: 'Stop 2',
              suggestedTime: '10:00',
              isVisited: false),
        ],
      );
      final completeDay = ItineraryDay(
        dayNumber: 1,
        date: '2026-09-04',
        places: [
          createPlace(
              id: 'p1',
              name: 'Stop 1',
              suggestedTime: '09:00',
              isVisited: true),
          createPlace(
              id: 'p2',
              name: 'Stop 2',
              suggestedTime: '10:00',
              isVisited: true),
        ],
      );

      final itinIncomplete =
          createItinerary(title: 'Incomplete', days: [incompleteDay]);
      final itinComplete =
          createItinerary(title: 'Complete', days: [completeDay]);

      expect(itinIncomplete.isCompleted, isFalse);
      expect(itinComplete.isCompleted, isTrue);

      final service = ItineraryPdfService();
      final bytesIncomplete = await service.generatePdf(itinIncomplete);
      final bytesComplete = await service.generatePdf(itinComplete);

      expect(bytesIncomplete.length, greaterThan(1000));
      expect(bytesComplete.length, greaterThan(1000));
    });

    test(
        '5. Export preserves all days and saved place order (Model & Content Verification)',
        () async {
      final p1 =
          createPlace(id: 'ord_1', name: 'Alpha Place', suggestedTime: '08:30');
      final p2 =
          createPlace(id: 'ord_2', name: 'Beta Place', suggestedTime: '10:00');
      final p3 =
          createPlace(id: 'ord_3', name: 'Gamma Place', suggestedTime: '13:00');
      final p4 =
          createPlace(id: 'ord_4', name: 'Delta Place', suggestedTime: '15:30');

      final days = [
        ItineraryDay(dayNumber: 1, date: '2026-09-04', places: [p1, p2]),
        ItineraryDay(dayNumber: 2, date: '2026-09-05', places: [p3, p4]),
      ];

      final itinerary = createItinerary(title: 'Ordering Test', days: days);

      // Model verification of ordered extraction
      final extractedPlaces =
          ItineraryPdfService.extractOrderedPlaces(itinerary);
      expect(extractedPlaces.length, equals(4));
      expect(extractedPlaces[0].placeId, equals('ord_1'));
      expect(extractedPlaces[1].placeId, equals('ord_2'));
      expect(extractedPlaces[2].placeId, equals('ord_3'));
      expect(extractedPlaces[3].placeId, equals('ord_4'));

      expect(extractedPlaces[0].name, equals('Alpha Place'));
      expect(extractedPlaces[1].name, equals('Beta Place'));
      expect(extractedPlaces[2].name, equals('Gamma Place'));
      expect(extractedPlaces[3].name, equals('Delta Place'));

      final service = ItineraryPdfService();
      final bytes = await service.generatePdf(itinerary);
      expect(bytes.isNotEmpty, isTrue);
    });

    test(
        '6. A 7-day x 6-place saved itinerary provides all 42 places exactly once to the production PDF builder (Content + Layout)',
        () async {
      final days = <ItineraryDay>[];
      int placeCounter = 0;

      for (int d = 1; d <= 7; d++) {
        final places = <ItineraryPlace>[];
        for (int p = 1; p <= 6; p++) {
          placeCounter++;
          places.add(
            createPlace(
              id: 'place_$placeCounter',
              name: 'Day $d Stop $p - Place $placeCounter',
              suggestedTime: '${(8 + p).toString().padLeft(2, '0')}:00',
              durationMinutes: 45,
              address: '$placeCounter Street, District $d',
              isVisited: false, // Unvisited
            ),
          );
        }
        days.add(
          ItineraryDay(
            dayNumber: d,
            date: '2026-09-0$d',
            places: places,
            legsData: List.generate(
              6,
              (idx) => {'distance': 1000.0, 'minutes': 12},
            ),
          ),
        );
      }

      final itinerary = createItinerary(title: '7-Day Grand Tour', days: days);
      expect(itinerary.totalPlaces, equals(42));
      expect(itinerary.isCompleted, isFalse);

      // Model / Content verification:
      final ordered = ItineraryPdfService.extractOrderedPlaces(itinerary);
      expect(ordered.length, equals(42));

      final seenIds = <String>{};
      for (int i = 0; i < 42; i++) {
        final expectedId = 'place_${i + 1}';
        expect(ordered[i].placeId, equals(expectedId));
        expect(seenIds.add(ordered[i].placeId), isTrue); // exactly once
      }

      // Visual Layout verification:
      final service = ItineraryPdfService();
      final doc = await service.buildDocument(itinerary);
      final bytes = await doc.save();

      expect(bytes.length, greaterThan(5000));
      expect(doc.document.pdfPageList.pages.length, greaterThan(1));
    });

    test(
        '7. Export does not mutate the original itinerary (Immutability Verification)',
        () async {
      final place = createPlace(
        id: 'immut_1',
        name: 'Original Place Name',
        suggestedTime: '09:00',
        durationMinutes: 60,
        address: '100 Main St',
        notes: 'Original note',
        isVisited: false,
      );

      final day = ItineraryDay(
        dayNumber: 1,
        date: '2026-09-04',
        places: [place],
      );

      final itinerary = createItinerary(
        title: 'Immutable Trip',
        days: [day],
      );

      // Deep serialize before export
      final beforeJson =
          jsonEncode(itinerary.toMap(), toEncodable: (o) => o.toString());

      final service = ItineraryPdfService(
        exportHandler: (itin) async => '/tmp/dummy.pdf',
      );

      await service.generatePdf(itinerary);
      await service.exportAndShareItinerary(itinerary);

      // Deep serialize after export
      final afterJson =
          jsonEncode(itinerary.toMap(), toEncodable: (o) => o.toString());

      expect(afterJson, equals(beforeJson));
      expect(itinerary.days[0].places[0].isVisited, isFalse);
      expect(itinerary.days[0].places[0].name, equals('Original Place Name'));
      expect(itinerary.days[0].places[0].notes, equals('Original note'));
    });

    test(
        '8. Missing optional place details do not crash generation and handle null gracefully',
        () async {
      final minimalPlace = ItineraryPlace(
        placeId: 'min_1',
        name: 'Mystery Point',
        address: '',
        suggestedTime: '',
        durationMinutes: 45,
        lat: null,
        lng: null,
        primaryType: null,
        allTypes: const [],
        rating: null,
        userRatingCount: null,
        phoneNumber: null,
        website: null,
        description: null,
        notes: null,
        photoUrl: null,
        isVisited: false,
        regularOpeningPeriods: null,
      );

      final day = ItineraryDay(
        dayNumber: 1,
        date: '',
        places: [minimalPlace],
        legsData: null,
      );

      final itinerary = createItinerary(
        title: 'Minimal Data Trip',
        days: [day],
        originName: null,
        originLat: null,
        originLng: null,
      );

      final service = ItineraryPdfService();
      final bytes = await service.generatePdf(itinerary);

      expect(bytes.isNotEmpty, isTrue);
      expect(String.fromCharCodes(bytes.sublist(0, 5)), equals('%PDF-'));
    });

    test(
        '9. Long place names and addresses wrap without crashing or losing subsequent entries',
        () async {
      final longName = 'Very ' * 50 + 'Long Place Name';
      final longAddress = 'Street Name ' * 60 + 'Jalan Example';
      final longDescription = 'Historic description sentence. ' * 40;

      final p1 = createPlace(
        id: 'long_1',
        name: longName,
        address: longAddress,
        description: longDescription,
        suggestedTime: '08:00',
      );
      final p2 = createPlace(
        id: 'normal_2',
        name: 'Subsequent Destination',
        address: '456 Second Road',
        suggestedTime: '10:00',
      );

      final day = ItineraryDay(
        dayNumber: 1,
        date: '2026-09-04',
        places: [p1, p2],
      );

      final itinerary =
          createItinerary(title: 'Text Wrapping Trip', days: [day]);
      final service = ItineraryPdfService();
      final bytes = await service.generatePdf(itinerary);

      expect(bytes.isNotEmpty, isTrue);
      expect(String.fromCharCodes(bytes.sublist(0, 5)), equals('%PDF-'));
    });

    test(
        '10. Production PlaceModel -> ItineraryPlace -> toMap -> fromMap -> PDF export content model preserves all available details',
        () async {
      // Genuinely populated PlaceModel from production Places API representation
      final placeModel = PlaceModel(
        id: 'place_penang_hill',
        name: 'Penang Hill Railway',
        address: 'Jalan Stesen, 11500 Ayer Itam, Pulau Pinang',
        lat: 5.4085,
        lng: 100.2771,
        rating: 4.6,
        userRatingCount: 4210,
        photoUrl: 'https://lh3.googleusercontent.com/p/penang_hill.jpg',
        source: 'google',
        primaryType: 'tourist_attraction',
        allTypes: const ['tourist_attraction', 'point_of_interest'],
        regularOpeningPeriods: const [
          OpeningHoursPeriod(
            open: OpeningHoursPoint(day: 1, hour: 6, minute: 30),
            close: OpeningHoursPoint(day: 1, hour: 23, minute: 0),
          ),
        ],
      );

      // Verify fields NOT in PlaceModel remain null
      // (PlaceModel genuinely does not hold phoneNumber, website, description)
      final itinPlace = ItineraryPlace.fromPlaceModel(
        placeModel,
        suggestedTime: '08:30',
        durationMinutes: 120,
        notes: 'Scenic funicular train ride',
      );

      expect(itinPlace.placeId, equals('place_penang_hill'));
      expect(itinPlace.name, equals('Penang Hill Railway'));
      expect(itinPlace.address,
          equals('Jalan Stesen, 11500 Ayer Itam, Pulau Pinang'));
      expect(itinPlace.rating, equals(4.6));
      expect(itinPlace.userRatingCount, equals(4210));
      expect(itinPlace.regularOpeningPeriods?.length, equals(1));
      expect(itinPlace.phoneNumber, isNull);
      expect(itinPlace.website, isNull);
      expect(itinPlace.description, isNull);

      // Verify serialization round-trip: toMap -> fromMap
      final map = itinPlace.toMap();
      final restored = ItineraryPlace.fromMap(map);

      expect(restored.placeId, equals(itinPlace.placeId));
      expect(restored.name, equals(itinPlace.name));
      expect(restored.address, equals(itinPlace.address));
      expect(restored.rating, equals(itinPlace.rating));
      expect(restored.userRatingCount, equals(itinPlace.userRatingCount));
      expect(restored.regularOpeningPeriods?.length,
          equals(itinPlace.regularOpeningPeriods?.length));
      expect(restored.phoneNumber, isNull);
      expect(restored.website, isNull);
      expect(restored.description, isNull);

      // Verify content model extraction in ItineraryPdfService
      final day =
          ItineraryDay(dayNumber: 1, date: '2026-09-04', places: [restored]);
      final itinerary = createItinerary(title: 'Penang Hill Trip', days: [day]);

      final extracted = ItineraryPdfService.extractOrderedPlaces(itinerary);
      expect(extracted.length, equals(1));
      expect(extracted.first.placeId, equals('place_penang_hill'));
      expect(extracted.first.rating, equals(4.6));
      expect(extracted.first.userRatingCount, equals(4210));
    });

    test(
        '11. Both system-generated and user-generated conversion paths preserve the same available metadata',
        () async {
      final sharedPlace = PlaceModel(
        id: 'place_shared',
        name: 'Shared Heritage Mansion',
        address: '12 Beach Street, George Town',
        lat: 5.4180,
        lng: 100.3390,
        rating: 4.8,
        userRatingCount: 950,
        photoUrl: 'https://example.com/shared.jpg',
        source: 'google',
        primaryType: 'historical_landmark',
        allTypes: const ['historical_landmark', 'tourist_attraction'],
        regularOpeningPeriods: const [
          OpeningHoursPeriod(
            open: OpeningHoursPoint(day: 2, hour: 9, minute: 0),
            close: OpeningHoursPoint(day: 2, hour: 17, minute: 0),
          ),
        ],
      );

      // System-generated conversion path
      final systemConverted = ItineraryPlace.fromPlaceModel(
        sharedPlace,
        suggestedTime: '10:00',
        durationMinutes: 90,
        notes: 'Historical mansion tour',
        primaryTypeOverride: 'historical_landmark',
      );

      // User-generated conversion path
      final userConverted = ItineraryPlace.fromPlaceModel(
        sharedPlace,
        suggestedTime: '10:00',
        durationMinutes: 90,
        notes: 'Added by user',
        primaryTypeOverride: 'historical_landmark',
      );

      expect(systemConverted.placeId, equals(userConverted.placeId));
      expect(systemConverted.name, equals(userConverted.name));
      expect(systemConverted.address, equals(userConverted.address));
      expect(systemConverted.rating, equals(userConverted.rating));
      expect(systemConverted.userRatingCount,
          equals(userConverted.userRatingCount));
      expect(systemConverted.regularOpeningPeriods?.length,
          equals(userConverted.regularOpeningPeriods?.length));
      expect(systemConverted.primaryType, equals(userConverted.primaryType));
      expect(systemConverted.allTypes, equals(userConverted.allTypes));
      expect(systemConverted.phoneNumber, isNull);
      expect(userConverted.phoneNumber, isNull);
    });

    test(
        '12. ProductionDiskCacheReader: Cache HIT embeds local bytes, MISS omits photo with zero downloads, ERROR handled safely',
        () async {
      const fs = LocalFileSystem();
      final cachedFile = fs.file('${tempTestDir.path}/cached_image.png');
      cachedFile.writeAsBytesSync(dummyPngBytes);

      final fakeCache = FakeDiskCacheManager(
        files: {
          'https://images.example.com/cached.jpg': cachedFile,
        },
      );

      final cacheReader = ProductionDiskCacheReader(cacheManager: fakeCache);

      // 1. Cache HIT -> returns local bytes
      final hitBytes =
          await cacheReader('https://images.example.com/cached.jpg');
      expect(hitBytes, isNotNull);
      expect(hitBytes!.length, equals(dummyPngBytes.length));

      // 2. Cache MISS -> returns null (never attempts download)
      final missBytes =
          await cacheReader('https://images.example.com/uncached.jpg');
      expect(missBytes, isNull);

      // 3. Cache ERROR -> returns null without throwing
      final errorCache = FakeDiskCacheManager(shouldThrow: true);
      final errorReader = ProductionDiskCacheReader(cacheManager: errorCache);
      final errorBytes =
          await errorReader('https://images.example.com/error.jpg');
      expect(errorBytes, isNull);
    });

    test(
        '13. URL-level deduplication: repeated identical photo URLs trigger exactly one disk cache lookup',
        () async {
      const fs = LocalFileSystem();
      final cachedFile = fs.file('${tempTestDir.path}/shared_photo.png');
      cachedFile.writeAsBytesSync(dummyPngBytes);

      final fakeCache = FakeDiskCacheManager(
        files: {
          'https://images.example.com/repeated.jpg': cachedFile,
        },
      );

      final p1 = createPlace(
        id: 'p_rep1',
        name: 'First Stop',
        suggestedTime: '09:00',
        photoUrl: 'https://images.example.com/repeated.jpg',
      );
      final p2 = createPlace(
        id: 'p_rep2',
        name: 'Second Stop Same Photo',
        suggestedTime: '11:00',
        photoUrl: 'https://images.example.com/repeated.jpg',
      );
      final p3 = createPlace(
        id: 'p_rep3',
        name: 'Third Stop Same Photo',
        suggestedTime: '13:00',
        photoUrl: 'https://images.example.com/repeated.jpg',
      );

      final day =
          ItineraryDay(dayNumber: 1, date: '2026-09-04', places: [p1, p2, p3]);
      final itinerary =
          createItinerary(title: 'Deduplication Trip', days: [day]);

      final service = ItineraryPdfService(
        imageBytesProvider:
            ProductionDiskCacheReader(cacheManager: fakeCache).call,
      );

      final bytes = await service.generatePdf(itinerary);
      expect(bytes.isNotEmpty, isTrue);

      // Verify that across all 3 places, getFileFromCache was invoked exactly ONCE
      expect(fakeCache.lookupCount, equals(1));
      expect(fakeCache.requestedUrls.length, equals(1));
      expect(fakeCache.requestedUrls.first,
          equals('https://images.example.com/repeated.jpg'));
    });

    test(
        '14. Default production ItineraryPdfService is wired to cache-only reader without network dependencies',
        () async {
      expect(ItineraryPdfService.productionCacheImageReader, isNotNull);

      // Verify default singleton uses production cache reader
      final defaultService = ItineraryPdfService();
      expect(defaultService.exportHandler, isNull);
      expect(defaultService.imageBytesProvider,
          isNull); // Falls back to productionCacheImageReader in buildDocument
    });

    test(
        '15. Real local Unicode font: English, Malay and Chinese place names render cleanly with embedded font',
        () async {
      final fontFile = io.File('assets/fonts/NotoSansSC-Regular.ttf');
      expect(fontFile.existsSync(), isTrue,
          reason:
              'Bundled font assets/fonts/NotoSansSC-Regular.ttf must exist on disk');

      final font = pw.Font.ttf(fontFile.readAsBytesSync().buffer.asByteData());
      final service = ItineraryPdfService(
        baseFont: font,
        boldFont: font,
      );

      final pEnglish = createPlace(
        id: 'lang_en',
        name: 'Penang Botanic Gardens & Fort Cornwallis',
        address: 'Pavilion Road, 10350 George Town',
        suggestedTime: '09:00',
      );
      final pMalay = createPlace(
        id: 'lang_ms',
        name: 'Masjid Kapitan Keling & Taman Negara Pulau Pinang',
        address: 'Jalan Masjid Kapitan Keling, 10200 George Town',
        suggestedTime: '11:00',
      );
      final pChinese = createPlace(
        id: 'lang_zh',
        name: '极乐寺 (Kek Lok Si) & 姓周桥 (Chew Jetty)',
        address: '11500 Ayer Itam, Pulau Pinang, 马来西亚',
        suggestedTime: '14:00',
      );

      final day = ItineraryDay(
        dayNumber: 1,
        date: '2026-09-04',
        places: [pEnglish, pMalay, pChinese],
      );

      final itinerary = createItinerary(
        title: 'Multilingual Trip (English, Malay, Chinese)',
        days: [day],
      );

      final doc = await service.buildDocument(itinerary);
      final bytes = await doc.save();

      expect(bytes.isNotEmpty, isTrue);
      expect(String.fromCharCodes(bytes.sublist(0, 5)), equals('%PDF-'));
      expect(doc.document.fonts.isNotEmpty, isTrue,
          reason: 'Generated PDF must contain the embedded font');
    });

    test(
        '16. Font loading failure returns a clear StateError without silently dropping Chinese text',
        () async {
      final serviceWithInvalidFont = ItineraryPdfService(
        fontAssetPath: 'assets/fonts/non_existent_font.ttf',
        fontBytesLoader: (path) async {
          throw const io.FileSystemException('Font file not found on disk');
        },
      );

      expect(
        () => serviceWithInvalidFont.loadBundledFont(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Failed to load bundled offline Unicode font'),
          ),
        ),
      );
    });
  });

  group(
      'Itinerary PDF v1.2.2 Presentation-Only Corrections (Hours/Note, Page Breaks, Bold Place Names)',
      () {
    List<pw.Text> findPdfTexts(pw.Widget widget) {
      final texts = <pw.Text>[];
      void visit(pw.Widget w) {
        if (w is pw.Text) {
          texts.add(w);
        } else if (w is pw.UrlLink && w.child != null) {
          visit(w.child!);
        } else if (w is pw.Container && w.child != null) {
          visit(w.child!);
        } else if (w is pw.Expanded && w.child != null) {
          visit(w.child!);
        } else if (w is pw.Padding && w.child != null) {
          visit(w.child!);
        } else if (w is pw.ClipRRect && w.child != null) {
          visit(w.child!);
        } else if (w is pw.MultiChildWidget) {
          for (final child in w.children) {
            visit(child);
          }
        }
      }

      visit(widget);
      return texts;
    }

    test('1. Hours is not included even when opening-hours data exists',
        () async {
      final pWithHours = createPlace(
        id: 'p_hours',
        name: 'Kek Lok Si Temple',
        suggestedTime: '09:00',
        openingPeriods: const [
          OpeningHoursPeriod(
            open: OpeningHoursPoint(day: 1, hour: 8, minute: 30),
            close: OpeningHoursPoint(day: 1, hour: 17, minute: 30),
          ),
        ],
      );

      final service = ItineraryPdfService();
      final itinerary = createItinerary(
        title: 'Hours Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [pWithHours],
          ),
        ],
      );

      final widgets = await service.buildProductionContentWidgets(itinerary);
      final allTexts = widgets
          .expand((w) => findPdfTexts(w))
          .map((t) => t.text.toPlainText())
          .toList();

      expect(allTexts.any((t) => t.contains('Hours:')), isFalse,
          reason: 'Hours row must be completely removed from every place card');
      expect(
          allTexts.any((t) =>
              t.contains('Open during') ||
              t.contains('Closed during') ||
              t.contains('Hours available')),
          isFalse);
    });

    test(
        '2. Note is included without the leading emoji and rating number (e.g. ⭐ 4.5 · )',
        () async {
      final pWithNote = createPlace(
        id: 'p_note',
        name: 'Chew Jetty Heritage Walk',
        suggestedTime: '09:00',
        notes:
            '⭐ 4.5 · Popular dining spot. Check wait times during peak hours.',
      );

      final service = ItineraryPdfService();
      final itinerary = createItinerary(
        title: 'Note Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [pWithNote],
          ),
        ],
      );

      final widgets = await service.buildProductionContentWidgets(itinerary);
      final allTexts = widgets
          .expand((w) => findPdfTexts(w))
          .map((t) => t.text.toPlainText())
          .toList();

      expect(
          allTexts.any((t) => t.contains(
              'Note: Popular dining spot. Check wait times during peak hours.')),
          isTrue,
          reason: 'Note text must remain present');
      expect(
          allTexts.any((t) => t.contains('⭐') || t.contains('4.5 ·')), isFalse,
          reason: 'Leading emoji and rating number must be stripped from Note');
    });

    test(
        '3. Missing optional fields do not emit Not available, N/A, null or empty labels',
        () async {
      final minimalPlace = ItineraryPlace(
        placeId: 'p_minimal',
        name: 'Minimal Landmark',
        address: '',
        photoUrl: null,
        lat: null,
        lng: null,
        primaryType: null,
        allTypes: const [],
        suggestedTime: '',
        durationMinutes: 0,
        notes: null,
        isVisited: false,
        visitedAt: null,
        regularOpeningPeriods: null,
        rating: null,
        userRatingCount: null,
        phoneNumber: null,
        website: null,
        description: null,
      );

      final service = ItineraryPdfService();
      final itinerary = createItinerary(
        title: 'Minimal Fields Trip',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [minimalPlace],
          ),
        ],
      );

      final widgets = await service.buildProductionContentWidgets(itinerary);
      final allTexts = widgets
          .expand((w) => findPdfTexts(w))
          .map((t) => t.text.toPlainText())
          .toList();

      expect(allTexts.any((t) => t.contains('Not available')), isFalse,
          reason: 'Must not emit "Not available" when fields are missing');
      expect(allTexts.any((t) => t.contains('N/A')), isFalse,
          reason: 'Must not emit "N/A" when fields are missing');
      expect(allTexts.any((t) => t.contains('null')), isFalse,
          reason: 'Must not emit "null" when fields are missing');
      expect(
          allTexts
              .any((t) => t == 'Type:' || t == 'Address:' || t == 'Schedule:'),
          isFalse,
          reason: 'Must not emit empty field labels');
    });

    test(
        '4. Available address, category, schedule, rating, travel information and Maps link remain available',
        () async {
      final fullPlace = ItineraryPlace(
        placeId: 'p_full',
        name: 'Penang State Museum',
        address: 'Farquhar Street, George Town',
        photoUrl: null,
        lat: 5.4215,
        lng: 100.3385,
        primaryType: 'Museum',
        allTypes: const ['museum', 'tourist_attraction'],
        suggestedTime: '10:00',
        durationMinutes: 60,
        notes: 'Ignored note',
        isVisited: true,
        visitedAt: DateTime(2026, 9, 4, 10, 15),
        regularOpeningPeriods: const [],
        rating: 4.6,
        userRatingCount: 320,
        phoneNumber: '+60 4-261 3144',
        website: 'https://museum.penang.gov.my',
        description: 'Rich Penang colonial history',
      );

      final service = ItineraryPdfService();
      final itinerary = createItinerary(
        title: 'Full Details Trip',
        travelMode: 'walk',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [fullPlace],
          ),
        ],
      );

      final widgets = await service.buildProductionContentWidgets(itinerary);
      final allTexts = widgets
          .expand((w) => findPdfTexts(w))
          .map((t) => t.text.toPlainText())
          .toList();

      expect(allTexts.any((t) => t.startsWith('Type: Museum')), isTrue);
      expect(
          allTexts.any((t) => t.startsWith('Rating: 4.6 / 5.0 (320 reviews)')),
          isTrue);
      expect(
          allTexts.any(
              (t) => t.startsWith('Address: Farquhar Street, George Town')),
          isTrue);
      expect(
          allTexts.any((t) => t.startsWith('Schedule: 10:00 - 11:00 (60 min)')),
          isTrue);
      expect(
          allTexts.any(
              (t) => t.startsWith('Travel from prev: First stop of the day')),
          isTrue);
      expect(allTexts.any((t) => t.startsWith('Tel: +60 4-261 3144')), isTrue);
      expect(
          allTexts.any(
              (t) => t.startsWith('Website: https://museum.penang.gov.my')),
          isTrue);
      expect(
          allTexts.any(
              (t) => t.startsWith('Description: Rich Penang colonial history')),
          isTrue);
      expect(allTexts.any((t) => t.startsWith('Open in Google Maps')), isTrue);
      expect(allTexts.any((t) => t.contains('Visited')), isTrue);
    });

    test('5. Day 1 has no leading page break', () async {
      final itinerary = createItinerary(
        title: 'Page Break Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(id: 'd1_p1', name: 'Stop 1', suggestedTime: '09:00')
            ],
          ),
          ItineraryDay(
            dayNumber: 2,
            date: '2026-09-05',
            places: [
              createPlace(id: 'd2_p1', name: 'Stop 2', suggestedTime: '09:00')
            ],
          ),
        ],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final day1Index = widgets.indexWhere((w) =>
          findPdfTexts(w).any((t) => t.text.toPlainText().startsWith('DAY 1')));
      expect(day1Index, isNonNegative);

      final preDay1Widgets = widgets.sublist(0, day1Index);
      expect(preDay1Widgets.any((w) => w is pw.NewPage), isFalse,
          reason: 'Day 1 begins after cover header with NO leading page break');
    });

    test('6. Every day after Day 1 receives exactly one page break', () async {
      final itinerary = createItinerary(
        title: '3-Day Break Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(id: 'd1_p1', name: 'Stop 1', suggestedTime: '09:00')
            ],
          ),
          ItineraryDay(
            dayNumber: 2,
            date: '2026-09-05',
            places: [
              createPlace(id: 'd2_p1', name: 'Stop 2', suggestedTime: '09:00')
            ],
          ),
          ItineraryDay(
            dayNumber: 3,
            date: '2026-09-06',
            places: [
              createPlace(id: 'd3_p1', name: 'Stop 3', suggestedTime: '09:00')
            ],
          ),
        ],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final newPageWidgets = widgets.whereType<pw.NewPage>().toList();
      expect(newPageWidgets.length, equals(2));

      final day2Index = widgets.indexWhere((w) =>
          findPdfTexts(w).any((t) => t.text.toPlainText().startsWith('DAY 2')));
      final day3Index = widgets.indexWhere((w) =>
          findPdfTexts(w).any((t) => t.text.toPlainText().startsWith('DAY 3')));

      expect(widgets[day2Index - 1] is pw.NewPage, isTrue,
          reason: 'Exactly one page break immediately precedes Day 2');
      expect(widgets[day3Index - 1] is pw.NewPage, isTrue,
          reason: 'Exactly one page break immediately precedes Day 3');
    });

    test(
        '7. A 3-day itinerary preserves order and starts every new day on a fresh page',
        () async {
      final d1 = ItineraryDay(
        dayNumber: 1,
        date: '2026-09-04',
        places: [
          createPlace(id: 'd1_a', name: 'Day 1 Stop A', suggestedTime: '09:00')
        ],
      );
      final d2 = ItineraryDay(
        dayNumber: 2,
        date: '2026-09-05',
        places: [
          createPlace(id: 'd2_a', name: 'Day 2 Stop A', suggestedTime: '09:00')
        ],
      );
      final d3 = ItineraryDay(
        dayNumber: 3,
        date: '2026-09-06',
        places: [
          createPlace(id: 'd3_a', name: 'Day 3 Stop A', suggestedTime: '09:00')
        ],
      );

      final itinerary = createItinerary(
        title: '3-Day Order Test',
        days: [d1, d2, d3],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final day1Idx = widgets.indexWhere((w) =>
          findPdfTexts(w).any((t) => t.text.toPlainText().startsWith('DAY 1')));
      final day2Idx = widgets.indexWhere((w) =>
          findPdfTexts(w).any((t) => t.text.toPlainText().startsWith('DAY 2')));
      final day3Idx = widgets.indexWhere((w) =>
          findPdfTexts(w).any((t) => t.text.toPlainText().startsWith('DAY 3')));

      expect(day1Idx < day2Idx, isTrue);
      expect(day2Idx < day3Idx, isTrue);

      expect(widgets[day2Idx - 1], isA<pw.NewPage>());
      expect(widgets[day3Idx - 1], isA<pw.NewPage>());
    });

    test(
        '8. A long single day can span multiple pages without losing/reordering places',
        () async {
      final places = List.generate(
        15,
        (i) => createPlace(
          id: 'long_d1_p$i',
          name: 'Day 1 Exploration Stop ${i + 1}',
          address: 'Heritage Lane ${i + 1}, George Town',
          suggestedTime:
              '${(8 + i ~/ 2).toString().padLeft(2, '0')}:${(i % 2 == 0 ? '00' : '30')}',
        ),
      );

      final itinerary = createItinerary(
        title: 'Long Day Tour',
        days: [
          ItineraryDay(dayNumber: 1, date: '2026-09-04', places: places),
        ],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final allTexts = widgets
          .expand((w) => findPdfTexts(w))
          .map((t) => t.text.toPlainText())
          .toList();

      for (int i = 0; i < 15; i++) {
        expect(allTexts.any((t) => t == 'Day 1 Exploration Stop ${i + 1}'),
            isTrue);
      }

      final doc = await service.buildDocument(itinerary);
      final pdfBytes = await doc.save();
      expect(pdfBytes.isNotEmpty, isTrue);
    });

    test(
        '9. A 7-day x 6-place itinerary keeps all 42 places exactly once and in order',
        () async {
      final days = List.generate(
        7,
        (d) => ItineraryDay(
          dayNumber: d + 1,
          date: '2026-09-0${d + 1}',
          places: List.generate(
            6,
            (p) => createPlace(
              id: 'd${d + 1}_p${p + 1}',
              name: 'Day ${d + 1} Place ${p + 1}',
              suggestedTime: '${(9 + p * 2).toString().padLeft(2, '0')}:00',
            ),
          ),
        ),
      );

      final itinerary = createItinerary(
        title: 'Grand 7-Day Tour',
        days: days,
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final pageBreaks = widgets.whereType<pw.NewPage>().toList();
      expect(pageBreaks.length, equals(6));

      final allTexts = widgets
          .expand((w) => findPdfTexts(w))
          .map((t) => t.text.toPlainText())
          .toList();

      for (int d = 1; d <= 7; d++) {
        for (int p = 1; p <= 6; p++) {
          final target = 'Day $d Place $p';
          final occurrences = allTexts.where((t) => t == target).length;
          expect(occurrences, equals(1),
              reason: '$target must appear exactly once');
        }
      }
    });

    test('10. No empty trailing page is produced', () async {
      final itinerary = createItinerary(
        title: 'Trailing Page Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(id: 'tp_1', name: 'Only Stop', suggestedTime: '09:00')
            ],
          ),
        ],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      expect(widgets.last is pw.NewPage, isFalse);
      expect(widgets.whereType<pw.NewPage>().isEmpty, isTrue);

      final doc = await service.buildDocument(itinerary);
      final bytes = await doc.save();
      expect(bytes.isNotEmpty, isTrue);
    });

    test('11. Trip summary remains after the final day', () async {
      final itinerary = createItinerary(
        title: 'Trip Summary Order Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(id: 'ts_p1', name: 'Stop 1', suggestedTime: '09:00')
            ],
          ),
          ItineraryDay(
            dayNumber: 2,
            date: '2026-09-05',
            places: [
              createPlace(id: 'ts_p2', name: 'Stop 2', suggestedTime: '09:00')
            ],
          ),
        ],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final stop2Index = widgets.indexWhere(
          (w) => findPdfTexts(w).any((t) => t.text.toPlainText() == 'Stop 2'));
      final tripSummaryIndex = widgets.indexWhere((w) =>
          findPdfTexts(w).any((t) => t.text.toPlainText() == 'TRIP SUMMARY'));

      expect(tripSummaryIndex > stop2Index, isTrue,
          reason: 'TRIP SUMMARY must appear after the final day places');
    });

    test('12. Every place name uses the PDF bold style', () async {
      final p1 = createPlace(
          id: 'bold_p1', name: 'Fort Cornwallis', suggestedTime: '09:00');
      final p2 = createPlace(
          id: 'bold_p2', name: 'Chew Jetty', suggestedTime: '10:00');

      final itinerary = createItinerary(
        title: 'Bold Place Names Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [p1, p2],
          ),
        ],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final allTexts = widgets.expand((w) => findPdfTexts(w)).toList();

      final p1Text =
          allTexts.firstWhere((t) => t.text.toPlainText() == 'Fort Cornwallis');
      final p2Text =
          allTexts.firstWhere((t) => t.text.toPlainText() == 'Chew Jetty');

      expect(p1Text.text.style?.fontWeight, equals(pw.FontWeight.bold),
          reason: 'Place name must use bold font style');
      expect(p2Text.text.style?.fontWeight, equals(pw.FontWeight.bold),
          reason: 'Place name must use bold font style');
      expect(p1Text.text.style?.fontSize, equals(12),
          reason:
              'Place name must remain clearly larger than supporting details');
    });

    test('13. A long bold place name wraps without failure', () async {
      const longName =
          'Very Long Heritage Site Name In Georgetown That Spans Multiple Lines When Formatted In The Itinerary PDF Place Card Header';
      final pLong = createPlace(
        id: 'p_long_bold',
        name: longName,
        address: '123 Heritage Street, George Town, Penang',
        suggestedTime: '09:00',
      );

      final itinerary = createItinerary(
        title: 'Long Bold Wrap Test',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [pLong],
          ),
        ],
      );

      final service = ItineraryPdfService();
      final widgets = await service.buildProductionContentWidgets(itinerary);

      final allTexts = widgets.expand((w) => findPdfTexts(w)).toList();
      final longText =
          allTexts.firstWhere((t) => t.text.toPlainText() == longName);

      expect(longText.text.style?.fontWeight, equals(pw.FontWeight.bold));
      expect(longText.text.toPlainText(), equals(longName));

      final doc = await service.buildDocument(itinerary);
      final bytes = await doc.save();
      expect(bytes.isNotEmpty, isTrue);
    });

    test(
        '14. English, Malay and Chinese bold place names render with the bundled Unicode font',
        () async {
      final fontFile = io.File('assets/fonts/NotoSansSC-Regular.ttf');
      expect(fontFile.existsSync(), isTrue);

      final font = pw.Font.ttf(fontFile.readAsBytesSync().buffer.asByteData());
      final service = ItineraryPdfService(
        baseFont: font,
        boldFont: font,
      );

      final itinerary = createItinerary(
        title: 'Multilingual Bold Names',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(
                id: 'en_bold',
                name: 'Penang Botanic Gardens',
                suggestedTime: '09:00',
              ),
              createPlace(
                id: 'ms_bold',
                name: 'Taman Negara Pulau Pinang',
                suggestedTime: '11:00',
              ),
              createPlace(
                id: 'zh_bold_1',
                name: '极乐寺',
                suggestedTime: '13:00',
              ),
              createPlace(
                id: 'zh_bold_2',
                name: '姓周桥',
                suggestedTime: '15:00',
              ),
              createPlace(
                id: 'zh_bold_3',
                name: '马来西亚',
                suggestedTime: '17:00',
              ),
            ],
          ),
        ],
      );

      final widgets = await service.buildProductionContentWidgets(itinerary);
      final allTexts = widgets.expand((w) => findPdfTexts(w)).toList();

      for (final name in [
        'Penang Botanic Gardens',
        'Taman Negara Pulau Pinang',
        '极乐寺',
        '姓周桥',
        '马来西亚'
      ]) {
        final textWidget =
            allTexts.firstWhere((t) => t.text.toPlainText() == name);
        expect(textWidget.text.style?.fontWeight, equals(pw.FontWeight.bold));
      }

      final doc = await service.buildDocument(itinerary);
      final bytes = await doc.save();
      expect(bytes.isNotEmpty, isTrue);
    });

    test(
        '15. Existing cache-only, Unicode, immutability and widget tests remain passing',
        () async {
      final p1 =
          createPlace(id: 'im_1', name: 'Origin Place', suggestedTime: '09:00');
      final originalItinerary = createItinerary(
        title: 'Original Unchanged Trip',
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [p1],
          ),
        ],
      );

      final service = ItineraryPdfService();
      await service.generatePdf(originalItinerary);

      expect(originalItinerary.title, equals('Original Unchanged Trip'));
      expect(originalItinerary.days.first.places.first.isVisited, isFalse);
      expect(originalItinerary.isCompleted, isFalse);
    });
  });

  group('Itinerary Detail Page - Export PDF Widget Tests', () {
    testWidgets(
        'Export button is enabled for an unvisited saved itinerary (does not require isCompleted)',
        (tester) async {
      // 2 places, 0 visited -> isCompleted is false
      final unvisitedItinerary = ItineraryModel(
        id: 'unvis_1',
        title: 'New Trip Plan',
        startDate: '2026-09-04',
        totalDays: 1,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(
                  id: 'p1',
                  name: 'Stop 1',
                  suggestedTime: '09:00',
                  isVisited: false),
              createPlace(
                  id: 'p2',
                  name: 'Stop 2',
                  suggestedTime: '11:00',
                  isVisited: false),
            ],
          ),
        ],
        createdAt: DateTime(2026, 9, 1),
        isOriginCurrentLocation: false,
      );

      expect(unvisitedItinerary.isCompleted, isFalse);
      expect(unvisitedItinerary.totalVisited, equals(0));

      await tester.pumpWidget(
        MaterialApp(
          home: ItineraryDetailPage(
            itinerary: unvisitedItinerary,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final exportButtonFinder =
          find.byKey(const ValueKey('export_pdf_button'));
      expect(exportButtonFinder, findsOneWidget);

      final iconButton = tester.widget<IconButton>(exportButtonFinder);
      // Button MUST be enabled for unvisited saved itinerary
      expect(iconButton.onPressed, isNotNull);
      expect(iconButton.tooltip, equals('Export PDF'));
    });

    testWidgets('Export button is enabled for a completed saved itinerary',
        (tester) async {
      final completedItinerary = ItineraryModel(
        id: 'comp_1',
        title: 'Finished Vacation',
        startDate: '2026-09-04',
        totalDays: 1,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(
                  id: 'p1',
                  name: 'Stop 1',
                  suggestedTime: '09:00',
                  isVisited: true),
            ],
          ),
        ],
        createdAt: DateTime(2026, 9, 1),
        isOriginCurrentLocation: false,
      );

      expect(completedItinerary.isCompleted, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: ItineraryDetailPage(
            itinerary: completedItinerary,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final exportButtonFinder =
          find.byKey(const ValueKey('export_pdf_button'));
      expect(exportButtonFinder, findsOneWidget);

      final iconButton = tester.widget<IconButton>(exportButtonFinder);
      expect(iconButton.onPressed, isNotNull);
      expect(iconButton.tooltip, equals('Export PDF'));
    });

    testWidgets(
        'Empty itinerary without places disables export button gracefully',
        (tester) async {
      final emptyItinerary = ItineraryModel(
        id: 'empty_1',
        title: 'Empty Trip',
        startDate: '2026-09-04',
        totalDays: 1,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: const [],
          ),
        ],
        createdAt: DateTime(2026, 9, 1),
        isOriginCurrentLocation: false,
      );

      expect(emptyItinerary.totalPlaces, equals(0));

      await tester.pumpWidget(
        MaterialApp(
          home: ItineraryDetailPage(
            itinerary: emptyItinerary,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final exportButtonFinder =
          find.byKey(const ValueKey('export_pdf_button'));
      expect(exportButtonFinder, findsOneWidget);

      final iconButton = tester.widget<IconButton>(exportButtonFinder);
      expect(iconButton.onPressed, isNull);
      expect(
          iconButton.tooltip, equals('No exportable places in this itinerary'));
    });

    testWidgets('Repeated export taps cannot start duplicate export operations',
        (tester) async {
      int exportCallCount = 0;
      final completer = Completer<void>();

      final fakeService = ItineraryPdfService(
        exportHandler: (itin) async {
          exportCallCount++;
          await completer.future;
          return '/tmp/mock.pdf';
        },
      );

      final unvisitedItinerary = ItineraryModel(
        id: 'unvis_tap',
        title: 'Unvisited Trip',
        startDate: '2026-09-04',
        totalDays: 1,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(
                  id: 'p1',
                  name: 'Stop 1',
                  suggestedTime: '09:00',
                  isVisited: false),
            ],
          ),
        ],
        createdAt: DateTime(2026, 9, 1),
        isOriginCurrentLocation: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ItineraryDetailPage(
            itinerary: unvisitedItinerary,
            pdfService: fakeService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final exportButtonFinder =
          find.byKey(const ValueKey('export_pdf_button'));
      expect(exportButtonFinder, findsOneWidget);

      // Tap once
      await tester.tap(exportButtonFinder);
      await tester.pump(); // Start export async task

      // Verify that progress indicator replaced the button
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.byKey(const ValueKey('export_pdf_button')), findsNothing);

      // Subsequent tap attempt on the area during in-flight operation
      await tester.tapAt(const Offset(300, 30));
      await tester.pump();

      // Ensure export only triggered once
      expect(exportCallCount, equals(1));

      // Resolve export operation
      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(exportCallCount, equals(1));
      expect(find.text('Itinerary PDF exported successfully!'), findsOneWidget);
    });

    testWidgets(
        'Failure is surfaced via SnackBar without corrupting the itinerary',
        (tester) async {
      final failingService = ItineraryPdfService(
        exportHandler: (itin) async {
          throw Exception('Simulated Android share sheet error');
        },
      );

      final testItinerary = ItineraryModel(
        id: 'err_itin',
        title: 'Error Test Trip',
        startDate: '2026-09-04',
        totalDays: 1,
        days: [
          ItineraryDay(
            dayNumber: 1,
            date: '2026-09-04',
            places: [
              createPlace(
                  id: 'p1',
                  name: 'Stop 1',
                  suggestedTime: '09:00',
                  isVisited: false),
            ],
          ),
        ],
        createdAt: DateTime(2026, 9, 1),
        isOriginCurrentLocation: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ItineraryDetailPage(
            itinerary: testItinerary,
            pdfService: failingService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final exportButtonFinder =
          find.byKey(const ValueKey('export_pdf_button'));
      expect(exportButtonFinder, findsOneWidget);

      await tester.tap(exportButtonFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Error SnackBar should be surfaced
      expect(
        find.textContaining(
            'Failed to export PDF: Exception: Simulated Android share sheet error'),
        findsOneWidget,
      );

      // Button is re-enabled and itinerary remains completely intact
      expect(find.byKey(const ValueKey('export_pdf_button')), findsOneWidget);
      expect(find.text('Stop 1'), findsOneWidget);
    });
  });
}
