import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/export/file_picker_service.dart';

/// Raised when a picked file is not a usable dictionary (SPEC 5.12).
class DictionaryImportException implements Exception {
  const DictionaryImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of importing one dictionary file.
class DictionaryImportSummary {
  const DictionaryImportSummary({required this.name, required this.entryCount});

  final String name;
  final int entryCount;
}

/// Upper bound per imported dictionary (SPEC 5.12).
///
/// Protects the app from a stray huge file freezing the import; the importer
/// refuses anything larger.
const int maxDictionaryEntries = 500000;

/// Imports user dictionaries into the app database (SPEC 5.12).
///
/// Accepts a CSV file (`word;translation`, the same shape as SPEC 4.6) or a
/// SQLite file with an `entry(text_key, translation)` table (the shape of
/// the bundled dictionary, so other dictionary tools' exports work too).
class DictionaryImporter {
  DictionaryImporter({required UserDictionaryRepository dictionaries})
    : _dictionaries = dictionaries;

  final UserDictionaryRepository _dictionaries;

  /// Parses [file] and stores it as the lowest-priority dictionary.
  ///
  /// Throws [DictionaryImportException] for unusable files.
  Future<DictionaryImportSummary> importFile(PickedDictionaryFile file) async {
    final List<({String textKey, String translation})> entries = file.isSqlite
        ? await _readSqlite(file.path)
        : _readCsv(file.csvContent ?? '');
    if (entries.isEmpty) {
      throw const DictionaryImportException(
        'The file has no dictionary entries.',
      );
    }
    final String base = p.basenameWithoutExtension(file.path).trim();
    final String name = base.isEmpty ? 'Imported dictionary' : base;
    await _dictionaries.importEntries(name: name, entries: entries);
    return DictionaryImportSummary(name: name, entryCount: entries.length);
  }

  List<({String textKey, String translation})> _readCsv(String content) {
    final String withoutBom = content.startsWith('\uFEFF')
        ? content.substring(1)
        : content;
    final List<({String textKey, String translation})> entries = [];
    final Set<String> seen = {};
    bool isFirstLine = true;
    for (final String rawLine in withoutBom.split(RegExp(r'\r\n|\r|\n'))) {
      final String line = rawLine.trim();
      if (isFirstLine) {
        isFirstLine = false;
        final String lower = line.toLowerCase();
        if (lower == 'word;translation' || lower == 'text_key;translation') {
          continue;
        }
      }
      if (line.isEmpty) {
        continue;
      }
      final List<String> parts = rawLine.split(';');
      if (parts.length < 2) {
        continue;
      }
      final String key = normalizeKey(parts.first);
      final String translation = parts[1].trim();
      if (key.isEmpty || translation.isEmpty || !seen.add(key)) {
        continue;
      }
      entries.add((textKey: key, translation: translation));
    }
    return entries;
  }

  Future<List<({String textKey, String translation})>> _readSqlite(
    String path,
  ) async {
    final File file = File(path);
    if (!await file.exists()) {
      throw const DictionaryImportException('The file could not be read.');
    }
    final QueryExecutor executor = NativeDatabase(file);
    try {
      await executor.ensureOpen(const DictionaryExecutorUser());
      final List<Map<String, Object?>> tables = await executor.runSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'entry'",
        [],
      );
      if (tables.isEmpty) {
        throw const DictionaryImportException("The file has no 'entry' table.");
      }
      final List<Map<String, Object?>> columns = await executor.runSelect(
        'PRAGMA table_info(entry)',
        [],
      );
      final Set<String> names = {
        for (final Map<String, Object?> column in columns)
          if (column['name'] is String) column['name']! as String,
      };
      if (!names.contains('text_key') || !names.contains('translation')) {
        throw const DictionaryImportException(
          "The 'entry' table needs text_key and translation columns.",
        );
      }
      final List<Map<String, Object?>> rows = await executor.runSelect(
        'SELECT text_key, translation FROM entry',
        [],
      );
      if (rows.length > maxDictionaryEntries) {
        throw const DictionaryImportException(
          'The dictionary has too many entries '
          '(the limit is $maxDictionaryEntries).',
        );
      }
      final List<({String textKey, String translation})> entries = [];
      final Set<String> seen = {};
      for (final Map<String, Object?> row in rows) {
        final Object? rawKey = row['text_key'];
        final Object? rawTranslation = row['translation'];
        if (rawKey is! String || rawTranslation is! String) {
          continue;
        }
        final String key = normalizeKey(rawKey);
        final String translation = rawTranslation.trim();
        if (key.isEmpty || translation.isEmpty || !seen.add(key)) {
          continue;
        }
        entries.add((textKey: key, translation: translation));
      }
      return entries;
    } finally {
      await executor.close();
    }
  }
}
