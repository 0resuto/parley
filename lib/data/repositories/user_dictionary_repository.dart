import 'package:drift/drift.dart';
import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';

/// Storage for imported user dictionaries (SPEC 5.12).
///
/// Entries live in the app database, so enabling, reordering and removing
/// a dictionary is a local transaction; a removal cascades to its entries.
class UserDictionaryRepository implements UserDictionaryLookup {
  UserDictionaryRepository(this._db, {required Clock clock}) : _clock = clock;

  final AppDatabase _db;
  final Clock _clock;

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

  /// Stores a new dictionary with [entries], at the lowest priority.
  ///
  /// Returns the new dictionary id. Duplicate keys inside [entries] keep
  /// the first occurrence (the table is unique on `(dictionary_id, text_key)`).
  Future<int> importEntries({
    required String name,
    required List<({String textKey, String translation})> entries,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('name is required');
    }
    if (entries.isEmpty) {
      throw ArgumentError('entries is required');
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
      final int id = await _db
          .into(_db.dictionaries)
          .insert(
            DictionariesCompanion.insert(
              name: name.trim(),
              position: maxPosition + 1,
              entryCount: entries.length,
              importedAt: _clock.now().toUtc(),
            ),
          );
      await _db.batch((batch) {
        batch.insertAll(_db.dictionaryEntries, [
          for (final ({String textKey, String translation}) entry in entries)
            DictionaryEntriesCompanion.insert(
              dictionaryId: id,
              textKey: entry.textKey,
              translation: entry.translation,
            ),
        ], mode: InsertMode.insertOrIgnore);
      });
      return id;
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

  /// Removes a dictionary (its entries cascade).
  Future<void> remove(int id) async {
    await (_db.delete(_db.dictionaries)..where((t) => t.id.equals(id))).go();
  }

  /// The highest-priority enabled dictionary's entry for [wordKey].
  @override
  Future<DictionaryEntry?> lookup(String wordKey) async {
    final String key = normalizeKey(wordKey);
    if (key.isEmpty) {
      return null;
    }
    final JoinedSelectStatement<HasResultSet, dynamic> query =
        _db.select(_db.dictionaryEntries).join([
            innerJoin(
              _db.dictionaries,
              _db.dictionaries.id.equalsExp(_db.dictionaryEntries.dictionaryId),
            ),
          ])
          ..where(
            _db.dictionaryEntries.textKey.equals(key) &
                _db.dictionaries.enabled.equals(true),
          )
          ..orderBy([
            OrderingTerm(
              expression: _db.dictionaries.position,
              mode: OrderingMode.asc,
            ),
            OrderingTerm(
              expression: _db.dictionaries.id,
              mode: OrderingMode.asc,
            ),
          ])
          ..limit(1);
    final TypedResult? row = await query.getSingleOrNull();
    if (row == null) {
      return null;
    }
    final DictionaryEntryRow entry = row.readTable(_db.dictionaryEntries);
    return DictionaryEntry(
      textKey: entry.textKey,
      translation: entry.translation,
    );
  }

  UserDictionary _toModel(UserDictionaryRow row) {
    return UserDictionary(
      id: row.id,
      name: row.name,
      enabled: row.enabled,
      position: row.position,
      entryCount: row.entryCount,
      importedAt: row.importedAt.toUtc(),
    );
  }
}
