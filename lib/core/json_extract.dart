import 'dart:convert';

import 'package:parley/core/failures.dart';
import 'package:parley/services/llm/llm_client.dart';

/// Extracts the first JSON object from raw LLM output (SPEC 6.7).
///
/// Strips ``` fences, finds the first balanced `{...}` (ignoring braces
/// inside double-quoted strings), decodes it. The result must be a JSON
/// object. Throws [InvalidResponseFailure] when nothing usable is found.
Map<String, dynamic> extractJson(String raw) {
  final String source = _stripFences(raw);
  final String jsonText = _firstBalancedObject(source);
  try {
    final Object? decoded = jsonDecode(jsonText);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const InvalidResponseFailure();
  } on AppFailure {
    rethrow;
  } catch (_) {
    throw const InvalidResponseFailure();
  }
}

/// Returns the fenced block content when ``` fences are present,
/// otherwise the input unchanged.
String _stripFences(String raw) {
  final int open = raw.indexOf('```');
  if (open == -1) {
    return raw;
  }
  int contentStart = raw.indexOf('\n', open);
  if (contentStart == -1) {
    contentStart = open + 3;
  } else {
    contentStart += 1;
  }
  final int close = raw.indexOf('```', contentStart);
  if (close == -1) {
    return raw.substring(contentStart);
  }
  return raw.substring(contentStart, close);
}

/// Returns the first balanced `{...}` substring of [source].
String _firstBalancedObject(String source) {
  final int start = source.indexOf('{');
  if (start == -1) {
    throw const InvalidResponseFailure();
  }
  int depth = 0;
  bool inString = false;
  bool escaped = false;
  for (int i = start; i < source.length; i++) {
    final String ch = source[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
    } else {
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          return source.substring(start, i + 1);
        }
        if (depth < 0) {
          throw const InvalidResponseFailure();
        }
      }
    }
  }
  throw const InvalidResponseFailure();
}

/// Part of speech from the translate contract (SPEC 6.3).
enum TranslatePos {
  noun('noun'),
  verb('verb'),
  adj('adj'),
  adv('adv'),
  phrase('phrase'),
  other('other');

  const TranslatePos(this.value);

  final String value;

  static TranslatePos? tryParse(String value) {
    for (final TranslatePos pos in TranslatePos.values) {
      if (pos.value == value) {
        return pos;
      }
    }
    return null;
  }
}

/// Validated translate result (SPEC 6.3).
class TranslateResult {
  const TranslateResult({
    required this.lemma,
    required this.translationRu,
    required this.translationInContext,
    required this.pos,
  });

  final String lemma;

  /// Main dictionary meaning (saved to the unit).
  final String translationRu;

  /// Meaning in the given sentence; equals [translationRu] when the
  /// model did not send a different one (SPEC 6.3).
  final String translationInContext;

  final TranslatePos pos;
}

/// Validates a decoded translate JSON object.
TranslateResult validateTranslateJson(Map<String, dynamic> json) {
  final Object? lemma = json['lemma'];
  final Object? translation = json['translation_ru'];
  final Object? context = json['translation_in_context'];
  final Object? pos = json['pos'];
  if (lemma is! String || lemma.trim().isEmpty) {
    throw const InvalidResponseFailure();
  }
  if (translation is! String || translation.trim().isEmpty) {
    throw const InvalidResponseFailure();
  }
  if (context != null && context is! String) {
    throw const InvalidResponseFailure();
  }
  if (pos is! String) {
    throw const InvalidResponseFailure();
  }
  final TranslatePos? parsed = TranslatePos.tryParse(pos);
  if (parsed == null) {
    throw const InvalidResponseFailure();
  }
  final String dictionary = translation.trim();
  final String inContext = context is String ? context.trim() : '';
  return TranslateResult(
    lemma: lemma.trim(),
    translationRu: dictionary,
    translationInContext: inContext.isEmpty ? dictionary : inContext,
    pos: parsed,
  );
}

/// Word-judge rating label (SPEC 6.5).
enum JudgeRating {
  again('again'),
  hard('hard'),
  good('good'),
  easy('easy');

  const JudgeRating(this.value);

  final String value;

  static JudgeRating? tryParse(String value) {
    for (final JudgeRating rating in JudgeRating.values) {
      if (rating.value == value) {
        return rating;
      }
    }
    return null;
  }
}

/// One validated word-judge entry.
class WordJudgeRating {
  const WordJudgeRating({
    required this.text,
    required this.rating,
    required this.reason,
  });

  final String text;
  final JudgeRating rating;
  final String reason;
}

/// Validated word-judge result (SPEC 6.5).
class WordJudgeResult {
  const WordJudgeResult({required this.ratings});

  final List<WordJudgeRating> ratings;
}

/// Validates a decoded word-judge JSON object.
WordJudgeResult validateWordJudgeJson(Map<String, dynamic> json) {
  final Object? ratings = json['ratings'];
  if (ratings is! List) {
    throw const InvalidResponseFailure();
  }
  final List<WordJudgeRating> parsed = [];
  for (final Object? entry in ratings) {
    if (entry is! Map) {
      throw const InvalidResponseFailure();
    }
    final Map<String, dynamic> map = entry is Map<String, dynamic>
        ? entry
        : Map<String, dynamic>.from(entry);
    final Object? text = map['text'];
    final Object? rating = map['rating'];
    final Object? reason = map['reason'];
    if (text is! String || text.trim().isEmpty) {
      throw const InvalidResponseFailure();
    }
    if (rating is! String) {
      throw const InvalidResponseFailure();
    }
    final JudgeRating? parsedRating = JudgeRating.tryParse(rating);
    if (parsedRating == null) {
      throw const InvalidResponseFailure();
    }
    if (reason is! String || reason.trim().isEmpty) {
      throw const InvalidResponseFailure();
    }
    parsed.add(
      WordJudgeRating(text: text, rating: parsedRating, reason: reason),
    );
  }
  return WordJudgeResult(ratings: parsed);
}

/// Runs a JSON job through [client] with the one-retry rule (SPEC 6.7).
///
/// Calls `complete`, extracts and validates the JSON. On
/// [InvalidResponseFailure] retries once with the extra user line
/// `Return ONLY the JSON object.` Other failures propagate without retry.
Future<T> completeJson<T>(
  LlmClient client,
  List<LlmMessage> messages,
  T Function(Map<String, dynamic>) validator, {
  double temperature = 0.2,
}) async {
  try {
    final String first = await client.complete(
      messages,
      temperature: temperature,
    );
    return await _parseJson(first, validator);
  } on InvalidResponseFailure {
    // Fall through to the single retry below.
  }
  final List<LlmMessage> retryMessages = [
    ...messages,
    const LlmMessage(
      role: LlmRole.user,
      content: 'Return ONLY the JSON object.',
    ),
  ];
  final String second = await client.complete(
    retryMessages,
    temperature: temperature,
  );
  return _parseJson(second, validator);
}

T _parseJson<T>(String raw, T Function(Map<String, dynamic>) validator) {
  try {
    final Map<String, dynamic> json = extractJson(raw);
    return validator(json);
  } on AppFailure {
    rethrow;
  } catch (_) {
    throw const InvalidResponseFailure();
  }
}
