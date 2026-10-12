import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/services/dictionary/dictionary_file_store.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/dsl/index_dictionary_source.dart';
import 'package:parley/services/dictionary/stardict/stardict_source.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';

/// Storage for imported user dictionaries (SPEC 5.12).
///
/// Only metadata lives in the app database; the dictionary data stays in
/// its original files under the row's `path`, read through a cached
/// [StarDictSource] per dictionary.
class UserDictionaryRepository implements UserDictionaryLookup {
  UserDictionaryRepository(
    this._db, {
    required Clock clock,
    required DictionaryFileStore files,
  }) : _clock = clock,
       _files = files;

  final AppDatabase _db;
  final Clock _clock;
  final DictionaryFileStore _files;
  final Map<int, DictionaryService> _sources = {};

  /// Watches all dictionaries, highest priority first.
  Stream<List<UserDictionary>> watchAll() {
    final query = _db.select(_db.dictionaries)
      ..orderBy([
        (t) => OrderingTerm(expression: t.position, mode: OrderingMode.asc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
      ]);
    return query.watch().map(
      (rows) => [for (final UserDictionaryRow row in rows) _toModel(row)],
    );
  }

  /// Stores a new dictionary at the lowest priority.
  ///
  /// Returns the new dictionary id.
  Future<int> add({
    required String name,
    required String path,
    required String targetLang,
    required int wordCount,
    String format = 'stardict',
  }) async {
    final String cleanedFormat = format.trim();
    if (name.trim().isEmpty ||
        path.trim().isEmpty ||
        targetLang.trim().isEmpty ||
        cleanedFormat.isEmpty ||
        wordCount <= 0) {
      throw ArgumentError(
        'name, path, targetLang, format and wordCount are required',
      );
    }
    return _db.transaction(() async {
      final List<UserDictionaryRow> rows = await _db
          .select(_db.dictionaries)
          .get();
      int maxPosition = -1;
      for (final UserDictionaryRow row in rows) {
        if (row.position > maxPosition) {
          maxPosition = row.position;
        }
      }
      return _db
          .into(_db.dictionaries)
          .insert(
            DictionariesCompanion.insert(
              name: name.trim(),
              format: cleanedFormat,
              path: path.trim(),
              targetLang: targetLang.trim().toLowerCase(),
              position: maxPosition + 1,
              wordCount: wordCount,
              importedAt: _clock.now().toUtc(),
            ),
          );
    });
  }

  /// Enables or disables a dictionary.
  Future<void> setEnabled(int id, bool enabled) async {
    await (_db.update(_db.dictionaries)..where((t) => t.id.equals(id))).write(
      DictionariesCompanion(enabled: Value(enabled)),
    );
  }

  /// Moves a dictionary [delta] slots in the priority order (-1 up, +1 down).
  Future<void> move(int id, int delta) async {
    if (delta == 0) {
      return;
    }
    await _db.transaction(() async {
      final List<UserDictionaryRow> rows =
          await (_db.select(_db.dictionaries)..orderBy([
                (t) => OrderingTerm(
                  expression: t.position,
                  mode: OrderingMode.asc,
                ),
                (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
              ]))
              .get();
      final int index = rows.indexWhere((row) => row.id == id);
      final int target = index + delta;
      if (index < 0 || target < 0 || target >= rows.length) {
        return;
      }
      final UserDictionaryRow moved = rows[index];
      final UserDictionaryRow neighbor = rows[target];
      await (_db.update(_db.dictionaries)..where((t) => t.id.equals(moved.id)))
          .write(DictionariesCompanion(position: Value(neighbor.position)));
      await (_db.update(_db.dictionaries)
            ..where((t) => t.id.equals(neighbor.id)))
          .write(DictionariesCompanion(position: Value(moved.position)));
    });
  }

  /// Removes a dictionary: the metadata row and, best-effort, its files.
  ///
  /// Only paths inside the dictionaries root are deleted (A-54): a row
  /// with a corrupted path must never delete arbitrary files. Remaining
  /// positions are compacted back to 0..n-1 (A-55).
  Future<void> remove(int id) async {
    final List<UserDictionaryRow> rows = await (_db.select(
      _db.dictionaries,
    )..where((t) => t.id.equals(id))).get();
    if (rows.isEmpty) {
      return;
    }
    await _db.transaction(() async {
      await (_db.delete(_db.dictionaries)..where((t) => t.id.equals(id))).go();
      await _normalizePositions();
    });
    await _disposeSource(id);
    try {
      final String rootPath = (await _files.root()).path;
      final String dictionaryPath = rows.single.path;
      if (p.isWithin(rootPath, dictionaryPath)) {
        await Directory(dictionaryPath).delete(recursive: true);
      }
    } catch (_) {
      // Best-effort: the row is gone even if the files cannot be deleted.
    }
  }

  /// Renumbers `position` to 0..n-1 in priority order.
  Future<void> _normalizePositions() async {
    final List<UserDictionaryRow> rows =
        await (_db.select(_db.dictionaries)..orderBy([
              (t) =>
                  OrderingTerm(expression: t.position, mode: OrderingMode.asc),
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
            ]))
            .get();
    for (int i = 0; i < rows.length; i++) {
      if (rows[i].position != i) {
        await (_db.update(_db.dictionaries)
              ..where((t) => t.id.equals(rows[i].id)))
            .write(DictionariesCompanion(position: Value(i)));
      }
    }
  }

  /// The highest-priority enabled dictionary's entry for [wordKey].
  ///
  /// Only dictionaries whose `target_lang` equals [targetLang] are
  /// consulted; a broken dictionary is skipped.
  @override
  Future<DictionaryEntry?> lookup(
    String wordKey, {
    required String targetLang,
  }) async {
    final String key = normalizeKey(wordKey);
    if (key.isEmpty) {
      return null;
    }
    final List<UserDictionaryRow> rows =
        await (_db.select(_db.dictionaries)
              ..where(
                (t) =>
                    t.enabled.equals(true) &
                    t.targetLang.equals(targetLang.trim().toLowerCase()),
              )
              ..orderBy([
                (t) => OrderingTerm(
                  expression: t.position,
                  mode: OrderingMode.asc,
                ),
                (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
              ]))
            .get();
    for (final UserDictionaryRow row in rows) {
      try {
        // Source creation is inside the try too: a dictionary that cannot
        // even be opened must not break the chain (A-53).
        final DictionaryService? source = _sourceFor(row);
        if (source == null) {
          continue;
        }
        final DictionaryEntry? entry = await source.lookup(key);
        if (entry != null) {
          return entry;
        }
      } catch (_) {
        // A broken dictionary must not break the chain.
      }
    }
    return null;
  }

  /// Releases the open dictionary files.
  Future<void> dispose() async {
    for (final DictionaryService source in _sources.values) {
      await source.dispose();
    }
    _sources.clear();
  }

  DictionaryService? _sourceFor(UserDictionaryRow row) {
    return _sources.putIfAbsent(row.id, () {
      switch (row.format) {
        case 'stardict':
          return StarDictSource(Directory(row.path));
        case 'dsl':
          return IndexDictionarySource(File(p.join(row.path, 'index.sqlite')));
        default:
          return EmptyDictionaryService();
      }
    });
  }

  Future<void> _disposeSource(int id) async {
    final DictionaryService? source = _sources.remove(id);
    await source?.dispose();
  }

  UserDictionary _toModel(UserDictionaryRow row) {
    return UserDictionary(
      id: row.id,
      name: row.name,
      format: row.format,
      path: row.path,
      targetLang: row.targetLang,
      enabled: row.enabled,
      position: row.position,
      wordCount: row.wordCount,
      importedAt: row.importedAt.toUtc(),
    );
  }
}
