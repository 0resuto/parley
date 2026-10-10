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
import 'package:parley/services/tts/tts_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_unit_repository.dart';

class FakeTranslateLlm implements LlmClient {
  FakeTranslateLlm(this.script);

  final List<Object> script;
  final List<List<LlmMessage>> calls = [];
  int _index = 0;

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    calls.add(messages);
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
  late FakeTtsService tts;
  late TranslationCache cache;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 4, 1, 12));
    units = FakeUnitRepository(clock: clock);
    connectivity = FakeConnectivityService();
    tts = FakeTtsService();
    cache = TranslationCache();
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
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(units),
          clockProvider.overrideWithValue(clock),
          connectivityServiceProvider.overrideWithValue(connectivity),
          llmClientProvider.overrideWithValue(llm),
          ttsServiceProvider.overrideWithValue(tts),
          translationCacheProvider.overrideWithValue(cache),
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
    testWidgets('dictionary word shows stored translation offline', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"x","translation_ru":"y","pos":"noun"}',
      ]);
      connectivity.setOnline(false);
      final Unit created = await units.add(
        text: 'cow',
        translationRu: 'корова',
      );
      final Unit? stored = await units.findByKey('cow');

      await pumpPopup(
        tester,
        surface: 'cow',
        wordKey: 'cow',
        sentence: 'I see a cow.',
        initialUnit: stored ?? created,
      );

      expect(find.byKey(const Key('wordPopupTitle')), findsOneWidget);
      expect(find.text('cow'), findsWidgets);
      expect(find.text('корова'), findsOneWidget);
      expect(find.byKey(const Key('wordPopupInDictionary')), findsOneWidget);
      expect(find.byKey(const Key('wordPopupAddButton')), findsNothing);
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
      expect(created!.translationRu, isEmpty);
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
      expect(byForm.translationRu, 'корова');
      expect(byForm.forms, contains('cows'));
      final Unit? byLemma = await units.findByKey('cow');
      expect(byLemma, isNotNull);
      expect(byLemma!.id, byForm.id);
      expect(find.byKey(const Key('wordPopupInDictionary')), findsOneWidget);
    });

    testWidgets('Speak calls TtsService with the tapped word', (
      WidgetTester tester,
    ) async {
      llm = FakeTranslateLlm([
        '{"lemma":"x","translation_ru":"y","pos":"noun"}',
      ]);
      connectivity.setOnline(false);
      final Unit created = await units.add(
        text: 'cow',
        translationRu: 'корова',
      );

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
