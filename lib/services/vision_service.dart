import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'api_Keys.dart';

class LandmarkResult {
  final String landmark;
  final String normalizedName;
  final String rawJson;
  final double? lat;
  final double? lng;
  final double confidence;
  final DetectionMethod method;

  const LandmarkResult({
    required this.landmark,
    required this.normalizedName,
    required this.rawJson,
    this.lat,
    this.lng,
    this.confidence = 0,
    required this.method,
  });

  bool get isDetected => method != DetectionMethod.notDetected;
}

enum DetectionMethod {
  visionLandmark,
  geminiVision,
  notDetected,
}

class VisionService {
  static const String _visionApiKey = ApiKeys.googleVision;
  static const String _geminiApiKey = ApiKeys.gemini;

  static const double _highConfidenceThreshold = 0.70;

  static Future<LandmarkResult> detectLandmark(
    String base64Image,
  ) async {
    String rawJson = '{"responses":[{}]}';

    // Step 1: Google Vision
    try {
      rawJson = await _callVisionApi(base64Image);

      final decoded =
          jsonDecode(rawJson) as Map<String, dynamic>;

      final responses = decoded['responses'] as List<dynamic>?;

      final response =
          responses != null && responses.isNotEmpty
              ? responses.first as Map<String, dynamic>
              : <String, dynamic>{};

      final apiError = response['error'];

      if (apiError != null) {
        debugPrint(
          '⚠️ [Vision] API returned an error: $apiError',
        );
      } else {
        final landmarks =
            response['landmarkAnnotations']
                    as List<dynamic>? ??
                [];

        if (landmarks.isNotEmpty) {
          final best =
              landmarks.first as Map<String, dynamic>;

          final description =
              (best['description'] as String? ?? '').trim();

          final score =
              (best['score'] as num?)?.toDouble() ?? 0.0;

          double? lat;
          double? lng;

          final locations = best['locations'] as List<dynamic>?;

          if (locations != null && locations.isNotEmpty) {
            final location =
                locations.first as Map<String, dynamic>;

            final latLng =
                location['latLng'] as Map<String, dynamic>?;

            lat =
                (latLng?['latitude'] as num?)?.toDouble();

            lng =
                (latLng?['longitude'] as num?)?.toDouble();
          }

          if (description.isNotEmpty &&
              score >= _highConfidenceThreshold) {
            debugPrint(
              '✅ [Vision] High-confidence: '
              '$description '
              '(${(score * 100).toStringAsFixed(1)}%)',
            );

            return LandmarkResult(
              landmark:
                  '$description '
                  '(Confidence: '
                  '${(score * 100).toStringAsFixed(1)}%)',
              normalizedName: description,
              rawJson: rawJson,
              lat: lat,
              lng: lng,
              confidence: score,
              method: DetectionMethod.visionLandmark,
            );
          }

          debugPrint(
            '⚠️ [Vision] Low confidence '
            '(${(score * 100).toStringAsFixed(1)}%) '
            'for "$description". Trying Gemini.',
          );
        } else {
          debugPrint(
            'ℹ️ [Vision] Request succeeded, '
            'but no landmark annotation was found.',
          );
        }
      }
    } on TimeoutException {
      debugPrint(
        '⚠️ [Vision] Request timed out. Trying Gemini.',
      );
    } catch (e, stackTrace) {
      debugPrint(
        '⚠️ [Vision] Detection failed: $e',
      );
      debugPrintStack(stackTrace: stackTrace);
    }

    // Step 2: Gemini fallback
    return _detectWithGeminiVision(
      base64Image,
      rawJson,
    );
  }

