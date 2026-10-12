import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';

import 'package:parley/data/models/unit.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';

/// Reads a dictionary kept in our own `entry` index schema (SPEC 5.12).
///
/// Used for DSL dictionaries, whose lookup cache materializes the text;
/// StarDict dictionaries keep offsets into their original body instead.
class IndexDictionarySource implements DictionaryService {
  IndexDictionarySource(this._file);

  final File _file;
  QueryExecutor? _executor;
  Future<void>? _opening;

  @override
  Future<DictionaryEntry?> lookup(String wordKey) async {
    final String key = normalizeKey(wordKey);
    if (key.isEmpty) {
      return null;
    }
    await _open();
    final List<Map<String, Object?>> rows = await _executor!.runSelect(
      'SELECT translation, transcription FROM entry WHERE text_key = ? '
      'LIMIT 1',
      [key],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Object? translation = rows.first['translation'];
    if (translation is! String || translation.isEmpty) {
      return null;
    }
    final Object? transcription = rows.first['transcription'];
    return DictionaryEntry(
      textKey: key,
      translation: translation,
      transcription: transcription is String && transcription.isNotEmpty
          ? transcription
          : null,
    );
  }

  Future<void> _open() {
    return _opening ??= _doOpen().onError<Object>((
      Object error,
      StackTrace stack,
    ) {
      // Do not cache a failed open (A-45): a transient problem (a file
      // still being transferred, a lock) must not kill the dictionary
      // until dispose.
      _opening = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _doOpen() async {
    if (!await _file.exists()) {
      throw const DictionarySourceException(
        'The dictionary files are missing.',
      );
    }
    final QueryExecutor executor = NativeDatabase(_file);
    await executor.ensureOpen(const DictionaryExecutorUser());
    _executor = executor;
  }

  @override
  Future<void> dispose() async {
    await _executor?.close();
    _executor = null;
    _opening = null;
  }
}
