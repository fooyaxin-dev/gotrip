// services/sentiment_service.dart
//
// ═══════════════════════════════════════════════════════════════════════════
// Lexicon-Based Sentiment Analysis Engine
// ═══════════════════════════════════════════════════════════════════════════
//
// Pure local algorithm — no external AI API calls. Designed to be a clean,
// explainable, and replaceable backend algorithm for the GoTrip Interaction
// Module.
//
// PIPELINE:
//   1. Preprocessing      — lowercase, strip punctuation, tokenize
//   2. Lexicon Matching   — match each token against polarity dictionaries
//   3. Negation Handling  — flips polarity within a negation window
//      (e.g. "not good" → negative, not positive)
//   4. Intensity Modifier — booster/diminisher words scale the score
//      (e.g. "very good" > "good" > "slightly good")
//   5. Aggregation        — sum token contributions
//   6. Normalization      — squash raw score into [0.0, 1.0] via a
//      saturating function so long posts don't blow past the scale
//   7. Classification     — map normalized score to positive/neutral/negative
//      using configurable thresholds
//
// The interface is async (`Future<SentimentResult>`) even though the current
// implementation is synchronous string processing. This keeps the call site
// (addPost.dart) stable if the underlying engine is ever swapped for a
// heavier model later — no caller code would need to change.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:math' as math;

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

/// Result object returned by the sentiment engine.
class SentimentResult {
  /// Normalized score in [0.0, 1.0]. 0.0 = most negative, 1.0 = most positive,
  /// ~0.5 = neutral. This continuous value is what the recommendation
  /// algorithm consumes (more granular than the 3-way label).
  final double score;

  /// Discretized 3-class label derived from [score] using threshold rules.
  final SentimentLabel label;

  /// Raw (pre-normalization) aggregate lexicon score — useful for debugging
  /// and for the FYP report to show the algorithm's intermediate output.
  final double rawScore;

  /// How many sentiment-bearing tokens were matched. Used as a lightweight
  /// confidence proxy — a post with 0 matched tokens is unreliable.
  final int matchedTokenCount;

  const SentimentResult({
    required this.score,
    required this.label,
    required this.rawScore,
    required this.matchedTokenCount,
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
  };

  @override
  String toString() =>
      'SentimentResult(label=${label.toJson()}, score=${score.toStringAsFixed(3)}, '
      'raw=${rawScore.toStringAsFixed(2)}, matched=$matchedTokenCount)';
}

// ═════════════════════════════════════════════════════════════════════════
// Abstract interface — allows swapping the engine later without touching
// any call sites.
// ═════════════════════════════════════════════════════════════════════════

abstract class SentimentAnalyzer {
  Future<SentimentResult> analyze(String text);
}

// ═════════════════════════════════════════════════════════════════════════
// Concrete implementation: Lexicon-Based Sentiment Analyzer
// ═════════════════════════════════════════════════════════════════════════

class LexiconSentimentAnalyzer implements SentimentAnalyzer {
  static final LexiconSentimentAnalyzer instance = LexiconSentimentAnalyzer._();
  LexiconSentimentAnalyzer._();

  // ── Classification thresholds ─────────────────────────────────────────
  // Applied to the normalized [0,1] score.
  static const double _positiveThreshold = 0.60;
  static const double _negativeThreshold = 0.40;

  // ── Negation window ────────────────────────────────────────────────────
  // A negation word flips the polarity of up to this many following tokens.
  // e.g. "not very good food" → "not" flips "very"(intensity) + "good"(polarity)
  static const int _negationWindow = 3;

  // ═══════════════════════════════════════════════════════════════════
  // LEXICON: General-purpose polarity words
  // ═══════════════════════════════════════════════════════════════════

