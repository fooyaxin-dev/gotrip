import 'dart:convert';
import 'package:http/http.dart' as http;

class VisionService {
  static const String _apiKey = 'AIzaSyBWodBoara2qnvRA_3TuYTFmHG9xngQwdc'; // String.fromEnvironment('GOOGLE_API_KEY');

  /// 返回 Map: { 'landmark': 'Eiffel Tower', 'rawJson': '...', 'lat': 48.85, 'lng': 2.29 }
  static Future<Map<String, dynamic>> detectLandmarkWithJson(
      String base64Image) async {
    final url = Uri.parse(
      'https://vision.googleapis.com/v1/images:annotate?key=$_apiKey',
    );

    final body = {
      "requests": [
        {
          "image": {"content": base64Image},
          "features": [
            {"type": "LANDMARK_DETECTION", "maxResults": 1}
          ]
        }
      ]
    };

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    final rawJson = response.body;

    if (response.statusCode == 200) {
      final data = jsonDecode(rawJson);
      final landmarks = data['responses'][0]['landmarkAnnotations'];

      if (landmarks != null && landmarks.isNotEmpty) {
        final description = landmarks[0]['description'];
        final score = landmarks[0]['score'];

        double? lat;
        double? lng;

        // 取第一个 location 的坐标
        try {
          lat = landmarks[0]['locations'][0]['latLng']['latitude'];
          lng = landmarks[0]['locations'][0]['latLng']['longitude'];
        } catch (e) {
          lat = null;
          lng = null;
        }

        return {
          'landmark': '$description (Confidence: ${(score * 100).toStringAsFixed(1)}%)',
          'rawJson': rawJson,
          'lat': lat,
          'lng': lng,
        };
      } 
    }

    print('🌐 Sending request to Vision API...');
    // 在 http.post 之前
    print('📊 Image base64 first 100 chars: ${base64Image.substring(0, 100)}');
    // 在收到 response 之后
    print('📩 Vision API status: ${response.statusCode}');
    print('📩 Vision API body: ${response.body}');

    // Landmark not detected
    return {
      'landmark': 'No landmark detected',
      'rawJson': rawJson,
      'lat': null,
      'lng': null,
    };

    
  }
}