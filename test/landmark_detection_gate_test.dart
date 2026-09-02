import 'package:flutter_test/flutter_test.dart';
import 'package:gotrip/services/vision_service.dart';

void main() {
  group('Landmark Detection Gate & Parser Production Tests', () {
    test('1. Valid clear landmark is accepted with confidence >= 0.70', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Petronas Twin Towers",
        "landmark_type": "tower",
        "confidence": 0.95,
        "lat": 3.1579,
        "lng": 101.7116
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isTrue);
      expect(result.method, equals(DetectionMethod.geminiVision));
      expect(result.normalizedName, equals('Petronas Twin Towers'));
      expect(result.confidence, equals(0.95));
      expect(result.lat, closeTo(3.1579, 0.0001));
      expect(result.lng, closeTo(101.7116, 0.0001));
    });

    test('2. is_landmark: false is rejected safely', () {
      const response = '''
      {
        "is_landmark": false,
        "name": null,
        "landmark_type": null,
        "confidence": 0.0,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
      expect(result.normalizedName, isEmpty);
    });

    test(
        '3. Person/selfie is rejected even if name is supplied with is_landmark: false',
        () {
      const response = '''
      {
        "is_landmark": false,
        "name": "Smiling Person Selfie",
        "landmark_type": "tourist_attraction",
        "confidence": 0.90,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('4. Animal image with generic label is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Cat",
        "landmark_type": "tourist_attraction",
        "confidence": 0.85,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('5. Food image with generic label is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Food",
        "landmark_type": "tourist_attraction",
        "confidence": 0.88,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('6. Ordinary room with generic label is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Living Room",
        "landmark_type": "notable_building",
        "confidence": 0.90,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('7. Generic exact label "Building" is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Building",
        "landmark_type": "notable_building",
        "confidence": 0.80,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test(
        '8. "Empire State Building" is accepted and not rejected by generic filter',
        () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Empire State Building",
        "landmark_type": "historic_building",
        "confidence": 0.98,
        "lat": 40.7484,
        "lng": -73.9857
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isTrue);
      expect(result.normalizedName, equals('Empire State Building'));
      expect(result.confidence, equals(0.98));
      expect(result.lat, closeTo(40.7484, 0.0001));
      expect(result.lng, closeTo(-73.9857, 0.0001));
    });

    test(
        '9. "Sultan Abdul Samad Building" is accepted with historic_building type',
        () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Sultan Abdul Samad Building",
        "landmark_type": "historic_building",
        "confidence": 0.92,
        "lat": 3.1486,
        "lng": 101.6944
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isTrue);
      expect(result.normalizedName, equals('Sultan Abdul Samad Building'));
      expect(result.confidence, equals(0.92));
    });

    test(
        '10. "KLCC Park" is accepted with public_square or tourist_attraction type',
        () {
      const response = '''
      {
        "is_landmark": true,
        "name": "KLCC Park",
        "landmark_type": "public_square",
        "confidence": 0.89,
        "lat": 3.1556,
        "lng": 101.7145
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isTrue);
      expect(result.normalizedName, equals('KLCC Park'));
      expect(result.confidence, equals(0.89));
    });

    test('11. Low confidence (< 0.70) is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Some Uncertain Tower",
        "landmark_type": "tower",
        "confidence": 0.65,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('12. Missing confidence is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Tokyo Tower",
        "landmark_type": "tower",
        "confidence": null,
        "lat": 35.6586,
        "lng": 139.7454
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('13. Invalid or unsupported landmark_type is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Random House",
        "landmark_type": "unsupported_custom_type",
        "confidence": 0.95,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('14. Missing or empty name is rejected', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "",
        "landmark_type": "monument",
        "confidence": 0.85,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test('15. Malformed JSON string is safely rejected without throwing', () {
      const response = 'THIS IS NOT VALID JSON AT ALL';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isFalse);
      expect(result.method, equals(DetectionMethod.notDetected));
    });

    test(
        '16. Out-of-range coordinates are sanitized to null while accepting landmark',
        () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Eiffel Tower",
        "landmark_type": "monument",
        "confidence": 0.99,
        "lat": 120.0,
        "lng": -250.0
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isTrue);
      expect(result.normalizedName, equals('Eiffel Tower'));
      expect(result.lat, isNull);
      expect(result.lng, isNull);
    });

    test('17. Valid landmark with null coordinates is accepted', () {
      const response = '''
      {
        "is_landmark": true,
        "name": "Colosseum",
        "landmark_type": "historic_building",
        "confidence": 0.94,
        "lat": null,
        "lng": null
      }
      ''';

      final result = VisionService.parseGeminiResponse(response);

      expect(result.isDetected, isTrue);
      expect(result.normalizedName, equals('Colosseum'));
      expect(result.lat, isNull);
      expect(result.lng, isNull);
      expect(result.confidence, equals(0.94));
    });
  });
}