  static const Map<String, double> _generalPositive = {
    'good': 1.0, 'great': 1.5, 'excellent': 2.0, 'amazing': 2.0,
    'awesome': 2.0, 'wonderful': 1.8, 'fantastic': 2.0, 'love': 1.8,
    'loved': 1.8, 'best': 1.8, 'happy': 1.3, 'beautiful': 1.5,
    'nice': 1.0, 'perfect': 2.0, 'enjoy': 1.3, 'enjoyed': 1.3,
    'enjoyable': 1.3, 'recommend': 1.5, 'recommended': 1.5,
    'impressive': 1.5, 'satisfied': 1.2, 'satisfying': 1.2,
    'pleasant': 1.2, 'comfortable': 1.0, 'fun': 1.2, 'cool': 1.0,
    'worth': 1.0, 'worthy': 1.0, 'memorable': 1.3, 'stunning': 1.8,
    'gorgeous': 1.7, 'lovely': 1.4, 'fabulous': 1.7, 'incredible': 1.8,
    'superb': 1.8, 'outstanding': 1.8, 'delightful': 1.5,
    'smooth': 0.9, 'helpful': 1.1, 'friendly': 1.2, 'welcoming': 1.2,
    'fresh': 0.9, 'cozy': 1.0, 'relaxing': 1.2, 'peaceful': 1.1,
  };

  static const Map<String, double> _generalNegative = {
    'bad': 1.0, 'terrible': 2.0, 'awful': 2.0, 'horrible': 2.0,
    'worst': 2.0, 'hate': 1.8, 'hated': 1.8, 'disappointing': 1.5,
    'disappointed': 1.5, 'poor': 1.2, 'sad': 1.0, 'annoying': 1.2,
    'frustrating': 1.4, 'frustrated': 1.4, 'boring': 1.1, 'bored': 1.1,
    'unpleasant': 1.3, 'uncomfortable': 1.1, 'waste': 1.4,
    'regret': 1.4, 'regretted': 1.4, 'disgusting': 1.9, 'gross': 1.5,
    'rude': 1.3, 'unfriendly': 1.2, 'unhelpful': 1.2, 'slow': 0.8,
    'dirty': 1.3, 'messy': 1.0, 'noisy': 0.9, 'crowded': 0.6,
    'overpriced': 1.0, 'expensive': 0.5, 'rip-off': 1.6, 'scam': 1.8,
    'mediocre': 0.9, 'mess': 1.0, 'broken': 1.1, 'lacking': 0.8,
  };

  // ═══════════════════════════════════════════════════════════════════
  // LEXICON: Travel/F&B domain-specific words
  // (Tailored to GoTrip's domain: restaurants, attractions, hotels, etc.)
  // ═══════════════════════════════════════════════════════════════════

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

  // ═══════════════════════════════════════════════════════════════════
  // LEXICON: Negation & intensity modifiers
  // ═══════════════════════════════════════════════════════════════════

  static const Set<String> _negationWords = {
    'not', 'no', "n't", 'never', 'none', 'nobody', 'nothing',
    'neither', 'nor', 'without', "isn't", "wasn't", "aren't",
    "weren't", "don't", "doesn't", "didn't", "won't", "wouldn't",
    "can't", "couldn't", "shouldn't",
  };

  // Multiplicative intensity modifiers applied to the NEXT polarity word.
  static const Map<String, double> _intensifiers = {
    'very': 1.5, 'extremely': 1.8, 'super': 1.6, 'really': 1.4,
    'so': 1.3, 'incredibly': 1.7, 'absolutely': 1.7, 'totally': 1.5,
    'highly': 1.5, 'truly': 1.4,
  };

  static const Map<String, double> _diminishers = {
    'slightly': 0.5, 'somewhat': 0.6, 'kinda': 0.6,
    'fairly': 0.7, 'rather': 0.7,
  };

  // ═══════════════════════════════════════════════════════════════════
  // LEXICON: Multi-word phrases (checked as bigrams before single-token
  // scoring, since "hidden gem" / "tourist trap" etc. only carry meaning
  // as a pair — splitting them into single tokens loses the signal).
  // ═══════════════════════════════════════════════════════════════════

  static const Map<String, double> _phrasePositive = {
    'hidden gem': 1.8,
  };

