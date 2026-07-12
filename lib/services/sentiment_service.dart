// services/sentiment_service.dart
//
// ═══════════════════════════════════════════════════════════════════════════
// Sentiment Analysis Engine — Lexicon + Gemini-backed implementations
// ═══════════════════════════════════════════════════════════════════════════
//
// This file ships THREE implementations of the same `SentimentAnalyzer`
// interface:
//
//   1. LexiconSentimentAnalyzer   — original rule/dictionary-based engine.
//                                   Fast, offline, fully explainable, but
//                                   blind to anything outside its word lists.
//
//   2. GeminiSentimentAnalyzer    — delegates to the Gemini API
//                                   (generateContent). Understands context,
//                                   sarcasm, slang, mixed languages, etc.
//                                   Requires network + API key, has
//                                   latency/cost per call (free tier
//                                   available with rate limits).
//
//   3. HybridSentimentAnalyzer    — tries Gemini first; if the call fails
//                                   (no network, API error, timeout, bad
//                                   JSON, rate limit, etc.) it transparently
//                                   falls back to the lexicon engine so the
//                                   app never breaks and always returns
//                                   *something*.
//
// Because every caller only ever depends on the abstract `SentimentAnalyzer`
// interface (see addPost.dart), swapping which concrete class gets
// constructed is a one-line change — no call-site changes needed.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:math' as math;


import 'package:http/http.dart' as http;

enum SentimentLabel { positive, neutral, negative }

extension SentimentLabelX on SentimentLabel {
  String toJson() => name; // 'positive' | 'neutral' | 'negative'

  static SentimentLabel fromJson(String? s) {
    switch (s) {
      case 'positive': return SentimentLabel.positive;
      case 'negative': return SentimentLabel.negative;
      default:          return SentimentLabel.neutral;
    }
  }

  String get emoji {
    switch (this) {
      case SentimentLabel.positive: return '😊';
      case SentimentLabel.neutral:  return '😐';
      case SentimentLabel.negative: return '😞';
    }
  }

  String get displayLabel {
    switch (this) {
      case SentimentLabel.positive: return 'Positive';
      case SentimentLabel.neutral:  return 'Neutral';
      case SentimentLabel.negative: return 'Negative';
    }
  }
}

/// Result object returned by any sentiment engine.
class SentimentResult {
  /// Normalized score in [0.0, 1.0]. 0.0 = most negative, 1.0 = most positive,
  /// ~0.5 = neutral. This continuous value is what the recommendation
  /// algorithm consumes (more granular than the 3-way label).
  final double score;

  /// Discretized 3-class label derived from [score] using threshold rules.
  final SentimentLabel label;

  /// Raw (pre-normalization) aggregate lexicon score. Only meaningful for
  /// the lexicon engine — Gemini-backed results leave this at 0.0.
  final double rawScore;

  /// For the lexicon engine: number of sentiment-bearing tokens matched.
  /// For the Gemini engine: repurposed as a 0–10 confidence proxy
  /// (confidence * 10, rounded) since there's no "token count" concept.
  final int matchedTokenCount;

  /// Which concrete engine actually produced this result ('gemini' or
  /// 'lexicon'). Useful for debugging/logging when using
  /// HybridSentimentAnalyzer, since you can't otherwise tell whether a
  /// fallback happened.
  final String source;

  const SentimentResult({
    required this.score,
    required this.label,
    required this.rawScore,
    required this.matchedTokenCount,
    this.source = 'lexicon',
  });

  /// True when the engine found too few sentiment cues to trust the result.
  /// Callers (e.g. the recommendation pipeline) can choose to ignore
  /// low-confidence results.
  bool get isLowConfidence => matchedTokenCount < 2;

  Map<String, dynamic> toMap() => {
    'sentimentScore': score,
    'sentimentLabel': label.toJson(),
    'sentimentRawScore': rawScore,
    'sentimentMatchedTokens': matchedTokenCount,
    'sentimentSource': source,
  };

  @override
  String toString() =>
      'SentimentResult(label=${label.toJson()}, score=${score.toStringAsFixed(3)}, '
      'raw=${rawScore.toStringAsFixed(2)}, matched=$matchedTokenCount, source=$source)';
}

