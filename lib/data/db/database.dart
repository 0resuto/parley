import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Units,
    Reviews,
    Conversations,
    Messages,
    Dictionaries,
    DictionaryEntries,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 3;

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
        // 19.2: user dictionaries live in the app database.
        await m.createTable(dictionaries);
        await m.createTable(dictionaryEntries);
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
