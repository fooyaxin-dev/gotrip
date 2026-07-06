import 'dart:convert';
import 'package:http/http.dart' as http;

const geoapifyApiKey = 'c5c749f7cbe1449990bce4542f6661aa'; // ← 换成你的 Geoapify key
const geminiApiKey   = 'AQ.Ab8RN6IzpDwG-M2jWuXySJCvcywHMj7VBftYmPUkwaF2Cv77TA';   // ← 换成你的 Gemini key

const double testLat = 3.1390;
const double testLng = 101.6869;
const int testRadius = 5000;

const cuisineToType = {
  'chinese':     'chinese_restaurant',
  'malay':       'malaysian_restaurant',
  'indian':      'indian_restaurant',
  'japanese':    'japanese_restaurant',
  'korean':      'korean_restaurant',
  'western':     'western_restaurant',
  'cafe':        'cafe',
  'dessert':     'dessert_shop',
  'unknown':     null, // Gemini 不确定时返回这个
};

Future<void> main() async {
  print('═══════════════════════════════════════');
  print('STEP 1: Search restaurants via Geoapify');
  print('═══════════════════════════════════════\n');

  final searchUri = Uri.parse(
    'https://api.geoapify.com/v2/places'
    '?categories=catering.restaurant'
    '&filter=circle:$testLng,$testLat,$testRadius'
    '&limit=20'
    '&apiKey=$geoapifyApiKey',
  );

  final searchResponse = await http.get(searchUri);
  if (searchResponse.statusCode != 200) {
    print('❌ Search failed: ${searchResponse.statusCode}');
    return;
  }

  final searchData = jsonDecode(searchResponse.body);
  final features = searchData['features'] as List? ?? [];

  print('✅ Found ${features.length} restaurants\n');

  // ── Get cuisine from Geoapify first (Layer 1) ──
  final List<Map<String, String>> needsGemini = [];
  final Map<String, String> tagResults = {};

  print('═══════════════════════════════════════');
  print('STEP 2: Check Geoapify cuisine tag first');
  print('═══════════════════════════════════════\n');

  for (final f in features) {
    final props   = f['properties'] as Map<String, dynamic>? ?? {};
    final name    = props['name']?.toString() ?? 'Unknown';
    final placeId = props['place_id']?.toString() ?? '';
    final address = props['formatted']?.toString() ?? '';

    if (placeId.isEmpty) continue;

    final detailsUri = Uri.parse(
      'https://api.geoapify.com/v2/place-details'
      '?id=$placeId'
      '&apiKey=$geoapifyApiKey',
    );

    final detailsResponse = await http.get(detailsUri);
    if (detailsResponse.statusCode != 200) continue;

    final detailsData = jsonDecode(detailsResponse.body);
    final detailFeatures = detailsData['features'] as List?;
    if (detailFeatures == null || detailFeatures.isEmpty) continue;

    final detailProps = detailFeatures[0]['properties'] as Map<String, dynamic>?;
    final raw = (detailProps?['datasource'] as Map<String, dynamic>?)?['raw'] as Map<String, dynamic>?;
    final cuisine = raw?['cuisine']?.toString().toLowerCase();

    if (cuisine != null && cuisine.isNotEmpty) {
      print('✅ [TAG] $name → cuisine="$cuisine"');
      tagResults[name] = cuisine;
    } else {
      print('⚪ [NO TAG] $name → will ask Gemini');
      needsGemini.add({'name': name, 'address': address});
    }

    await Future.delayed(const Duration(milliseconds: 150));
  }

  print('\n═══════════════════════════════════════');
  print('STEP 3: Ask Gemini for the rest (${needsGemini.length} places)');
  print('═══════════════════════════════════════\n');

  if (needsGemini.isEmpty) {
    print('No places need Gemini classification.');
    return;
  }

  // ── Build batch prompt ──
  final placesListStr = needsGemini.asMap().entries.map((e) {
    final idx = e.key;
    final place = e.value;
    return '${idx + 1}. "${place['name']}" (address: ${place['address']})';
  }).join('\n');

  final prompt = '''
You are a restaurant cuisine classifier for Malaysia. Based on the restaurant name and address, classify each restaurant's primary cuisine type.

Restaurants:
$placesListStr

Respond ONLY with a JSON array, no markdown, no explanation. Each object must have "name" and "cuisine" fields. 
The "cuisine" value must be exactly one of: "chinese", "malay", "indian", "japanese", "korean", "western", "cafe", "dessert", "unknown".
Use "unknown" only if you genuinely cannot determine the cuisine from the name/address.

Example output:
[{"name": "Restoran Yik Feng", "cuisine": "chinese"}, {"name": "Some Cafe", "cuisine": "cafe"}]
''';

  final geminiUri = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$geminiApiKey',
  );

  final geminiBody = jsonEncode({
    'contents': [
      {
        'parts': [
          {'text': prompt}
        ]
      }
    ],
    'generationConfig': {
      'temperature': 0.1,
      'maxOutputTokens': 2000,
      'responseMimeType': 'application/json',
    },
  });

  final geminiResponse = await http.post(
    geminiUri,
    headers: {'Content-Type': 'application/json'},
    body: geminiBody,
  );

  if (geminiResponse.statusCode != 200) {
    print('❌ Gemini failed: ${geminiResponse.statusCode}');
    print(geminiResponse.body);
    return;
  }

  final geminiData = jsonDecode(geminiResponse.body);
  final text = geminiData['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '';

  print('Raw Gemini response:');
  print(text);
  print('');

  // ── Parse Gemini's JSON response ──
  try {
    final clean = text.replaceAll(RegExp(r'```json|```'), '').trim();
    final parsed = jsonDecode(clean) as List;

    print('═══════════════════════════════════════');
    print('STEP 4: Final results');
    print('═══════════════════════════════════════\n');

    for (final item in parsed) {
      final name    = item['name'] as String;
      final cuisine = item['cuisine'] as String;
      final mapped  = cuisineToType[cuisine];

      if (mapped != null) {
        print('🤖 [GEMINI] $name → cuisine="$cuisine" → $mapped');
      } else {
        print('⚪ [GEMINI] $name → unknown, stays in "All"');
      }
    }
  } catch (e) {
    print('❌ Failed to parse Gemini response: $e');
  }

  print('\n═══════════════════════════════════════');
  print('SUMMARY');
  print('═══════════════════════════════════════');
  print('Total restaurants:     ${features.length}');
  print('Classified by tag:     ${tagResults.length}');
  print('Sent to Gemini:        ${needsGemini.length}');
}