// ═════════════════════════════════════════════════════════════════════════
// Abstract interface — allows swapping the engine later without touching
// any call sites.
// ═════════════════════════════════════════════════════════════════════════

abstract class SentimentAnalyzer {
  Future<SentimentResult> analyze(String text);
}

// ═════════════════════════════════════════════════════════════════════════
// Implementation 1: Lexicon-Based Sentiment Analyzer (original engine)
// ═════════════════════════════════════════════════════════════════════════

class LexiconSentimentAnalyzer implements SentimentAnalyzer {
  static final LexiconSentimentAnalyzer instance = LexiconSentimentAnalyzer._();
  LexiconSentimentAnalyzer._();

  static const double _positiveThreshold = 0.60;
  static const double _negativeThreshold = 0.40;
  static const int _negationWindow = 3;

  static const Map<String, double> _generalPositive = {
    'good': 1.0, 'great': 1.5, 'excellent': 2.0, 'amazing': 2.0,
    'awesome': 2.0, 'wonderful': 1.8, 'fantastic': 2.0, 'love': 1.8,
    'loved': 1.8, 'like': 1.0, 'likes': 1.0, 'liked': 1.0,
    'best': 1.8, 'happy': 1.3, 'beautiful': 1.5,
    'nice': 1.0, 'perfect': 2.0, 'enjoy': 1.3, 'enjoyed': 1.3,
    'enjoyable': 1.3, 'recommend': 1.5, 'recommended': 1.5,
    'impressive': 1.5, 'satisfied': 1.2, 'satisfying': 1.2,
    'pleasant': 1.2, 'comfortable': 1.0, 'fun': 1.2, 'cool': 1.0,
    'worth': 1.0, 'worthy': 1.0, 'memorable': 1.3, 'stunning': 1.8,
    'gorgeous': 1.7, 'lovely': 1.4, 'fabulous': 1.7, 'incredible': 1.8,
    'superb': 1.8, 'outstanding': 1.8, 'delightful': 1.5,
    'smooth': 0.9, 'helpful': 1.1, 'friendly': 1.2, 'welcoming': 1.2,
    'fresh': 0.9, 'cozy': 1.0, 'relaxing': 1.2, 'peaceful': 1.1,
    'okay': 0.5, 'ok': 0.5, 'fine': 0.6, 'decent': 0.7, 'solid': 0.9,
  };

  static const Map<String, double> _generalNegative = {
    'bad': 1.0, 'terrible': 2.0, 'awful': 2.0, 'horrible': 2.0,
    'worst': 2.0, 'hate': 1.8, 'hated': 1.8, 'dislike': 1.2, 'disliked': 1.2,
    'disappointing': 1.5,
    'disappointed': 1.5, 'poor': 1.2, 'sad': 1.0, 'annoying': 1.2,
    'frustrating': 1.4, 'frustrated': 1.4, 'boring': 1.1, 'bored': 1.1,
    'unpleasant': 1.3, 'uncomfortable': 1.1, 'waste': 1.4,
    'regret': 1.4, 'regretted': 1.4, 'disgusting': 1.9, 'gross': 1.5,
    'rude': 1.3, 'unfriendly': 1.2, 'unhelpful': 1.2, 'slow': 0.8,
    'dirty': 1.3, 'messy': 1.0, 'noisy': 0.9, 'crowded': 0.6,
    'overpriced': 1.0, 'expensive': 0.5, 'rip-off': 1.6, 'scam': 1.8,
    'mediocre': 0.9, 'mess': 1.0, 'broken': 1.1, 'lacking': 0.8,
  };

