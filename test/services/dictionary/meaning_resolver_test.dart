import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/meaning_resolver.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_dictionary_service.dart';
import '../../helpers/stardict_fixture.dart';
import '../../helpers/temp_dictionary_file_store.dart';

/// In-memory user-dictionary lookup fake.
class FakeUserDictionaryLookup implements UserDictionaryLookup {
  FakeUserDictionaryLookup([Map<String, String> entries = const {}])
    : _entries = Map<String, String>.of(entries);

  final Map<String, String> _entries;

  int lookups = 0;
  final List<String> targetLangs = [];

  @override
  Future<DictionaryEntry?> lookup(
    String wordKey, {
    required String targetLang,
  }) async {
    lookups++;
    targetLangs.add(targetLang);
    final String key = wordKey.trim().toLowerCase();
    final String? translation = _entries[key];
    if (key.isEmpty || translation == null) {
      return null;
    }
    return DictionaryEntry(textKey: key, translation: translation);
  }
}

/// Scripted LLM client for resolver tests.
class FakeLlm implements LlmClient {
  FakeLlm(this.script);

  final List<Object> script;
  final List<List<LlmMessage>> calls = [];
  int _index = 0;

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    calls.add(messages);
    if (_index >= script.length) {
      throw StateError('script exhausted');
    }
    final Object next = script[_index++];
    if (next is String) {
      return next;
    }
    throw next;
  }

  @override
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  late FakeDictionaryService bundle;
  late FakeConnectivityService connectivity;
  late UserDictionaryLookup userDictionaries;
  late FakeLlm llm;

  MeaningResolver resolver({String meaningLanguage = 'ru'}) {
    return MeaningResolver(
      dictionary: bundle,
      llm: llm,
      connectivity: connectivity,
      userDictionaries: userDictionaries,
      settings: MemorySettingsRepository(
        MemorySecureKeyStore(),
        meaningLanguage: meaningLanguage,
      ),
    );
  }

  setUp(() {
    bundle = FakeDictionaryService({'bank': 'банк, берег'});
    connectivity = FakeConnectivityService();
    userDictionaries = FakeUserDictionaryLookup();
    llm = FakeLlm(['{"lemma":"heifer","translation":"тёлка","pos":"noun"}']);
  });

  tearDown(() async {
    await connectivity.dispose();
  });

  group('MeaningResolver chain (5.12)', () {
    test('a user dictionary wins over the bundle', () async {
      userDictionaries = FakeUserDictionaryLookup({'bank': 'скамейка'});

      final DictionaryEntry? entry = await resolver().dictionaryEntry('Bank');

      expect(entry, isNotNull);
      expect(entry!.textKey, 'bank');
      expect(entry.translation, 'скамейка');
      expect(bundle.lookups, 0);
      expect(llm.calls, isEmpty);
    });

    test('the meaning language selects the user dictionaries', () async {
      final FakeUserDictionaryLookup fake = FakeUserDictionaryLookup({
        'cow': 'Kuh',
      });
      userDictionaries = fake;

      expect(await resolver(meaningLanguage: 'de').resolve('cow'), 'Kuh');
      expect(fake.targetLangs, ['de']);
      expect(bundle.lookups, 0);
    });

    test(
      'a missing user dictionary for the language skips the bundle',
      () async {
        final String? meaning = await resolver(
          meaningLanguage: 'de',
        ).resolve('bank');

        expect(meaning, 'тёлка');
        expect(bundle.lookups, 0);
        expect(llm.calls, hasLength(1));
        expect(llm.calls.single.first.content, contains('English-German'));
      },
    );

    test('a user miss falls through to the bundle', () async {
      userDictionaries = FakeUserDictionaryLookup({'cow': 'корова'});

      expect(await resolver().resolve('bank'), 'банк, берег');
      expect(bundle.lookups, 1);
      expect(llm.calls, isEmpty);
    });

    test('both local sources missing goes to the LLM when online', () async {
      final MeaningResolver meaningResolver = resolver();
      final String? meaning = await meaningResolver.resolve(
        'heifer',
        sentence: 'I saw a heifer.',
      );

      expect(meaning, 'тёлка');
      expect(llm.calls, hasLength(1));
      final List<LlmMessage> messages = llm.calls.single;
      expect(messages.first.content, contains('English-Russian'));
      expect(messages.first.content, contains('"translation"'));
      expect(messages.last.content, contains('Word: heifer'));

      // The LLM answer is cached for the session.
      expect(await meaningResolver.resolve('heifer'), 'тёлка');
      expect(llm.calls, hasLength(1));
    });

    test('the prompt uses the configured meaning language', () async {
      final String? meaning = await resolver(
        meaningLanguage: 'de',
      ).resolve('heifer');

      expect(meaning, 'тёлка');
      expect(llm.calls.single.first.content, contains('English-German'));
    });

    test('a meaning language change refetches from the LLM', () async {
      llm = FakeLlm([
        '{"lemma":"heifer","translation":"тёлка","pos":"noun"}',
        '{"lemma":"heifer","translation":"Färse","pos":"noun"}',
      ]);
      final MemorySettingsRepository settings = MemorySettingsRepository(
        MemorySecureKeyStore(),
      );
      final MeaningResolver meaningResolver = MeaningResolver(
        dictionary: bundle,
        llm: llm,
        connectivity: connectivity,
        userDictionaries: userDictionaries,
        settings: settings,
      );

      expect(await meaningResolver.resolve('heifer'), 'тёлка');
      expect(llm.calls, hasLength(1));
      expect(llm.calls.single.first.content, contains('English-Russian'));

      await settings.setMeaningLanguage('de');

      expect(await meaningResolver.resolve('heifer'), 'Färse');
      expect(llm.calls, hasLength(2));
      expect(llm.calls.last.first.content, contains('English-German'));
    });

    test('offline with both local sources missing resolves to null', () async {
      connectivity.setOnline(false);

      expect(await resolver().resolve('heifer'), isNull);
      expect(llm.calls, isEmpty);
    });

    test('a broken user dictionary falls through to the bundle', () async {
      userDictionaries = _ThrowingLookup();

      expect(await resolver().resolve('bank'), 'банк, берег');
    });

    test(
      'a real StarDict dictionary wins over the bundle end to end',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'parley_resolver_e2e',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final Directory dir = Directory('${tempDir.path}/d');
        await dir.create(recursive: true);
        await writeStarDict(dir: dir, entries: {'bank': 'скамейка'});
        final AppDatabase db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final UserDictionaryRepository repo = UserDictionaryRepository(
          db,
          clock: FakeClock(DateTime.utc(2026, 1, 1)),
          files: TempDictionaryFileStore(tempDir),
        );
        addTearDown(repo.dispose);
        await repo.add(
          name: 'user',
          path: dir.path,
          targetLang: 'ru',
          wordCount: 1,
        );
        userDictionaries = repo;

        final DictionaryEntry? entry = await resolver().dictionaryEntry('bank');
        expect(entry, isNotNull);
        expect(entry!.translation, 'скамейка');
        expect(bundle.lookups, 0);

        // Disabling the dictionary falls back to the bundle.
        await repo.setEnabled((await repo.watchAll().first).single.id, false);
        expect(await resolver().resolve('bank'), 'банк, берег');
        expect(bundle.lookups, 1);
      },
    );
  });
}

class _ThrowingLookup implements UserDictionaryLookup {
  @override
  Future<DictionaryEntry?> lookup(
    String wordKey, {
    required String targetLang,
  }) async {
    throw StateError('broken');
  }
}
