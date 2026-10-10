import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/chat/word_popup.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/translation/translation.dart';
import 'package:parley/services/tts/tts_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_dictionary_service.dart';
import '../../helpers/fake_unit_repository.dart';

class FakeTranslateLlm implements LlmClient {
  FakeTranslateLlm(this.script, {this.gate});

  final List<Object> script;

  /// When set, [complete] waits for it before returning the reply.
  final Completer<void>? gate;

  final List<List<LlmMessage>> calls = [];
  int _index = 0;

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    calls.add(messages);
    if (gate != null) {
      await gate!.future;
    }
    final Object next = _index < script.length ? script[_index++] : script.last;
    if (next is String) {
      return next;
    }
    if (next is AppFailure) {
      throw next;
    }
    throw StateError('Bad script entry: $next');
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
  late FakeClock clock;
  late FakeUnitRepository units;
  late FakeConnectivityService connectivity;
  late FakeTranslateLlm llm;
  late FakeDictionaryService dictionary;
  late FakeTtsService tts;
  late TranslationCache cache;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 4, 1, 12));
    units = FakeUnitRepository(clock: clock);
    connectivity = FakeConnectivityService();
    dictionary = FakeDictionaryService();
    tts = FakeTtsService();
    cache = TranslationCache();
    llm = FakeTranslateLlm(['unused']);
  });

  tearDown(() async {
    await connectivity.dispose();
    await tts.dispose();
  });

  Future<void> pumpPopup(
    WidgetTester tester, {
    required String surface,
    required String wordKey,
    required String sentence,
    Unit? initialUnit,
    SettingsRepository? settings,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(units),
          clockProvider.overrideWithValue(clock),
          connectivityServiceProvider.overrideWithValue(connectivity),
          dictionaryServiceProvider.overrideWithValue(dictionary),
          llmClientProvider.overrideWithValue(llm),
          ttsServiceProvider.overrideWithValue(tts),
          translationCacheProvider.overrideWithValue(cache),
          settingsRepositoryProvider.overrideWithValue(
            settings ?? MemorySettingsRepository(MemorySecureKeyStore()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: WordPopup(
              surface: surface,
              wordKey: wordKey,
              sentence: sentence,
              initialUnit: initialUnit,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('WordPopup 6.6', () {
    testWidgets('dictionary word shows the bundle meaning offline', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"x","translation_ru":"y","pos":"noun"}',
      ]);
      connectivity.setOnline(false);
      dictionary = FakeDictionaryService({'cow': 'корова'});
      final Unit created = await units.add(text: 'cow');

      await pumpPopup(
        tester,
        surface: 'cow',
        wordKey: 'cow',
        sentence: 'I see a cow.',
        initialUnit: created,
      );

      expect(find.byKey(const Key('wordPopupTitle')), findsOneWidget);
      expect(find.text('cow'), findsWidgets);
      expect(find.text('корова'), findsOneWidget);
      expect(find.byKey(const Key('wordPopupInDictionary')), findsOneWidget);
      expect(find.byKey(const Key('wordPopupAddButton')), findsNothing);
      expect(dictionary.lookups, greaterThanOrEqualTo(1));
      expect(llm.calls, isEmpty);
    });

    testWidgets('unknown word fetches and caches', (WidgetTester tester) async {
      llm = FakeTranslateLlm([
        '{"lemma":"heifer","translation_ru":"телка","pos":"noun"}',
      ]);

      await pumpPopup(
        tester,
        surface: 'heifer',
        wordKey: 'heifer',
        sentence: 'I saw a heifer.',
      );

      expect(find.text('телка'), findsOneWidget);
      expect(llm.calls, hasLength(1));
      // Translate request uses the verbatim system prompt and the sentence.
      final List<LlmMessage> first = llm.calls.single;
      expect(first, hasLength(2));
      expect(first[0].role, LlmRole.system);
      expect(first[0].content, translateSystemPrompt);
      expect(first[1].content, contains('Word: heifer'));
      expect(first[1].content, contains('I saw a heifer.'));
      expect(cache.get('heifer')?.translationRu, 'телка');
      // No contextual field in the reply: it falls back to the dictionary one.
      expect(cache.get('heifer')?.translationInContext, 'телка');

      // Second open with the same cache does not call the LLM again.
      await pumpPopup(
        tester,
        surface: 'heifer',
        wordKey: 'heifer',
        sentence: 'I saw a heifer.',
      );
      expect(find.text('телка'), findsOneWidget);
      expect(llm.calls, hasLength(1));
    });

    testWidgets('dictionary meaning first, in-sentence meaning second', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"bank","translation_ru":"банк","translation_in_context":"берег","pos":"noun"}',
      ]);

      await pumpPopup(
        tester,
        surface: 'bank',
        wordKey: 'bank',
        sentence: 'We sat on the river bank.',
      );

      expect(find.text('банк'), findsOneWidget);
      expect(find.text('In this sentence: берег'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('wordPopupTranslation'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('wordPopupTranslationContext')))
              .dy,
        ),
      );
    });

    testWidgets('hides the in-sentence line when the meanings match', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"cow","translation_ru":"корова","translation_in_context":"корова","pos":"noun"}',
      ]);

      await pumpPopup(
        tester,
        surface: 'cow',
        wordKey: 'cow',
        sentence: 'I see a cow.',
      );

      expect(find.text('корова'), findsOneWidget);
      expect(
        find.byKey(const Key('wordPopupTranslationContext')),
        findsNothing,
      );
    });

    testWidgets('Add saves the word spelling and forms, not a meaning', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"bank","translation_ru":"банк","translation_in_context":"берег","pos":"noun"}',
      ]);

      await pumpPopup(
        tester,
        surface: 'banks',
        wordKey: 'banks',
        sentence: 'We sat on the river banks.',
      );

      await tester.tap(find.byKey(const Key('wordPopupAddButton')));
      await tester.pumpAndSettle();

      final Unit? created = await units.findByKey('banks');
      expect(created, isNotNull);
      expect(created!.text, 'bank');
      expect(created.forms, contains('banks'));
    });

    testWidgets('bundle word shows offline without the LLM', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"x","translation_ru":"y","pos":"noun"}',
      ]);
      connectivity.setOnline(false);
      dictionary = FakeDictionaryService({'heifer': 'тёлка'});

      await pumpPopup(
        tester,
        surface: 'heifer',
        wordKey: 'heifer',
        sentence: 'I saw a heifer.',
      );

      expect(find.text('тёлка'), findsOneWidget);
      expect(find.text(wordPopupOfflineMessage), findsNothing);
      expect(find.byKey(const Key('wordPopupAiWarning')), findsNothing);
      expect(llm.calls, isEmpty);
      expect(dictionary.lookups, 1);
    });

    testWidgets('bundle word online adds the in-sentence line', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"bank","translation_ru":"банк","translation_in_context":"берег","pos":"noun"}',
      ]);
      dictionary = FakeDictionaryService({'bank': 'банк, склад'});

      await pumpPopup(
        tester,
        surface: 'bank',
        wordKey: 'bank',
        sentence: 'We sat on the river bank.',
      );

      expect(find.text('банк, склад'), findsOneWidget);
      expect(find.text('In this sentence: берег'), findsOneWidget);
      expect(find.byKey(const Key('wordPopupAiWarning')), findsNothing);
      expect(llm.calls, hasLength(1));
    });

    testWidgets('bundle meaning shows before the AI context arrives', (
      WidgetTester tester,
    ) async {
      final Completer<void> gate = Completer<void>();
      llm = FakeTranslateLlm([
        '{"lemma":"bank","translation_ru":"банк","translation_in_context":"берег","pos":"noun"}',
      ], gate: gate);
      dictionary = FakeDictionaryService({'bank': 'банк, склад'});

      await pumpPopup(
        tester,
        surface: 'bank',
        wordKey: 'bank',
        sentence: 'We sat on the river bank.',
      );

      expect(find.text('банк, склад'), findsOneWidget);
      expect(
        find.byKey(const Key('wordPopupTranslationContext')),
        findsNothing,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(llm.calls, hasLength(1));

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('In this sentence: берег'), findsOneWidget);
    });

    testWidgets('context translation off skips the AI call for bundle words', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"bank","translation_ru":"банк","translation_in_context":"берег","pos":"noun"}',
      ]);
      dictionary = FakeDictionaryService({'bank': 'банк, склад'});

      await pumpPopup(
        tester,
        surface: 'bank',
        wordKey: 'bank',
        sentence: 'We sat on the river bank.',
        settings: MemorySettingsRepository(
          MemorySecureKeyStore(),
          contextTranslation: false,
        ),
      );

      expect(find.text('банк, склад'), findsOneWidget);
      expect(
        find.byKey(const Key('wordPopupTranslationContext')),
        findsNothing,
      );
      expect(llm.calls, isEmpty);
    });

    testWidgets('context translation off hides the AI contextual line', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"heifer","translation_ru":"тёлка","translation_in_context":"тёлочка","pos":"noun"}',
      ]);
      dictionary = FakeDictionaryService();

      await pumpPopup(
        tester,
        surface: 'heifer',
        wordKey: 'heifer',
        sentence: 'I saw a heifer.',
        settings: MemorySettingsRepository(
          MemorySecureKeyStore(),
          contextTranslation: false,
        ),
      );

      expect(find.text('тёлка'), findsOneWidget);
      expect(
        find.byKey(const Key('wordPopupTranslationContext')),
        findsNothing,
      );
      expect(llm.calls, hasLength(1));
    });

    testWidgets('missing word is marked AI-generated and explains on tap', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"heifer","translation_ru":"тёлка","pos":"noun"}',
      ]);
      dictionary = FakeDictionaryService();

      await pumpPopup(
        tester,
        surface: 'heifer',
        wordKey: 'heifer',
        sentence: 'I saw a heifer.',
      );

      expect(find.text('тёлка'), findsOneWidget);
      expect(find.byKey(const Key('wordPopupAiWarning')), findsOneWidget);

      await tester.tap(find.byKey(const Key('wordPopupAiWarning')));
      await tester.pumpAndSettle();

      expect(find.text('AI-generated translation'), findsOneWidget);
      expect(
        find.textContaining('not in the bundled dictionary'),
        findsOneWidget,
      );
    });

    testWidgets('Add saves the bundle translation offline', (
      WidgetTester tester,
    ) async {
      connectivity.setOnline(false);
      dictionary = FakeDictionaryService({'banks': 'банки'});

      await pumpPopup(
        tester,
        surface: 'banks',
        wordKey: 'banks',
        sentence: 'We sat on the river banks.',
      );

      expect(find.text('банки'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wordPopupAddButton')));
      await tester.pumpAndSettle();

      final Unit? created = await units.findByKey('banks');
      expect(created, isNotNull);
      expect(created!.text, 'banks');
      expect(llm.calls, isEmpty);
    });

    testWidgets('Add saves the bundle spelling, not the tapped capital', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"Nice","translation_ru":"милый","translation_in_context":"милая","pos":"adj"}',
      ]);
      dictionary = FakeDictionaryService({
        'nice': 'милый, приятный, симпатичный',
      });

      await pumpPopup(
        tester,
        surface: 'Nice',
        wordKey: 'nice',
        sentence: 'Nice to meet you.',
      );

      expect(find.text('милый, приятный, симпатичный'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wordPopupAddButton')));
      await tester.pumpAndSettle();

      final Unit? created = await units.findByKey('nice');
      expect(created, isNotNull);
      expect(created!.text, 'nice');
    });

    testWidgets('offline shows message and Add still works', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"x","translation_ru":"y","pos":"noun"}',
      ]);
      connectivity.setOnline(false);

      await pumpPopup(
        tester,
        surface: 'heifer',
        wordKey: 'heifer',
        sentence: 'I saw a heifer.',
      );

      expect(find.text(wordPopupOfflineMessage), findsOneWidget);
      expect(llm.calls, isEmpty);
      expect(find.byKey(const Key('wordPopupAddButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('wordPopupAddButton')));
      await tester.pumpAndSettle();

      final Unit? created = await units.findByKey('heifer');
      expect(created, isNotNull);
      expect(find.byKey(const Key('wordPopupInDictionary')), findsOneWidget);
    });

    testWidgets('Add creates the unit with the right forms', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"cow","translation_ru":"корова","pos":"noun"}',
      ]);

      await pumpPopup(
        tester,
        surface: 'COWS',
        wordKey: 'cows',
        sentence: 'I love COWS a lot.',
      );

      expect(find.text('корова'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wordPopupAddButton')));
      await tester.pumpAndSettle();

      final Unit? byForm = await units.findByKey('cows');
      expect(byForm, isNotNull);
      expect(byForm!.text, 'cow');
      expect(byForm.forms, contains('cows'));
      final Unit? byLemma = await units.findByKey('cow');
      expect(byLemma, isNotNull);
      expect(byLemma!.id, byForm.id);
      expect(find.byKey(const Key('wordPopupInDictionary')), findsOneWidget);
    });

    testWidgets('Mark as known creates the unit straight into Known', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm(['unused']);
      connectivity.setOnline(false);
      dictionary = FakeDictionaryService({'heifer': 'тёлка'});

      await pumpPopup(
        tester,
        surface: 'Heifer',
        wordKey: 'heifer',
        sentence: 'I saw a heifer.',
      );

      await tester.tap(find.byKey(const Key('wordPopupMarkKnownButton')));
      await tester.pumpAndSettle();

      final Unit? created = await units.findByKey('heifer');
      expect(created, isNotNull);
      expect(created!.text, 'heifer');
      expect(statusOf(created), UnitStatus.known);
      expect(find.byKey(const Key('wordPopupInDictionary')), findsOneWidget);
      expect(find.text('Known'), findsOneWidget);
      expect(llm.calls, isEmpty);
    });

    testWidgets('Mark as known flips an existing unit', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm(['unused']);
      connectivity.setOnline(false);
      final Unit created = await units.add(text: 'cow');

      await pumpPopup(
        tester,
        surface: 'cow',
        wordKey: 'cow',
        sentence: 'I see a cow.',
        initialUnit: created,
      );

      expect(find.text('Mark as known'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wordPopupMarkKnownButton')));
      await tester.pumpAndSettle();

      final Unit? updated = await units.findByKey('cow');
      expect(updated, isNotNull);
      expect(statusOf(updated!), UnitStatus.known);
      expect(find.text('Known'), findsOneWidget);
      expect(find.text('Mark as known'), findsNothing);
    });

    testWidgets('a Known word shows the disabled Known button', (
      WidgetTester tester,
    ) async {
      connectivity.setOnline(false);
      final Unit created = await units.add(text: 'cow');
      final Unit? known = await units.setKnown(created.id, true);

      await pumpPopup(
        tester,
        surface: 'cow',
        wordKey: 'cow',
        sentence: 'I see a cow.',
        initialUnit: known,
      );

      final Finder button = find.byKey(const Key('wordPopupMarkKnownButton'));
      expect(button, findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      expect(find.text('Known'), findsOneWidget);
    });

    testWidgets('Speak calls TtsService with the tapped word', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"x","translation_ru":"y","pos":"noun"}',
      ]);
      connectivity.setOnline(false);
      final Unit created = await units.add(text: 'cow');

      await pumpPopup(
        tester,
        surface: 'cow',
        wordKey: 'cow',
        sentence: 'I see a cow.',
        initialUnit: created,
      );

      await tester.tap(find.byKey(const Key('wordPopupSpeakButton')));
      await tester.pumpAndSettle();

      expect(tts.spokenTexts, ['cow']);
    });
  });
}