  static const Map<String, double> _travelPositive = {
    'delicious': 1.8, 'tasty': 1.5, 'yummy': 1.5, 'flavorful': 1.4,
    'fresh': 1.0, 'authentic': 1.3, 'must-visit': 1.8, 'must-try': 1.8,
    'breathtaking': 2.0, 'scenic': 1.4, 'picturesque': 1.5,
    'spacious': 1.0, 'spotless': 1.4, 'clean': 1.2, 'tidy': 1.0,
    'underrated': 1.3, 'value': 0.9,
    'affordable': 1.0, 'cheap': 0.6, 'reasonable': 0.9,
    'instagrammable': 1.2, 'aesthetic': 1.1, 'cozy': 1.1,
    'serene': 1.3, 'tranquil': 1.3, 'vibrant': 1.2, 'lively': 1.0,
    'well-maintained': 1.3, 'attentive': 1.2, 'prompt': 1.0,
    'generous': 1.1, 'iconic': 1.4, 'charming': 1.4,
  };

  static const Map<String, double> _travelNegative = {
    'overpriced': 1.4, 'overrated': 1.3,
    'stale': 1.3, 'bland': 1.2, 'undercooked': 1.6, 'overcooked': 1.3,
    'tasteless': 1.4, 'cramped': 1.1, 'filthy': 1.8, 'unsanitary': 1.7,
    'understaffed': 1.0, 'unorganized': 1.0, 'chaotic': 1.1,
    'sketchy': 1.3,
    'run-down': 1.3, 'outdated': 0.9, 'shabby': 1.2,
    'pushy': 1.1, 'scammed': 1.8, 'misleading': 1.3,
    'avoid': 1.5, 'skip': 1.0, 'underwhelming': 1.2,
  };

  static const Set<String> _negationWords = {
    'not', 'no', "n't", 'never', 'none', 'nobody', 'nothing',
    'neither', 'nor', 'without', "isn't", "wasn't", "aren't",
    "weren't", "don't", "doesn't", "didn't", "won't", "wouldn't",
    "can't", "couldn't", "shouldn't",
  };

  static const Map<String, double> _intensifiers = {
    'very': 1.5, 'extremely': 1.8, 'super': 1.6, 'really': 1.4,
    'so': 1.3, 'incredibly': 1.7, 'absolutely': 1.7, 'totally': 1.5,
    'highly': 1.5, 'truly': 1.4,
  };

  static const Map<String, double> _diminishers = {
    'slightly': 0.5, 'somewhat': 0.6, 'kinda': 0.6,
    'fairly': 0.7, 'rather': 0.7,
  };

  static const Map<String, double> _phrasePositive = {
    'hidden gem': 1.8,
  };

  static const Map<String, double> _phraseNegative = {
    'tourist trap': 1.8,
    'long queue': 0.9,
    'long wait': 0.9,
    'rip off': 1.6,
  };

  static const Map<String, double> _phraseDiminishers = {
    'a bit': 0.6, 'a little': 0.6, 'kind of': 0.6,
  };

  @override
  Future<SentimentResult> analyze(String text) async {
    if (text.trim().isEmpty) {
      return const SentimentResult(
        score: 0.5,
        label: SentimentLabel.neutral,
        rawScore: 0.0,
        matchedTokenCount: 0,
        source: 'lexicon',
      );
    }

    final tokens = _tokenize(text);
    final scoring = _scoreTokens(tokens);

    final normalized = _normalize(scoring.rawScore);
    final label = _classify(normalized);

    return SentimentResult(
      score: normalized,
      label: label,
      rawScore: scoring.rawScore,
      matchedTokenCount: scoring.matchedCount,
      source: 'lexicon',
    );
  }

  List<String> _tokenize(String text) {
    final lower = text.toLowerCase();
    final cleaned = lower.replaceAll(RegExp(r"[^\w\s']"), ' ');
    return cleaned
        .split(RegExp(r'\s+'))
        .where((t) => t.trim().isNotEmpty)
        .toList();
  }

