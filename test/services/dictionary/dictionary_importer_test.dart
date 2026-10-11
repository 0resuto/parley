import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:parley/data/db/database.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/services/dictionary/dictionary_importer.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/export/file_picker_service.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late UserDictionaryRepository repo;
  late DictionaryImporter importer;
  late Directory tempDir;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = UserDictionaryRepository(
      db,
      clock: FakeClock(DateTime.utc(2026, 1, 10, 12)),
    );
    importer = DictionaryImporter(dictionaries: repo);
    tempDir = await Directory.systemTemp.createTemp('parley_dict_test');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  PickedDictionaryFile csvFile(String name, String content) {
    return PickedDictionaryFile(
      path: p.join(tempDir.path, name),
      isSqlite: false,
      csvContent: content,
    );
  }

  Future<String> writeSqliteFile({
    required String name,
    required String ddl,
    required List<(String, String)> rows,
  }) async {
    final File file = File(p.join(tempDir.path, name));
    final NativeDatabase executor = NativeDatabase(file);
    await executor.ensureOpen(const DictionaryExecutorUser());
    await executor.runCustom(ddl);
    for (final (String key, String translation) in rows) {
      await executor.runInsert(
        'INSERT INTO entry (text_key, translation) VALUES (?, ?)',
        [key, translation],
      );
    }
    await executor.close();
    return file.path;
  }

  group('CSV dictionaries', () {
    test('parses, normalizes and stores the file', () async {
      final DictionaryImportSummary summary = await importer.importFile(
        csvFile(
          'My words.csv',
          '\uFEFFword;translation\r\n'
              'Cow;корова\r\n'
              '\r\n'
              'bank;банк, берег\r\n'
              'missing;   \r\n'
              'noTranslationOnly\r\n'
              'COW;бык\r\n',
        ),
      );

      expect(summary.name, 'My words');
      expect(summary.entryCount, 2);
      expect((await repo.lookup('cow'))!.translation, 'корова');
      expect((await repo.lookup('bank'))!.translation, 'банк, берег');
      expect(await repo.lookup('missing'), isNull);
      expect(await repo.lookup('noTranslationOnly'), isNull);
    });

    test(
      'accepts the text_key header and falls back to a default name',
      () async {
        final DictionaryImportSummary summary = await importer.importFile(
          csvFile('   .csv', 'text_key;translation\ncow;корова\n'),
        );

        expect(summary.name, 'Imported dictionary');
        expect(summary.entryCount, 1);
      },
    );

    test('a CSV without usable rows is rejected', () async {
      expect(
        () => importer.importFile(csvFile('empty.csv', 'word;translation\n')),
        throwsA(isA<DictionaryImportException>()),
      );
    });
  });

  group('SQLite dictionaries', () {
    test('reads an entry table, normalizing keys', () async {
      final String path = await writeSqliteFile(
        name: 'tools.sqlite',
        ddl: 'CREATE TABLE entry (text_key TEXT, translation TEXT)',
        rows: [('Cow', 'корова'), ('cow', 'бык'), ('bank', 'банк')],
      );

      final DictionaryImportSummary summary = await importer.importFile(
        PickedDictionaryFile(path: path, isSqlite: true),
      );

      expect(summary.name, 'tools');
      expect(summary.entryCount, 2);
      expect((await repo.lookup('cow'))!.translation, 'корова');
      expect((await repo.lookup('BANK'))!.translation, 'банк');
    });

    test('a file without an entry table is rejected', () async {
      final String path = await writeSqliteFile(
        name: 'other.sqlite',
        ddl: 'CREATE TABLE other (a TEXT)',
        rows: const [],
      );

      expect(
        () => importer.importFile(
          PickedDictionaryFile(path: path, isSqlite: true),
        ),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('an entry table without the needed columns is rejected', () async {
      final String path = await writeSqliteFile(
        name: 'broken.sqlite',
        ddl: 'CREATE TABLE entry (word TEXT, meaning TEXT)',
        rows: const [],
      );

      expect(
        () => importer.importFile(
          PickedDictionaryFile(path: path, isSqlite: true),
        ),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('a missing file is rejected', () async {
      expect(
        () => importer.importFile(
          PickedDictionaryFile(
            path: p.join(tempDir.path, 'nope.sqlite'),
            isSqlite: true,
          ),
        ),
        throwsA(isA<DictionaryImportException>()),
      );
    });
  });
}
