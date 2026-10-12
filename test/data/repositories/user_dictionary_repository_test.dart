import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:parley/data/db/database.dart';
import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/dsl/dsl_index.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/stardict_fixture.dart';
import '../../helpers/temp_dictionary_file_store.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UserDictionaryRepository repo;
  late Directory tempDir;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    tempDir = await Directory.systemTemp.createTemp('parley_dicts');
    repo = UserDictionaryRepository(
      db,
      clock: clock,
      files: TempDictionaryFileStore(tempDir),
    );
  });

  tearDown(() async {
    await repo.dispose();
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<String> makeDictionary(
    String name, {
    required Map<String, String> entries,
    String bookName = 'Book',
  }) async {
    final Directory dir = Directory('${tempDir.path}/$name');
    await dir.create(recursive: true);
    return writeStarDict(dir: dir, entries: entries, bookName: bookName);
  }

  Future<int> addDictionary(
    String name, {
    required String targetLang,
    required Map<String, String> entries,
  }) async {
    final String ifoPath = await makeDictionary(name, entries: entries);
    return repo.add(
      name: name,
      path: File(ifoPath).parent.path,
      targetLang: targetLang,
      wordCount: entries.length,
    );
  }

  group('add', () {
    test('stores metadata with clock, lowest priority and enabled', () async {
      final int id = await addDictionary(
        'first',
        targetLang: 'RU',
        entries: {'cow': 'корова'},
      );

      final List<UserDictionary> all = await repo.watchAll().first;
      expect(all, hasLength(1));
      expect(all.single.id, id);
      expect(all.single.name, 'first');
      expect(all.single.format, 'stardict');
      expect(all.single.targetLang, 'ru');
      expect(all.single.enabled, isTrue);
      expect(all.single.position, 0);
      expect(all.single.wordCount, 1);
      expect(all.single.importedAt, clock.now());
    });

    test('rejects blank metadata', () async {
      expect(
        () => repo.add(name: ' ', path: 'x', targetLang: 'ru', wordCount: 1),
        throwsArgumentError,
      );
      expect(
        () => repo.add(name: 'x', path: '', targetLang: 'ru', wordCount: 1),
        throwsArgumentError,
      );
      expect(
        () => repo.add(name: 'x', path: 'p', targetLang: ' ', wordCount: 1),
        throwsArgumentError,
      );
      expect(
        () => repo.add(name: 'x', path: 'p', targetLang: 'ru', wordCount: 0),
        throwsArgumentError,
      );
    });

    test('rejects a blank format (A-53)', () async {
      expect(
        () => repo.add(
          name: 'x',
          path: 'p',
          targetLang: 'ru',
          wordCount: 1,
          format: '  ',
        ),
        throwsArgumentError,
      );

      // Nothing was stored.
      expect(await repo.watchAll().first, isEmpty);
    });

    test('a duplicate path is rejected by the schema (A-55)', () async {
      await addDictionary(
        'first',
        targetLang: 'ru',
        entries: {'cow': 'корова'},
      );
      final String path = (await repo.watchAll().first).single.path;

      expect(
        () =>
            repo.add(name: 'copy', path: path, targetLang: 'ru', wordCount: 1),
        throwsA(isA<SqliteException>()),
      );
      expect(await repo.watchAll().first, hasLength(1));
    });
  });

  group('lookup', () {
    test('reads the entry from the dictionary files, normalized', () async {
      await addDictionary(
        'first',
        targetLang: 'ru',
        entries: {'cow': 'корова', 'bank': 'банк'},
      );

      final DictionaryEntry? entry = await repo.lookup(
        '  COW ',
        targetLang: 'ru',
      );
      expect(entry, isNotNull);
      expect(entry!.textKey, 'cow');
      expect(entry.translation, 'корова');
      expect(await repo.lookup('heifer', targetLang: 'ru'), isNull);
      expect(await repo.lookup('   ', targetLang: 'ru'), isNull);
    });

    test(
      'only dictionaries for the requested language are consulted',
      () async {
        await addDictionary('ru', targetLang: 'ru', entries: {'cow': 'корова'});
        await addDictionary('de', targetLang: 'de', entries: {'cow': 'Kuh'});

        expect(
          (await repo.lookup('cow', targetLang: 'ru'))!.translation,
          'корова',
        );
        expect(
          (await repo.lookup('cow', targetLang: 'de'))!.translation,
          'Kuh',
        );
        expect(await repo.lookup('cow', targetLang: 'fr'), isNull);
      },
    );

    test(
      'the earlier dictionary wins and disabling promotes the next',
      () async {
        final int first = await addDictionary(
          'first',
          targetLang: 'ru',
          entries: {'cow': 'корова'},
        );
        await addDictionary(
          'second',
          targetLang: 'ru',
          entries: {'cow': 'бык'},
        );

        expect(
          (await repo.lookup('cow', targetLang: 'ru'))!.translation,
          'корова',
        );

        await repo.setEnabled(first, false);
        expect(
          (await repo.lookup('cow', targetLang: 'ru'))!.translation,
          'бык',
        );
      },
    );

    test('a dictionary without the word falls through to the next', () async {
      await addDictionary('first', targetLang: 'ru', entries: {'bank': 'банк'});
      await addDictionary(
        'second',
        targetLang: 'ru',
        entries: {'cow': 'корова'},
      );

      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
    });

    test('a broken dictionary is skipped without breaking the chain', () async {
      await repo.add(
        name: 'broken',
        path: '${tempDir.path}/missing',
        targetLang: 'ru',
        wordCount: 1,
      );
      await addDictionary('good', targetLang: 'ru', entries: {'cow': 'корова'});

      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
    });

    test('reads a DSL dictionary through its index cache', () async {
      final Directory dir = Directory('${tempDir.path}/dsl');
      await dir.create(recursive: true);
      final String dslPath = await writeDsl(
        dir: dir,
        entries: {'cow': 'корова'},
        transcriptions: {'cow': 'kaʊ'},
      );
      await buildDslIndexCache(
        dslFile: File(dslPath),
        cacheFile: File(p.join(dir.path, 'index.sqlite')),
      );
      await repo.add(
        name: 'dsl',
        path: dir.path,
        targetLang: 'ru',
        wordCount: 1,
        format: 'dsl',
      );

      final DictionaryEntry? entry = await repo.lookup('cow', targetLang: 'ru');
      expect(entry, isNotNull);
      expect(entry!.translation, 'корова');
      expect(entry.transcription, 'kaʊ');
    });

    test('move changes the priority order', () async {
      await addDictionary(
        'first',
        targetLang: 'ru',
        entries: {'cow': 'корова'},
      );
      final int second = await addDictionary(
        'second',
        targetLang: 'ru',
        entries: {'cow': 'бык'},
      );

      await repo.move(second, -1);

      expect((await repo.lookup('cow', targetLang: 'ru'))!.translation, 'бык');
      final List<UserDictionary> all = await repo.watchAll().first;
      expect(all.map((d) => d.name).toList(), ['second', 'first']);
    });

    test('move at the edges is a no-op', () async {
      final int only = await addDictionary(
        'only',
        targetLang: 'ru',
        entries: {'cow': 'корова'},
      );

      await repo.move(only, -1);
      await repo.move(only, 1);

      expect((await repo.watchAll().first).single.position, 0);
    });
  });

  group('remove', () {
    test('removes the row and the dictionary files', () async {
      final int id = await addDictionary(
        'first',
        targetLang: 'ru',
        entries: {'cow': 'корова'},
      );
      final String path = (await repo.watchAll().first).single.path;

      await repo.remove(id);

      expect(await repo.watchAll().first, isEmpty);
      expect(await Directory(path).exists(), isFalse);
      expect(await repo.lookup('cow', targetLang: 'ru'), isNull);
    });

    test('a path outside the dictionaries root is kept (A-54)', () async {
      final Directory outside = await Directory.systemTemp.createTemp(
        'parley_outside',
      );
      addTearDown(() async {
        if (await outside.exists()) {
          await outside.delete(recursive: true);
        }
      });
      final int id = await repo.add(
        name: 'corrupt',
        path: outside.path,
        targetLang: 'ru',
        wordCount: 1,
      );

      await repo.remove(id);

      // The row is gone, but the arbitrary directory was not touched.
      expect(await repo.watchAll().first, isEmpty);
      expect(await outside.exists(), isTrue);
    });

    test('positions are compacted after remove (A-55)', () async {
      await addDictionary('first', targetLang: 'ru', entries: {'cow': 'a'});
      final int second = await addDictionary(
        'second',
        targetLang: 'ru',
        entries: {'cow': 'b'},
      );
      await addDictionary('third', targetLang: 'ru', entries: {'cow': 'c'});
      expect((await repo.watchAll().first).map((d) => d.position).toList(), [
        0,
        1,
        2,
      ]);

      await repo.remove(second);

      final List<UserDictionary> left = await repo.watchAll().first;
      expect(left.map((d) => d.name).toList(), ['first', 'third']);
      expect(left.map((d) => d.position).toList(), [0, 1]);
    });
  });
}
