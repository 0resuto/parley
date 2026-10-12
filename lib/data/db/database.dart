import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Units, Reviews, Conversations, Messages, Dictionaries])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        // 19.1: meanings resolve live from the active sources, so units no
        // longer store a translation. drift keeps foreign keys off while
        // the table is recreated, so review history is preserved.
        await m.alterTable(TableMigration(units));
      }
      if (from < 3) {
        // 20.1: metadata-only dictionary rows (a v1/v2 database goes
        // straight to the current shape).
        await m.createTable(dictionaries);
      }
      if (from == 3) {
        // 20.1: 19.2 stored dictionary entries in the app database; that
        // feature never shipped, so the tables are recreated empty. The
        // dictionary files themselves are imported again.
        await customStatement('DROP TABLE IF EXISTS dictionary_entries');
        await customStatement('DROP TABLE IF EXISTS dictionaries');
        await m.createTable(dictionaries);
      }
      if (from < 5) {
        // A-52: indexes for the hot queries. Runs after any table
        // recreation above, so the indexes survive re-created tables.
        await m.createIndex(unitsDue);
        await m.createIndex(reviewsUnitId);
        await m.createIndex(messagesConversationId);
        await m.createIndex(dictionariesLookup);
      }
      if (from < 6) {
        // A-55: one dictionary per path. A manually edited database could
        // contain duplicates; it keeps working without the constraint
        // instead of failing to open.
        final List<QueryRow> duplicatePaths = await customSelect(
          'SELECT path FROM dictionaries GROUP BY path HAVING COUNT(*) > 1',
        ).get();
        if (duplicatePaths.isEmpty) {
          await m.createIndex(dictionariesPath);
        }
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(driftDatabase(name: 'parley'));
  ref.onDispose(db.close);
  return db;
});
