import 'package:parley/core/json_extract.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/translation/translation.dart';

/// Resolves a word's meaning at display time (PLAN 19.1, SPEC 5.12).
///
/// Units store no translations; every surface asks the current sources:
/// the enabled user dictionaries for the configured meaning language
/// (highest priority wins), then the bundled English-Russian dictionary
/// when that language matches (offline, instant), then the LLM when the
/// device is online and configured. A session cache avoids duplicate LLM
/// calls; the LLM answer is requested in the configured meaning language
/// (PLAN 19.2).
class MeaningResolver {
  MeaningResolver({
    required DictionaryService dictionary,
    required LlmClient llm,
    required ConnectivityService connectivity,
    required UserDictionaryLookup userDictionaries,
    required SettingsRepository settings,
  }) : _dictionary = dictionary,
       _llm = llm,
       _connectivity = connectivity,
       _userDictionaries = userDictionaries,
       _settings = settings;

  final DictionaryService _dictionary;
  final LlmClient _llm;
  final ConnectivityService _connectivity;
  final UserDictionaryLookup _userDictionaries;
  final SettingsRepository _settings;
  final Map<(String, String), String> _llmCache = {};

  /// Entry from the local sources: user dictionaries for the configured
  /// meaning language first, then the bundled dictionary (only when that
  /// language matches the bundle's).
  ///
  /// A broken user dictionary or bundle just means a miss.
  Future<DictionaryEntry?> dictionaryEntry(String wordKey) async {
    final String language = _settings.meaningLanguage;
    try {
      final DictionaryEntry? entry = await _userDictionaries.lookup(
        wordKey,
        targetLang: language,
      );
      if (entry != null) {
        return entry;
      }
    } catch (_) {
      // Fall through to the bundle.
    }
    if (language != bundledDictionaryLanguage) {
      return null;
    }
    try {
      return await _dictionary.lookup(wordKey);
    } catch (_) {
      return null;
    }
  }

  /// Meaning from the local sources (SPEC 5.12), or null.
  Future<String?> dictionaryMeaning(String textKey) async {
    final DictionaryEntry? entry = await dictionaryEntry(textKey);
    final String? translation = entry?.translation;
    if (translation == null || translation.isEmpty) {
      return null;
    }
    return translation;
  }

  /// Local meaning, then the LLM (online only). Null when unresolved.
  ///
  /// LLM answers are cached per word and meaning language, so switching the
  /// language in Settings refetches instead of serving the old language.
  Future<String?> resolve(String textKey, {String sentence = ''}) async {
    final String language = _settings.meaningLanguage;
    final String? meaning = await dictionaryMeaning(textKey);
    if (meaning != null) {
      return meaning;
    }
    final String? cached = _llmCache[(textKey, language)];
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
        buildTranslateMessages(textKey, sentence, meaningLanguage: language),
        validateTranslateJson,
      );
      _llmCache[(textKey, language)] = result.translation;
      return result.translation;
    } catch (_) {
      return null;
    }
  }
}
