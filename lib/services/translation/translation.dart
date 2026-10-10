import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/json_extract.dart';
import 'package:parley/services/llm/llm_client.dart';

/// Verbatim system prompt for translation (SPEC 6.3).
const String translateSystemPrompt =
    'You are a precise English-Russian dictionary. Output ONLY JSON: '
    '{"lemma":"...","translation_ru":"...","translation_in_context":"...","pos":"noun|verb|adj|adv|phrase|other"}. '
    'lemma is the base form of the word as used in the sentence. '
    'translation_ru is the main dictionary meaning: 1-3 short Russian equivalents '
    'separated by commas that describe the word itself, as a dictionary does. '
    'translation_in_context is 1-3 short Russian equivalents matching the meaning '
    'in the given sentence; use the same text as translation_ru when the meanings match. '
    'pos is the part of speech.';

/// Builds the non-streaming translate request (SPEC 6.3).
List<LlmMessage> buildTranslateMessages(String surface, String sentence) {
  return [
    const LlmMessage(role: LlmRole.system, content: translateSystemPrompt),
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