  ({double rawScore, int matchedCount}) _scoreTokens(List<String> tokens) {
    double total = 0.0;
    int matched = 0;

    int negationCountdown = 0;
    double pendingMultiplier = 1.0;

    int i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      final bigram = (i + 1 < tokens.length) ? '$token ${tokens[i + 1]}' : null;

      if (bigram != null) {
        final phrasePolarity = _phrasePositive[bigram] ?? _phraseNegative[bigram];
        if (phrasePolarity != null) {
          final isPositive = _phrasePositive.containsKey(bigram);
          double contribution = phrasePolarity * pendingMultiplier;
          if (!isPositive) contribution = -contribution;
          if (negationCountdown > 0) contribution = -contribution;

          total += contribution;
          matched++;
          pendingMultiplier = 1.0;
          if (negationCountdown > 0) negationCountdown--;

          i += 2;
          continue;
        }

        if (_phraseDiminishers.containsKey(bigram)) {
          pendingMultiplier *= _phraseDiminishers[bigram]!;
          i += 2;
          continue;
        }
      }

      if (_negationWords.contains(token)) {
        negationCountdown = _negationWindow;
        i++;
        continue;
      }

      if (_intensifiers.containsKey(token)) {
        pendingMultiplier *= _intensifiers[token]!;
        i++;
        continue;
      }
      if (_diminishers.containsKey(token)) {
        pendingMultiplier *= _diminishers[token]!;
        i++;
        continue;
      }

      double? polarity = _travelPositive[token] ?? _generalPositive[token];
      bool isPositive = polarity != null;

      if (!isPositive) {
        polarity = _travelNegative[token] ?? _generalNegative[token];
      }

      if (polarity != null) {
        double contribution = polarity * pendingMultiplier;
        if (!isPositive) contribution = -contribution;
        if (negationCountdown > 0) contribution = -contribution;

        total += contribution;
        matched++;
        pendingMultiplier = 1.0;
      }

      if (negationCountdown > 0) negationCountdown--;
      i++;
    }

    return (rawScore: total, matchedCount: matched);
  }

  double _normalize(double rawScore) {
    const double steepness = 0.45;
    final double squashed = 1.0 / (1.0 + math.exp(-steepness * rawScore));
    return squashed.clamp(0.0, 1.0);
  }

  SentimentLabel _classify(double normalizedScore) {
    if (normalizedScore >= _positiveThreshold) return SentimentLabel.positive;
    if (normalizedScore <= _negativeThreshold) return SentimentLabel.negative;
    return SentimentLabel.neutral;
  }
}

// ═════════════════════════════════════════════════════════════════════════
// Implementation 2: Gemini-Based Sentiment Analyzer
// ═════════════════════════════════════════════════════════════════════════
//
// Delegates the actual judgment to Gemini instead of a fixed dictionary.
// This handles sarcasm, mixed languages, slang, and anything not covered
// by a hand-written word list — at the cost of needing network access,
// an API key, and per-call latency. Gemini's free tier (with rate limits)
// makes this cheap for FYP-scale usage.
//
// Follows the same generateContent + responseMimeType: application/json
// pattern already used in VisionService, so the calling style should look
// familiar.
//
// IMPORTANT: never hardcode the API key in the app for production/shared
// repos. Inject it via --dart-define, a secrets manager, or a backend
// proxy so it isn't shipped inside the compiled app binary or committed
// to version control.
// ═════════════════════════════════════════════════════════════════════════

class GeminiSentimentAnalyzer implements SentimentAnalyzer {
  final String apiKey;
  final String model;
  final Duration timeout;
  final http.Client _client;

