import 'package:drift/drift.dart'
    show OpeningDetails, QueryExecutor, QueryExecutorUser;

import 'package:parley/data/models/unit.dart';

/// Language of the bundled dictionary (SPEC 5.11); it is only consulted
/// when the meaning language setting matches it.
const String bundledDictionaryLanguage = 'ru';

/// Raised when a dictionary's files are missing or unreadable.
class DictionarySourceException implements Exception {
  const DictionarySourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One dictionary lookup result (SPEC 5.11, 5.5).
///
/// Extensible: sources that carry richer data (transcription, examples)
/// fill the optional fields; the LLM fallback leaves them empty.
class DictionaryEntry {
  const DictionaryEntry({
    required this.textKey,
    required this.translation,
    this.transcription,
    this.examples = const [],
  });

  /// Normalized lookup key.
  final String textKey;

  /// Dictionary translation(s), comma-separated.
  final String translation;

  /// Phonetic transcription, when the source provides one.
  final String? transcription;

  /// Example sentences, when the source provides them.
  final List<String> examples;
}

/// Bundled dictionary lookups (SPEC 5.11).
abstract class DictionaryService {
  /// Returns the entry for [wordKey] or null when the word is missing.
  ///
  /// [wordKey] is normalized internally, so any case/apostrophe form works.
  Future<DictionaryEntry?> lookup(String wordKey);

  /// Releases the underlying resources (no-op for fakes).
  Future<void> dispose();
}

/// Fallback used when the bundle is unavailable: every lookup misses.
class EmptyDictionaryService implements DictionaryService {
  @override
  Future<DictionaryEntry?> lookup(String wordKey) async => null;

  @override
  Future<void> dispose() async {}
}

/// Minimal [QueryExecutorUser] for opening the bundled dictionary executor.
///
/// The dictionary file is built by `tool/build_dictionary.py`; opening it
/// needs no migrations, so the callbacks are no-ops.
class DictionaryExecutorUser implements QueryExecutorUser {
  const DictionaryExecutorUser();

  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

/// Read-only SQLite implementation over the bundled dictionary copy.
///
/// The database is the compact `entry(text_key, translation)` table built by
/// `tool/build_dictionary.py` from WikDict en-ru (CC BY-SA, SPEC 5.11).
class SqliteDictionaryService implements DictionaryService {
  SqliteDictionaryService(this._executor);

  final QueryExecutor _executor;

  @override
  Future<DictionaryEntry?> lookup(String wordKey) async {
    final String key = normalizeKey(wordKey);
    if (key.isEmpty) {
      return null;
    }
    await _executor.ensureOpen(const DictionaryExecutorUser());
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT translation FROM entry WHERE text_key = ? LIMIT 1',
      [key],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Object? translation = rows.first['translation'];
    if (translation is! String || translation.isEmpty) {
      return null;
    }
    return DictionaryEntry(textKey: key, translation: translation);
  }

  @override
  Future<void> dispose() => _executor.close();
}
