import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/dictionary/word_meaning.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/meaning_resolver.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_connectivity_service.dart';

class _NoLlm implements LlmClient {
  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    throw UnimplementedError();
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

class _NoUserDictionaries implements UserDictionaryLookup {
  @override
  Future<DictionaryEntry?> lookup(
    String wordKey, {
    required String targetLang,
  }) async => null;
}

/// Resolver whose lookups are scripted by the test (A-28).
class ScriptedResolver extends MeaningResolver {
  ScriptedResolver(this.handler)
    : super(
        dictionary: EmptyDictionaryService(),
        llm: _NoLlm(),
        connectivity: FakeConnectivityService(),
        userDictionaries: _NoUserDictionaries(),
        settings: MemorySettingsRepository(MemorySecureKeyStore()),
      );

  final Future<DictionaryEntry?> Function(String textKey) handler;

  @override
  Future<DictionaryEntry?> dictionaryEntry(String textKey) => handler(textKey);
}

/// Rebuilds [WordMeaning] with the listenable's value, so a key change
/// updates the existing state (didUpdateWidget) instead of remounting.
class _Host extends StatelessWidget {
  const _Host(this.textKey);

  final ValueListenable<String> textKey;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: textKey,
      builder: (BuildContext context, String value, Widget? child) {
        return WordMeaning(textKey: value);
      },
    );
  }
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    ScriptedResolver resolver,
    Stream<List<UserDictionary>> dictionaries,
    ValueListenable<String> textKey,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meaningResolverProvider.overrideWithValue(resolver),
          userDictionariesProvider.overrideWith((ref) => dictionaries),
        ],
        child: MaterialApp(home: Scaffold(body: _Host(textKey))),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a slow old lookup cannot overwrite a newer word', (
    WidgetTester tester,
  ) async {
    final Completer<DictionaryEntry?> gate = Completer<DictionaryEntry?>();
    final ScriptedResolver resolver = ScriptedResolver((String key) {
      if (key == 'cow') {
        return gate.future;
      }
      return Future<DictionaryEntry?>.value(
        const DictionaryEntry(textKey: 'milk', translation: 'молоко'),
      );
    });
    final ValueNotifier<String> textKey = ValueNotifier<String>('cow');

    await pump(
      tester,
      resolver,
      Stream<List<UserDictionary>>.value(const <UserDictionary>[]),
      textKey,
    );
    expect(find.text('корова'), findsNothing);
    expect(find.text('молоко'), findsNothing);

    // The widget now shows another word; its lookup answers immediately.
    textKey.value = 'milk';
    await tester.pumpAndSettle();
    expect(find.text('молоко'), findsOneWidget);

    // The stale 'cow' answer arrives late and must be ignored.
    gate.complete(const DictionaryEntry(textKey: 'cow', translation: 'корова'));
    await tester.pumpAndSettle();

    expect(find.text('молоко'), findsOneWidget);
    expect(find.text('корова'), findsNothing);
  });

  testWidgets('dictionary changes re-resolve the meaning', (
    WidgetTester tester,
  ) async {
    final StreamController<List<UserDictionary>> dictionaries =
        StreamController<List<UserDictionary>>.broadcast();
    String translation = 'старое';
    final ScriptedResolver resolver = ScriptedResolver((String key) async {
      return DictionaryEntry(textKey: key, translation: translation);
    });
    final ValueNotifier<String> textKey = ValueNotifier<String>('cow');

    await pump(tester, resolver, dictionaries.stream, textKey);
    dictionaries.add(const <UserDictionary>[]);
    await tester.pumpAndSettle();
    expect(find.text('старое'), findsOneWidget);

    // A dictionary is disabled/removed/imported: the resolver chain
    // changes and the shown meaning must follow.
    translation = 'новое';
    dictionaries.add(<UserDictionary>[
      UserDictionary(
        id: 1,
        name: 'Test',
        format: 'stardict',
        path: '/tmp/dict',
        targetLang: 'ru',
        enabled: true,
        position: 0,
        wordCount: 1,
        importedAt: DateTime.utc(2026, 1, 10),
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('новое'), findsOneWidget);
    expect(find.text('старое'), findsNothing);

    await dictionaries.close();
  });
}
