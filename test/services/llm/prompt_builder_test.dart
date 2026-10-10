import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/llm/prompt_builder.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_clock.dart';

const String _baseWith10 =
    'You are the user\'s English conversation partner inside a language-learning app.\n'
    'Write ONLY in English.\n'
    'Be like a friendly, experienced English teacher who is also a good friend: natural, warm, curious, a bit playful. Never sound like a textbook or a quiz.\n'
    'Keep replies short (usually 1-4 sentences) and move the conversation forward.\n'
    'Correct mistakes the way a skilled teacher or a close friend would: only when it helps, lightly and in the flow of the conversation. Never lecture or list errors unless the user asks.\n'
    'Use plain text. No markdown headings, bullet lists or emojis unless the user asks for them.\n'
    'Vocabulary: assume the general vocabulary of the user\'s current level (see the language profile in NOTES) is known. TARGET WORDS are words the user is learning: steer the conversation so they come up naturally. Never list them, define them unprompted, or quiz the user on them. Aim for about 10% of the content words in your replies to be unfamiliar or target words; the rest should be words the user already knows.\n'
    'When you deliberately use a word that is probably new to the user and is NOT in TARGET WORDS, wrap it in double square brackets, like [[heifer]] (at most 2 per reply). Do not bracket target words or recently known words.\n'
    'If the user asks what a word means, explain it simply in English using words they know, with a short example.\n'
    'Rules: you may change the RULES document only by calling the update_rules tool, and ONLY when the user clearly and directly asks you to change the rules. Never change the rules on your own initiative. The NOTES are maintained automatically; do not mention them unless relevant.';

