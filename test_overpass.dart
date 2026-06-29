import 'dart:convert';
import 'package:http/http.dart' as http;

const apiKey = '9';

Future<void> main() async {
  try {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
    );

    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        "contents": [
          {
            "parts": [
              {
                "text": "Hello"
              }
            ]
          }
        ]
      }),
    );

    print("==============");
    print("Status: ${response.statusCode}");
    print(response.headers);
    print("--------------");
    print(response.body);
    print("==============");
  } catch (e, stack) {
    print(e);
    print(stack);
  }
}