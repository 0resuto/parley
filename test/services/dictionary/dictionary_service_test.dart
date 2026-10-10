import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';

void main() {
  late NativeDatabase db;

  setUp(() async {
    db = NativeDatabase.memory();
    await db.ensureOpen(const DictionaryExecutorUser());
    await db.runCustom(
      'CREATE TABLE entry (text_key TEXT PRIMARY KEY, translation TEXT NOT NULL)',
    );
    await db.runCustom(
      'INSERT INTO entry (text_key, translation) VALUES (?, ?), (?, ?)',
      ['cow', 'корова, бык', 'bank', 'банк, склад'],
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('SqliteDictionaryService', () {
    test('finds an entry by normalized key', () async {
      final SqliteDictionaryService service = SqliteDictionaryService(db);

      final DictionaryEntry? entry = await service.lookup('  COW ');

      expect(entry, isNotNull);
      expect(entry!.textKey, 'cow');
      expect(entry.translation, 'корова, бык');
    });

    test('missing word returns null', () async {
      final SqliteDictionaryService service = SqliteDictionaryService(db);

      expect(await service.lookup('heifer'), isNull);
    });

    test('empty key returns null', () async {
      final SqliteDictionaryService service = SqliteDictionaryService(db);

      expect(await service.lookup('   '), isNull);
    });
  });

  group('EmptyDictionaryService', () {
    test('always misses and disposes cleanly', () async {
      final EmptyDictionaryService service = EmptyDictionaryService();

      expect(await service.lookup('cow'), isNull);
      await service.dispose();
    });
  });
}