  static const Map<String, double> _phraseNegative = {
    'tourist trap': 1.8,
    'long queue': 0.9,
    'long wait': 0.9,
    'rip off': 1.6, // hyphen stripped during tokenization → "rip off"
  };

  // Multi-word intensity modifiers (also bigrams).
  static const Map<String, double> _phraseDiminishers = {
    'a bit': 0.6, 'a little': 0.6, 'kind of': 0.6,
  };

  // ═══════════════════════════════════════════════════════════════════
  // PUBLIC ENTRY POINT
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<SentimentResult> analyze(String text) async {
    if (text.trim().isEmpty) {
      return const SentimentResult(
        score: 0.5,
        label: SentimentLabel.neutral,
        rawScore: 0.0,
        matchedTokenCount: 0,
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
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  // STEP 1: Preprocessing — lowercase, strip punctuation, tokenize
  // ═══════════════════════════════════════════════════════════════════

  List<String> _tokenize(String text) {
    final lower = text.toLowerCase();

    // Preserve apostrophes inside contractions (don't, can't) but strip
    // other punctuation so "good!!" matches "good".
    final cleaned = lower.replaceAll(RegExp(r"[^\w\s']"), ' ');

    return cleaned
        .split(RegExp(r'\s+'))
        .where((t) => t.trim().isNotEmpty)
        .toList();
  }

  // ═══════════════════════════════════════════════════════════════════
  // STEP 2-4: Phrase + lexicon matching, negation handling, intensity
  // ═══════════════════════════════════════════════════════════════════
  //
  // Phrase-level matching runs first: at each position we check whether
  // the current token + next token form a known bigram (e.g. "hidden gem").
  // If so, both tokens are consumed together and treated as ONE unit.
  // Otherwise we fall back to single-token lexicon lookup.
  // ═══════════════════════════════════════════════════════════════════

  ({double rawScore, int matchedCount}) _scoreTokens(List<String> tokens) {
    double total = 0.0;
    int matched = 0;

    int negationCountdown = 0;
    double pendingMultiplier = 1.0;

    int i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      final bigram = (i + 1 < tokens.length) ? '$token ${tokens[i + 1]}' : null;

      // ── Bigram phrase check (consumes 2 tokens at once) ──
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

          i += 2; // consumed both tokens
          continue;
        }

        if (_phraseDiminishers.containsKey(bigram)) {
          pendingMultiplier *= _phraseDiminishers[bigram]!;
          i += 2;
          continue;
        }
      }

      // ── Negation trigger ──
      if (_negationWords.contains(token)) {
        negationCountdown = _negationWindow;
        i++;
        continue;
      }

      // ── Single-word intensity modifiers ──
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

      // ── Single-word polarity lookup (domain-specific lexicon checked
      //    first, so travel-specific meaning takes priority over generic) ──
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

  // ═══════════════════════════════════════════════════════════════════
  // STEP 5-6: Normalization — saturating squash into [0.0, 1.0]
  // ═══════════════════════════════════════════════════════════════════
  //
  // Uses a scaled logistic-like curve so a handful of strong words don't
  // immediately max out the scale, but the score still saturates smoothly
  // for very long, heavily one-sided posts.
  //
  //   rawScore = 0   → normalized = 0.5 (neutral)
  //   rawScore = +3  → normalized ≈ 0.73
  //   rawScore = +6  → normalized ≈ 0.88
  //   rawScore = -3  → normalized ≈ 0.27
  // ═══════════════════════════════════════════════════════════════════

  double _normalize(double rawScore) {
    const double steepness = 0.45; // controls how quickly it saturates
    final double squashed = 1.0 / (1.0 + math.exp(-steepness * rawScore));
    return squashed.clamp(0.0, 1.0);
  }

  // ═══════════════════════════════════════════════════════════════════
  // STEP 7: Classification
  // ═══════════════════════════════════════════════════════════════════

  SentimentLabel _classify(double normalizedScore) {
    if (normalizedScore >= _positiveThreshold) return SentimentLabel.positive;
    if (normalizedScore <= _negativeThreshold) return SentimentLabel.negative;
    return SentimentLabel.neutral;
  }
}