import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class LandmarkResult {
  final String landmark;       // display name (with confidence if from Vision)
  final String normalizedName; // clean name for Wikipedia/Gemini queries
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
  visionLandmark,   // Google Vision found it with high confidence
  geminiVision,     // Gemini looked at the image
  notDetected,
}

class VisionService {
  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc';
  static const double _highConfidenceThreshold = 0.70;

  // ─────────────────────────────────────────────────────────────
  // PUBLIC ENTRY
  // ─────────────────────────────────────────────────────────────

  static Future<LandmarkResult> detectLandmark(String base64Image) async {
    // ── Step 1: Google Vision Landmark Detection ──────────────
    final rawJson = await _callVisionApi(base64Image);
    final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
    final response =
        (decoded['responses'] as List?)?.firstOrNull as Map<String, dynamic>? ?? {};
    final landmarks = response['landmarkAnnotations'] as List<dynamic>? ?? [];

    if (landmarks.isNotEmpty) {
      final best = landmarks[0] as Map<String, dynamic>;
      final description = (best['description'] as String? ?? '').trim();
      final score = (best['score'] as num?)?.toDouble() ?? 0.0;

      double? lat, lng;
      try {
        lat = (best['locations'][0]['latLng']['latitude'] as num).toDouble();
        lng = (best['locations'][0]['latLng']['longitude'] as num).toDouble();
      } catch (_) {}

      if (score >= _highConfidenceThreshold && description.isNotEmpty) {
        debugPrint('✅ [Vision] High-confidence: $description (${(score * 100).toStringAsFixed(1)}%)');
        return LandmarkResult(
          landmark: '$description (Confidence: ${(score * 100).toStringAsFixed(1)}%)',
          normalizedName: description,
          rawJson: rawJson,
          lat: lat,
          lng: lng,
          confidence: score,
          method: DetectionMethod.visionLandmark,
        );
      }

      debugPrint('⚠️ [Vision] Low confidence ($score) for "$description" — falling back to Gemini Vision');
    } else {
      debugPrint('❌ [Vision] No landmark annotation — falling back to Gemini Vision');
    }

    // ── Step 2: Gemini Vision — send the actual image ─────────
    return await _detectWithGeminiVision(base64Image, rawJson);
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE: Google Vision API call
  // ─────────────────────────────────────────────────────────────

  static Future<String> _callVisionApi(String base64Image) async {
    final url = Uri.parse(
      'https://vision.googleapis.com/v1/images:annotate?key=$_apiKey',
    );
    final body = {
      'requests': [
        {
          'image': {'content': base64Image},
          'features': [
            {'type': 'LANDMARK_DETECTION', 'maxResults': 3},
          ],
        }
      ]
    };

    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      debugPrint('📩 Vision API status: ${response.statusCode}');
      return response.body;
    } catch (e) {
      debugPrint('⚠️ Vision API error: $e');
      return '{"responses":[{}]}';
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE: Gemini Vision — let Gemini look at the image
  // ─────────────────────────────────────────────────────────────

  static Future<LandmarkResult> _detectWithGeminiVision(
    String base64Image,
    String rawJson,
  ) async {
    try {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_apiKey',
      );

      final body = {
        'contents': [
          {
            'parts': [
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Image,
                }
              },
              {
                'text': '''
  You are a landmark identification expert. Look at this image carefully.

  If you can identify a landmark, famous place, tourist attraction, historical site, or notable building, respond ONLY with this JSON (no markdown, no explanation):
  {
    "name": "Official English name of the landmark",
    "lat": decimal number or null,
    "lng": decimal number or null
  }

  If you cannot identify any recognizable landmark or notable place, respond ONLY with:
  {"name": null, "lat": null, "lng": null}
  ''',
              }
            ]
          }
        ],
        'generationConfig': {
          'temperature': 0.1,
          'maxOutputTokens': 500,
          'responseMimeType': 'application/json',
        },
      };

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        debugPrint('⚠️ Gemini Vision error: ${response.statusCode}');
        return _noLandmark(rawJson);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '';

      final clean = text
          .replaceAll(RegExp(r'```json|```', multiLine: true), '')
          .trim();

      final start = clean.indexOf('{');
      final end   = clean.lastIndexOf('}');
      if (start == -1 || end == -1 || end <= start) {
        debugPrint('❌ [Gemini Vision] No valid JSON bounds in response: $clean');
        return _noLandmark(rawJson);
      }

      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(clean.substring(start, end + 1)) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('❌ [Gemini Vision] JSON decode failed: $e\nRaw: $clean');
        return _noLandmark(rawJson);
      }

      final name = (parsed['name'] as String?)?.trim();
      if (name == null || name.isEmpty) {
        debugPrint('❌ [Gemini Vision] Could not identify any landmark');
        return _noLandmark(rawJson);
      }

      final lat = (parsed['lat'] as num?)?.toDouble();
      final lng = (parsed['lng'] as num?)?.toDouble();

      debugPrint('✅ [Gemini Vision] Identified: $name');
      return LandmarkResult(
        landmark:       name,
        normalizedName: name,
        rawJson:        rawJson,
        lat:            lat,
        lng:            lng,
        confidence:     0.6,
        method:         DetectionMethod.geminiVision,
      );
    } catch (e) {
      debugPrint('⚠️ Gemini Vision exception: $e');
      return _noLandmark(rawJson);
    }
  }
  
  static Future<void> debugAvailableModels() async {
    const modelsToTest = [
      'gemini-2.0-flash',
      'gemini-2.0-flash-lite',
      'gemini-1.5-flash-latest',
      'gemini-1.5-pro-latest',
      'gemini-2.5-flash-preview-04-17',
    ];

    for (final model in modelsToTest) {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$_apiKey',
      );
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [{'parts': [{'text': 'say hi'}]}],
          'generationConfig': {'maxOutputTokens': 5},
        }),
      ).timeout(const Duration(seconds: 10));
      debugPrint('🔬 $model → ${res.statusCode}');
    }
  }



  // ─────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────

  static LandmarkResult _noLandmark(String rawJson) => LandmarkResult(
        landmark: 'No landmark detected',
        normalizedName: '',
        rawJson: rawJson,
        lat: null,
        lng: null,
        confidence: 0,
        method: DetectionMethod.notDetected,
      );
}