  GeminiSentimentAnalyzer({
    required this.apiKey,
    this.model = 'gemini-2.5-flash',
    this.timeout = const Duration(seconds: 15),
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<SentimentResult> analyze(String text) async {
    if (text.trim().isEmpty) {
      return const SentimentResult(
        score: 0.5,
        label: SentimentLabel.neutral,
        rawScore: 0.0,
        matchedTokenCount: 0,
        source: 'gemini',
      );
    }

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
    );

    final body = {
      'contents': [
        {
          'parts': [
            {'text': _buildPrompt(text)},
          ],
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 200,
        'responseMimeType': 'application/json',
      },
    };

    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw SentimentAnalysisException(
        'Gemini API returned ${response.statusCode}: ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final rawText = data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;
    if (rawText == null || rawText.trim().isEmpty) {
      throw const SentimentAnalysisException('Gemini response missing text');
    }

    final parsed = _extractJson(rawText);

    final score = (parsed['score'] as num?)?.toDouble();
    final labelStr = parsed['label'] as String?;
    final confidence = (parsed['confidence'] as num?)?.toDouble() ?? 0.5;

    if (score == null || labelStr == null) {
      throw const SentimentAnalysisException('Gemini response missing required fields');
    }

    return SentimentResult(
      score: score.clamp(0.0, 1.0),
      label: SentimentLabelX.fromJson(labelStr),
      rawScore: 0.0,
      matchedTokenCount: (confidence.clamp(0.0, 1.0) * 10).round(),
      source: 'gemini',
    );
  }

  String _buildPrompt(String text) {
    return '''
You are a sentiment classifier for travel and F&B (food & beverage) reviews.
Analyze the sentiment of the review below, accounting for context, sarcasm,
negation, mixed languages, and slang.

Respond with ONLY a raw JSON object, no markdown fences, no extra text:
{"score": <float 0.0-1.0, 0.0=very negative, 0.5=neutral, 1.0=very positive>, "label": "positive"|"neutral"|"negative", "confidence": <float 0.0-1.0>}

Review: "${text.replaceAll('"', "'")}"
''';
  }

  /// Strips markdown code fences if the model added them despite
  /// `responseMimeType: application/json`, and parses the remaining text.
  Map<String, dynamic> _extractJson(String rawText) {
    var cleaned = rawText.replaceAll(RegExp(r'```json|```'), '').trim();

    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      throw SentimentAnalysisException('No valid JSON bounds in Gemini response: $cleaned');
    }

    try {
      return jsonDecode(cleaned.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (e) {
      throw SentimentAnalysisException('Failed to parse Gemini JSON response: $e');
    }
  }

  void dispose() => _client.close();
}

class SentimentAnalysisException implements Exception {
  final String message;
  const SentimentAnalysisException(this.message);
  @override
  String toString() => 'SentimentAnalysisException: $message';
}

// ═════════════════════════════════════════════════════════════════════════
// Implementation 3: Hybrid — Gemini primary, lexicon as automatic fallback
// ═════════════════════════════════════════════════════════════════════════
//
// This is the one you should actually construct and use in the app.
// It tries the Gemini engine first (best quality, handles context/sarcasm).
// If anything goes wrong — no network, API error, timeout, malformed
// response, rate limit — it silently falls back to the offline lexicon
// engine so `addPost.dart` (or any other caller) NEVER sees a thrown
// exception and NEVER blocks the user's post from being submitted.
//
// Check `result.source` ('gemini' vs 'lexicon') if you want to log/monitor
// how often the fallback is triggered (e.g. hitting Gemini's free-tier
// rate limit).
// ═════════════════════════════════════════════════════════════════════════

class HybridSentimentAnalyzer implements SentimentAnalyzer {
  final GeminiSentimentAnalyzer _primary;
  final LexiconSentimentAnalyzer _fallback;
  final void Function(Object error, StackTrace stack)? onFallback;

  HybridSentimentAnalyzer({
    required GeminiSentimentAnalyzer primary,
    LexiconSentimentAnalyzer? fallback,
    this.onFallback,
  }) : _primary = primary,
       _fallback = fallback ?? LexiconSentimentAnalyzer.instance;

  @override
  Future<SentimentResult> analyze(String text) async {
    try {
      return await _primary.analyze(text);
    } catch (e, st) {
      // Network failure, API error, timeout, bad JSON, rate limit, etc.
      // Log it (e.g. via your crash-reporting tool) and degrade gracefully.
      onFallback?.call(e, st);
      return await _fallback.analyze(text);
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════
// Example wiring (put this where you currently construct the analyzer,
// e.g. in addPost.dart or a service locator / DI setup):
// ═════════════════════════════════════════════════════════════════════════
//
//   final analyzer = HybridSentimentAnalyzer(
//     primary: GeminiSentimentAnalyzer(
//       apiKey: const String.fromEnvironment('GEMINI_API_KEY'),
//     ),
//     onFallback: (e, st) => debugPrint('Sentiment fallback triggered: $e'),
//   );
//
//   final result = await analyzer.analyze(postText);
//
// No other call site needs to change — `result` is still a SentimentResult
// with the same fields as before, just with `source` telling you which
// engine actually produced it.
// ═════════════════════════════════════════════════════════════════════════