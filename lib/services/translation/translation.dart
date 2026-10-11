import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/json_extract.dart';
import 'package:parley/services/llm/llm_client.dart';

/// Language meanings are translated into when the setting is not set
/// (SPEC 5.10). The bundled dictionary is English-Russian, so this matches.
const String defaultMeaningLanguage = 'ru';

const Map<String, String> _meaningLanguageNames = {
  'ru': 'Russian',
  'en': 'English',
  'de': 'German',
  'fr': 'French',
  'es': 'Spanish',
  'it': 'Italian',
  'pt': 'Portuguese',
  'nl': 'Dutch',
  'pl': 'Polish',
  'uk': 'Ukrainian',
  'tr': 'Turkish',
  'cs': 'Czech',
  'sv': 'Swedish',
  'da': 'Danish',
  'no': 'Norwegian',
  'fi': 'Finnish',
  'el': 'Greek',
  'he': 'Hebrew',
  'ar': 'Arabic',
  'fa': 'Persian',
  'hi': 'Hindi',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'vi': 'Vietnamese',
  'th': 'Thai',
  'id': 'Indonesian',
};

/// English name of the meaning language code, for the prompt.
///
/// Unknown codes are passed through as-is; models understand ISO codes.
String meaningLanguageName(String code) {
  final String normalized = code.trim().toLowerCase();
  return _meaningLanguageNames[normalized] ?? normalized;
}

/// Verbatim system prompt for translation, filled with the meaning language
/// (SPEC 6.3).
String translateSystemPrompt(String meaningLanguage) {
  final String language = meaningLanguageName(meaningLanguage);
  return 'You are a precise English-$language dictionary. Output ONLY JSON: '
      '{"lemma":"...","translation":"...","translation_in_context":"...","pos":"noun|verb|adj|adv|phrase|other"}. '
      'lemma is the base form of the word as used in the sentence. '
      'translation is the main dictionary meaning: 1-3 short $language equivalents '
      'separated by commas that describe the word itself, as a dictionary does. '
      'translation_in_context is 1-3 short $language equivalents matching the meaning '
      'in the given sentence; use the same text as translation when the meanings match. '
      'pos is the part of speech.';
}

/// Builds the non-streaming translate request (SPEC 6.3).
List<LlmMessage> buildTranslateMessages(
  String surface,
  String sentence, {
  String meaningLanguage = defaultMeaningLanguage,
}) {
  return [
    LlmMessage(
      role: LlmRole.system,
      content: translateSystemPrompt(meaningLanguage),
    ),
    LlmMessage(
      role: LlmRole.user,
      content: 'Word: $surface\nSentence: $sentence',
    ),
  ];
}

/// In-memory translate cache for one app session (SPEC 5.5).
class TranslationCache {
  final Map<String, TranslateResult> _entries = {};

  TranslateResult? get(String key) => _entries[key];

  void set(String key, TranslateResult value) {
    _entries[key] = value;
  }
}

/// Cache provider (one instance per app session).
final translationCacheProvider = Provider<TranslationCache>((ref) {
  return TranslationCache();
});