void main() {
  group('buildSystemPromptText exact strings', () {
    test('minimal prompt omits empty blocks without onboarding', () {
      final String prompt = buildSystemPromptText(
        newWordPercent: 10,
        rules: 'RULES BODY',
        notes: '# Learner notes\n## Language profile\n**Overall:** ok',
        targetWords: [],
        knownWords: [],
        today: DateTime.utc(2026, 3, 4),
      );

      const String expected =
          '$_baseWith10\n'
          '\n'
          '=== RULES ===\n'
          'RULES BODY\n'
          '\n'
          '=== NOTES ===\n'
          '# Learner notes\n'
          '## Language profile\n'
          '**Overall:** ok\n'
          '\n'
          '=== SESSION ===\n'
          'Today: 2026-03-04';
      expect(prompt, expected);
    });

    test('full prompt includes target, known and onboarding in order', () {
      final String prompt = buildSystemPromptText(
        newWordPercent: 15,
        rules: 'R1',
        notes: '# Learner notes\nStatus: not assessed yet',
        targetWords: ['cow', 'barn'],
        knownWords: ['milk'],
        today: DateTime.utc(2026, 1, 9),
      );

      expect(prompt.contains('{percent}'), isFalse);
      expect(prompt.contains('about 15%'), isTrue);

      final int baseIndex = prompt.indexOf(
        'You are the user\'s English conversation partner',
      );
      final int rulesIndex = prompt.indexOf('=== RULES ===');
      final int notesIndex = prompt.indexOf('=== NOTES ===');
      final int targetsIndex = prompt.indexOf(
        '=== TARGET WORDS (user is learning these) ===',
      );
      final int knownIndex = prompt.indexOf('=== RECENTLY KNOWN WORDS ===');
      final int sessionIndex = prompt.indexOf('=== SESSION ===');
      expect(baseIndex, 0);
      expect(rulesIndex > baseIndex, isTrue);
      expect(notesIndex > rulesIndex, isTrue);
      expect(targetsIndex > notesIndex, isTrue);
      expect(knownIndex > targetsIndex, isTrue);
      expect(sessionIndex > knownIndex, isTrue);

      expect(
        prompt.contains(
          '=== TARGET WORDS (user is learning these) ===\ncow, barn',
        ),
        isTrue,
      );
      expect(prompt.contains('=== RECENTLY KNOWN WORDS ===\nmilk'), isTrue);
      expect(prompt.contains('Today: 2026-01-09'), isTrue);
      expect(
        prompt.contains(
          'ONBOARDING: the user\'s language profile has not been written yet. Follow the Onboarding section of RULES now.',
        ),
        isTrue,
      );

      const String expectedSuffix =
          '=== TARGET WORDS (user is learning these) ===\n'
          'cow, barn\n'
          '\n'
          '=== RECENTLY KNOWN WORDS ===\n'
          'milk\n'
          '\n'
          '=== SESSION ===\n'
          'Today: 2026-01-09\n'
          'ONBOARDING: the user\'s language profile has not been written yet. Follow the Onboarding section of RULES now.';
      expect(prompt.endsWith(expectedSuffix), isTrue);
    });

    test('onboarding off when status line absent', () {
      final String prompt = buildSystemPromptText(
        newWordPercent: 10,
        rules: 'R',
        notes: '# Learner notes\n## Language profile\n**Overall:** B1',
        targetWords: [],
        knownWords: [],
        today: DateTime.utc(2026, 5, 1),
      );
      expect(prompt.contains('ONBOARDING:'), isFalse);
      expect(prompt.endsWith('=== SESSION ===\nToday: 2026-05-01'), isTrue);
    });

    test('percent substitution fills the base block', () {
      for (final int percent in [0, 5, 10, 30]) {
        final String prompt = buildSystemPromptText(
          newWordPercent: percent,
          rules: 'R',
          notes: 'N',
          targetWords: [],
          knownWords: [],
          today: DateTime.utc(2026, 5, 1),
        );
        expect(prompt.contains('about $percent%'), isTrue);
        expect(prompt.contains('{percent}'), isFalse);
      }
    });

    test('target list capped at 40 and known at 50', () {
      final List<String> manyTargets = [for (int i = 0; i < 45; i++) 't$i'];
      final List<String> manyKnown = [for (int i = 0; i < 55; i++) 'k$i'];
      final String prompt = buildSystemPromptText(
        newWordPercent: 10,
        rules: 'R',
        notes: 'N',
        targetWords: manyTargets,
        knownWords: manyKnown,
        today: DateTime.utc(2026, 5, 1),
      );

      final String targetsLine = prompt
          .split('\n')
          .firstWhere((l) => l.startsWith('t0,'));
      expect(targetsLine.split(', '), hasLength(40));
      expect(targetsLine.contains('t39'), isTrue);
      expect(targetsLine.contains('t40'), isFalse);

      final String knownLine = prompt
          .split('\n')
          .firstWhere((l) => l.startsWith('k0,'));
      expect(knownLine.split(', '), hasLength(50));
      expect(knownLine.contains('k49'), isTrue);
      expect(knownLine.contains('k50'), isFalse);
    });

    test('date is zero-padded YYYY-MM-DD', () {
      final String prompt = buildSystemPromptText(
        newWordPercent: 10,
        rules: 'R',
        notes: 'N',
        targetWords: [],
        knownWords: [],
        today: DateTime(2026, 1, 2, 15, 30),
      );
      expect(prompt.contains('Today: 2026-01-02'), isTrue);
    });
  });

  group('PromptBuilder wiring', () {
    late AppDatabase db;
    late FakeClock clock;
    late UnitRepository units;
    late MemoryDocumentStore documents;
    late MemorySettingsRepository settings;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      clock = FakeClock(DateTime.utc(2026, 3, 4, 12));
      units = UnitRepository(db, clock: clock);
      documents = MemoryDocumentStore(clock: clock);
      settings = MemorySettingsRepository(MemorySecureKeyStore());
    });

    tearDown(() async {
      await db.close();
    });

    PromptBuilder builder() {
      return PromptBuilder(
        settings: settings,
        documents: documents,
        units: units,
        clock: clock,
      );
    }

    test('empty store omits target and known blocks', () async {
      await documents.write(DocumentKind.rules, 'RULES!');
      await documents.write(DocumentKind.notes, 'NOTES!');
      await settings.setNewWordPercent(10);

      final String prompt = await builder().buildSystemPrompt();

      expect(prompt.contains('=== RULES ===\nRULES!'), isTrue);
      expect(prompt.contains('=== NOTES ===\nNOTES!'), isTrue);
      expect(
        prompt.contains('=== TARGET WORDS (user is learning these) ==='),
        isFalse,
      );
      expect(prompt.contains('=== RECENTLY KNOWN WORDS ==='), isFalse);
      expect(prompt.contains('Today: 2026-03-04'), isTrue);
      expect(prompt.contains('ONBOARDING:'), isFalse);
    });

    test('new unit appears as target, known unit as recently known', () async {
      await documents.write(DocumentKind.rules, 'R');
      await documents.write(
        DocumentKind.notes,
        '# Learner notes\nStatus: not assessed yet',
      );
      final added = await units.add(text: 'cow');
      await units.add(text: 'barn');
      await units.setKnown(added.id, true);

      final String prompt = await builder().buildSystemPrompt();

      // barn is still a target, cow moved to known.
      expect(
        prompt.contains('=== TARGET WORDS (user is learning these) ==='),
        isTrue,
      );
      expect(prompt.contains('barn'), isTrue);
      expect(prompt.contains('=== RECENTLY KNOWN WORDS ==='), isTrue);
      expect(prompt.contains('cow'), isTrue);
      expect(prompt.contains('ONBOARDING:'), isTrue);
    });

    test('buildSystemMessage returns a system LlmMessage', () async {
      await documents.write(DocumentKind.rules, 'R');
      await documents.write(DocumentKind.notes, 'N');
      final LlmMessage message = await builder().buildSystemMessage();
      expect(message.role, LlmRole.system);
      expect(message.content.contains('=== SESSION ==='), isTrue);
    });

    test('uses clock date and settings percent', () async {
      await documents.write(DocumentKind.rules, 'R');
      await documents.write(DocumentKind.notes, 'N');
      await settings.setNewWordPercent(25);
      clock.setNow(DateTime.utc(2027, 12, 31));

      final String prompt = await builder().buildSystemPrompt();

      expect(prompt.contains('about 25%'), isTrue);
      expect(prompt.contains('Today: 2027-12-31'), isTrue);
    });
  });
}