  static Future<String> _callVisionApi(
    String base64Image,
  ) async {
    final url = Uri.parse(
      'https://vision.googleapis.com/v1/images:annotate'
      '?key=$_visionApiKey',
    );

    final body = {
      'requests': [
        {
          'image': {
            'content': base64Image,
          },
          'features': [
            {
              'type': 'LANDMARK_DETECTION',
              'maxResults': 3,
            },
          ],
        },
      ],
    };

    final response = await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));

    debugPrint(
      '📩 Vision API status: ${response.statusCode}',
    );

    if (response.statusCode != 200) {
      debugPrint(
        '❌ Vision API body: ${response.body}',
      );

      throw Exception(
        'Vision API failed with '
        'status ${response.statusCode}',
      );
    }

    return response.body;
  }

  static Future<LandmarkResult>
      _detectWithGeminiVision(
    String base64Image,
    String rawJson,
  ) async {
    try {
      debugPrint(
        '🔄 Falling back to Gemini Vision...',
      );

      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/'
        'v1beta/models/gemini-2.5-flash:generateContent'
        '?key=$_geminiApiKey',
      );

      final body = {
        'contents': [
          {
            'parts': [
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Image,
                },
              },
              {
                'text': '''
You are a landmark identification expert.

Look carefully at the provided image.

If you can identify a landmark, famous place, tourist attraction, historical site, or notable building, respond only with valid JSON:

{
  "name": "Official English name",
  "lat": 0.0,
  "lng": 0.0
}

Use null for latitude and longitude when uncertain.

If no recognizable landmark is visible, respond only with:

{
  "name": null,
  "lat": null,
  "lng": null
}
''',
              },
            ],
          },
        ],
        'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 500,
        'responseMimeType': 'application/json',
        'thinkingConfig': {
          'thinkingBudget': 0,
        },
      },
      };

     final stopwatch = Stopwatch()..start();

    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    debugPrint(
      '⏱️ Gemini request took ${stopwatch.elapsedMilliseconds}ms',
    );
    debugPrint(
      '📩 Gemini Vision status: '
      '${response.statusCode}',
    );

      if (response.statusCode != 200) {
        debugPrint(
          '❌ Gemini Vision body: ${response.body}',
        );
        return _noLandmark(rawJson);
      }

      final data =
          jsonDecode(response.body)
              as Map<String, dynamic>;

      final candidates =
          data['candidates'] as List<dynamic>?;

      if (candidates == null || candidates.isEmpty) {
        debugPrint(
          '❌ [Gemini Vision] No candidates. Full body: ${response.body}',
        );
        return _noLandmark(rawJson);
      }

      final candidate =
          candidates.first as Map<String, dynamic>;

      final content =
          candidate['content'] as Map<String, dynamic>?;

      final parts =
          content?['parts'] as List<dynamic>?;

      if (parts == null || parts.isEmpty) {
        debugPrint(
          '❌ [Gemini Vision] No response parts.',
        );
        return _noLandmark(rawJson);
      }

      final text = parts
          .whereType<Map<String, dynamic>>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();

      debugPrint('🧾 [Gemini Vision] Combined text: $text');

      final clean = text
          .replaceAll(
            RegExp(r'```json|```', caseSensitive: false),
            '',
          )
          .trim();

      debugPrint('🧾 [Gemini Vision] Raw text: $clean');

      final start = clean.indexOf('{');
      final end = clean.lastIndexOf('}');

      if (start == -1 || end == -1 || end <= start) {
        debugPrint(
          '❌ [Gemini Vision] No valid JSON object found: $clean',
        );
        return _noLandmark(rawJson);
      }

      final jsonText = clean.substring(start, end + 1);

      final Map<String, dynamic> parsed;

      try {
        parsed = jsonDecode(jsonText) as Map<String, dynamic>;
      } on FormatException catch (e) {
        debugPrint(
          '❌ [Gemini Vision] Invalid JSON: $e\n'
          'Extracted JSON: $jsonText\n'
          'Full response: $clean',
        );
        return _noLandmark(rawJson);
      }

      final name =
          (parsed['name'] as String?)?.trim();

      if (name == null || name.isEmpty) {
        debugPrint(
          '❌ [Gemini Vision] '
          'Could not identify landmark.',
        );
        return _noLandmark(rawJson);
      }

      final lat =
          (parsed['lat'] as num?)?.toDouble();

      final lng =
          (parsed['lng'] as num?)?.toDouble();

      debugPrint(
        '✅ [Gemini Vision] Identified: $name',
      );

      return LandmarkResult(
        landmark: name,
        normalizedName: name,
        rawJson: rawJson,
        lat: lat,
        lng: lng,
        confidence: 0.6,
        method: DetectionMethod.geminiVision,
      );
    } on TimeoutException {
      debugPrint(
        '❌ [Gemini Vision] Request timed out.',
      );
      return _noLandmark(rawJson);
    } catch (e, stackTrace) {
      debugPrint(
        '⚠️ Gemini Vision exception: $e',
      );
      debugPrintStack(stackTrace: stackTrace);
      return _noLandmark(rawJson);
    }
  }

  static LandmarkResult _noLandmark(
    String rawJson,
  ) {
    return LandmarkResult(
      landmark: 'No landmark detected',
      normalizedName: '',
      rawJson: rawJson,
      lat: null,
      lng: null,
      confidence: 0,
      method: DetectionMethod.notDetected,
    );
  }
}