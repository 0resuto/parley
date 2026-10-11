import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UserDictionaryRepository repo;
  final DateTime initial = DateTime.utc(2026, 1, 10, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    repo = UserDictionaryRepository(db, clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> importDict(String name, Map<String, String> entries) {
    return repo.importEntries(
      name: name,
      entries: [
        for (final MapEntry<String, String> e in entries.entries)
          (textKey: e.key, translation: e.value),
      ],
    );
  }

  group('importEntries', () {
    test('stores metadata and entries, normalizing lookups', () async {
      final int id = await importDict('My words', {
        'cow': 'корова',
        'bank': 'банк, берег',
      });

      final List<UserDictionary> all = await repo.watchAll().first;
      expect(all, hasLength(1));
      expect(all.single.id, id);
      expect(all.single.name, 'My words');
      expect(all.single.enabled, isTrue);
      expect(all.single.position, 0);
      expect(all.single.entryCount, 2);
      expect(all.single.importedAt, initial);

      final DictionaryEntry? entry = await repo.lookup('  COW ');
      expect(entry, isNotNull);
      expect(entry!.textKey, 'cow');
      expect(entry.translation, 'корова');
    });

    test('rejects an empty name or empty entries', () async {
      expect(
        () => repo.importEntries(
          name: '  ',
          entries: const [(textKey: 'cow', translation: 'корова')],
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.importEntries(name: 'x', entries: const []),
        throwsArgumentError,
      );
    });

    test('duplicate keys inside one file keep the first occurrence', () async {
      await repo.importEntries(
        name: 'dupes',
        entries: const [
          (textKey: 'cow', translation: 'корова'),
          (textKey: 'cow', translation: 'бык'),
        ],
      );

      expect((await repo.lookup('cow'))!.translation, 'корова');
      expect((await repo.watchAll().first).single.entryCount, 2);
    });
  });

  group('lookup priority', () {
    test(
      'the earlier import wins and disabling it promotes the next',
      () async {
        final int first = await importDict('first', {'cow': 'корова'});
        await importDict('second', {'cow': 'бык'});

        expect((await repo.lookup('cow'))!.translation, 'корова');

        await repo.setEnabled(first, false);
        expect((await repo.lookup('cow'))!.translation, 'бык');
      },
    );

    test('a dictionary without the word falls through to the next', () async {
      await importDict('first', {'bank': 'банк'});
      await importDict('second', {'cow': 'корова'});

      expect((await repo.lookup('cow'))!.translation, 'корова');
      expect(await repo.lookup('heifer'), isNull);
    });

    test('move changes the priority order', () async {
      await importDict('first', {'cow': 'корова'});
      final int second = await importDict('second', {'cow': 'бык'});

      await repo.move(second, -1);

      expect((await repo.lookup('cow'))!.translation, 'бык');
      final List<UserDictionary> all = await repo.watchAll().first;
      expect(all.map((d) => d.name).toList(), ['second', 'first']);
    });

    test('move at the edges is a no-op', () async {
      final int only = await importDict('only', {'cow': 'корова'});

      await repo.move(only, -1);
      await repo.move(only, 1);

      expect((await repo.watchAll().first).single.position, 0);
    });

    test('empty and blank keys miss', () async {
      await importDict('words', {'cow': 'корова'});

      expect(await repo.lookup('   '), isNull);
      expect(await repo.lookup('!!!'), isNull);
    });
  });

  group('remove', () {
    test('removes the dictionary and cascades to its entries', () async {
      final int first = await importDict('first', {'cow': 'корова'});
      await importDict('second', {'cow': 'бык'});

      await repo.remove(first);

      final List<UserDictionary> all = await repo.watchAll().first;
      expect(all.map((d) => d.name).toList(), ['second']);
      expect((await repo.lookup('cow'))!.translation, 'бык');
    });
  });
}
