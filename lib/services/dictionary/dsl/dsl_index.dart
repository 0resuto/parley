import 'dart:io';

import 'package:drift/native.dart';

import 'package:parley/data/models/unit.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/dsl/dsl_parser.dart';

/// Number of rows per multi-row INSERT while building the cache.
const int _rowsPerInsert = 400;

/// Builds the lookup cache for a `.dsl` dictionary (SPEC 5.12).
///
/// The cache is a small SQLite file (`entry(text_key, translation,
/// transcription)`); the first card of a headword wins. Returns the number
/// of stored entries.
Future<int> buildDslIndexCache({
  required File dslFile,
  required File cacheFile,
  void Function(double fraction)? onProgress,
}) async {
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  final NativeDatabase executor = NativeDatabase(cacheFile);
  try {
    await executor.ensureOpen(const DictionaryExecutorUser());
    await executor.runCustom(
      'CREATE TABLE entry ('
      'text_key TEXT PRIMARY KEY, '
      'translation TEXT NOT NULL, '
      'transcription TEXT)',
    );
    final List<Object?> buffer = [];

    Future<void> flush() async {
      if (buffer.isEmpty) {
        return;
      }
      final int rows = buffer.length ~/ 3;
      final String placeholders = List.filled(rows, '(?, ?, ?)').join(', ');
      await executor.runCustom(
        'INSERT OR IGNORE INTO entry (text_key, translation, transcription) '
        'VALUES $placeholders',
        List<Object?>.of(buffer),
      );
      buffer.clear();
    }

    await for (final DslEntry entry in parseDsl(
      dslFile,
      onProgress: onProgress,
    )) {
      final String key = normalizeKey(entry.word);
      if (key.isEmpty) {
        continue;
      }
      buffer.addAll([key, entry.translation, entry.transcription]);
      if (buffer.length >= 3 * _rowsPerInsert) {
        await flush();
      }
    }
    await flush();
    final List<Map<String, Object?>> count = await executor.runSelect(
      'SELECT COUNT(*) AS total FROM entry',
      [],
    );
    return (count.first['total'] as int?) ?? 0;
  } finally {
    await executor.close();
  }
}
