import 'dart:convert';
import 'package:http/http.dart' as http;

class VisionService {
  static const String _apiKey = 'AIzaSyDHWey-AFgT_7trhWfPLF_X2i3qFdwKzBk';

  /// 返回 Map: { 'landmark': 'Eiffel Tower', 'rawJson': '...' }
  static Future<Map<String, String>> detectLandmarkWithJson(
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
        return {
          'landmark': '$description (Confidence: ${(score * 100).toStringAsFixed(1)}%)',
          'rawJson': rawJson
        };
      }
    }

    // Landmark not detected
    return {'landmark': 'No landmark detected', 'rawJson': rawJson};
  }
}
