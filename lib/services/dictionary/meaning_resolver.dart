import 'package:parley/core/json_extract.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/translation/translation.dart';

/// Resolves a word's meaning at display time (PLAN 19.1).
///
/// Units store no translations; every surface asks the current sources:
/// the bundled dictionary first (offline, instant), then the LLM when the
/// device is online and configured. A session cache avoids duplicate LLM
/// calls. User dictionaries plug into the same chain in 19.2.
class MeaningResolver {
  MeaningResolver({
    required DictionaryService dictionary,
    required LlmClient llm,
    required ConnectivityService connectivity,
  }) : _dictionary = dictionary,
       _llm = llm,
       _connectivity = connectivity;

  final DictionaryService _dictionary;
  final LlmClient _llm;
  final ConnectivityService _connectivity;
  final Map<String, String> _llmCache = {};

  /// Bundled-dictionary meaning, or null when the word is missing.
  Future<String?> bundled(String textKey) async {
    try {
      final DictionaryEntry? entry = await _dictionary.lookup(textKey);
      return entry?.translation;
    } catch (_) {
      return null;
    }
  }

  /// Bundled meaning, then the LLM (online only). Null when unresolved.
  Future<String?> resolve(String textKey, {String sentence = ''}) async {
    final String? local = await bundled(textKey);
    if (local != null && local.isNotEmpty) {
      return local;
    }
    final String? cached = _llmCache[textKey];
    if (cached != null) {
      return cached;
    }
    bool online = false;
    try {
      online = await _connectivity.isOnline();
    } catch (_) {
      online = false;
    }
    if (!online) {
      return null;
    }
    try {
      final TranslateResult result = await completeJson(
        _llm,
        buildTranslateMessages(textKey, sentence),
        validateTranslateJson,
      );
      _llmCache[textKey] = result.translationRu;
      return result.translationRu;
    } catch (_) {
      return null;
    }
  }
}
