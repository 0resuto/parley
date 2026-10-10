import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';

/// Line in `notes.md` that enables the onboarding sentence (SPEC 6.2).
const String onboardingStatusLine = 'Status: not assessed yet';

/// Onboarding sentence appended to the SESSION block (SPEC 6.2, verbatim).
const String onboardingPromptLine =
    'ONBOARDING: the user\'s language profile has not been written yet. '
    'Follow the Onboarding section of RULES now.';

/// Base block template (SPEC 6.2, verbatim except `{percent}`).
const String promptBaseTemplate =
    'You are the user\'s English conversation partner inside a language-learning app.\n'
    'Write ONLY in English.\n'
    'Be like a friendly, experienced English teacher who is also a good friend: natural, warm, curious, a bit playful. Never sound like a textbook or a quiz.\n'
    'Keep replies short (usually 1-4 sentences) and move the conversation forward.\n'
    'Correct mistakes the way a skilled teacher or a close friend would: only when it helps, lightly and in the flow of the conversation. Never lecture or list errors unless the user asks.\n'
    'Use plain text. No markdown headings, bullet lists or emojis unless the user asks for them.\n'
    'Vocabulary: assume the general vocabulary of the user\'s current level (see the language profile in NOTES) is known. TARGET WORDS are words the user is learning: steer the conversation so they come up naturally. Never list them, define them unprompted, or quiz the user on them. Aim for about {percent}% of the content words in your replies to be unfamiliar or target words; the rest should be words the user already knows.\n'
    'When you deliberately use a word that is probably new to the user and is NOT in TARGET WORDS, wrap it in double square brackets, like [[heifer]] (at most 2 per reply). Do not bracket target words or recently known words.\n'
    'If the user asks what a word means, explain it simply in English using words they know, with a short example.\n'
    'Rules: you may change the RULES document only by calling the update_rules tool, and ONLY when the user clearly and directly asks you to change the rules. Never change the rules on your own initiative. The NOTES are maintained automatically; do not mention them unless relevant.';

/// Formats [today] as `YYYY-MM-DD` (SPEC 6.2).
String formatPromptDate(DateTime today) {
  final DateTime utc = today.toUtc();
  final String month = utc.month.toString().padLeft(2, '0');
  final String day = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$day';
}

/// Builds the chat system prompt exactly per SPEC 6.2.
///
/// Blocks are joined by a blank line in SPEC order. The target and known
/// blocks are omitted when their word lists are empty. Lists are truncated
/// to [targetWordsMax] / [recentlyKnownMax] defensively; callers normally
/// pass already-limited lists from [UnitRepository].
String buildSystemPromptText({
  required int newWordPercent,
  required String rules,
  required String notes,
  required List<String> targetWords,
  required List<String> knownWords,
  required DateTime today,
}) {
  final List<String> targets = targetWords
      .where((w) => w.trim().isNotEmpty)
      .take(targetWordsMax)
      .toList();
  final List<String> known = knownWords
      .where((w) => w.trim().isNotEmpty)
      .take(recentlyKnownMax)
      .toList();

  final String base = promptBaseTemplate.replaceAll(
    '{percent}',
    '$newWordPercent',
  );
  final List<String> parts = <String>[
    base,
    '=== RULES ===\n$rules',
    '=== NOTES ===\n$notes',
  ];
  if (targets.isNotEmpty) {
    parts.add(
      '=== TARGET WORDS (user is learning these) ===\n${targets.join(', ')}',
    );
  }
  if (known.isNotEmpty) {
    parts.add('=== RECENTLY KNOWN WORDS ===\n${known.join(', ')}');
  }
  String session = '=== SESSION ===\nToday: ${formatPromptDate(today)}';
  if (notes.contains(onboardingStatusLine)) {
    session += '\n$onboardingPromptLine';
  }
  parts.add(session);
  return parts.join('\n\n');
}

/// Assembles the chat system prompt from live app state (SPEC 6.2).
///
/// Time comes from [Clock]; target words use [UnitRepository.targetWords]
/// (due now first, then newest) and known words use
/// [UnitRepository.recentlyKnown] (latest `last_review` first).
class PromptBuilder {
  PromptBuilder({
    required SettingsRepository settings,
    required DocumentStore documents,
    required UnitRepository units,
    required Clock clock,
  }) : _settings = settings,
       _documents = documents,
       _units = units,
       _clock = clock;

  final SettingsRepository _settings;
  final DocumentStore _documents;
  final UnitRepository _units;
  final Clock _clock;

  /// Returns the full system prompt text.
  Future<String> buildSystemPrompt() async {
    final int percent = _settings.newWordPercent;
    final DateTime now = _clock.now().toUtc();
    final String rules = await _documents.read(DocumentKind.rules);
    final String notes = await _documents.read(DocumentKind.notes);
    final List<String> targets = [
      for (final unit in await _units.targetWords(targetWordsMax, now))
        unit.text,
    ];
    final List<String> known = [
      for (final unit in await _units.recentlyKnown(recentlyKnownMax))
        unit.text,
    ];
    return buildSystemPromptText(
      newWordPercent: percent,
      rules: rules,
      notes: notes,
      targetWords: targets,
      knownWords: known,
      today: now,
    );
  }

  /// Returns the system prompt as an LLM system message.
  Future<LlmMessage> buildSystemMessage() async {
    return LlmMessage(role: LlmRole.system, content: await buildSystemPrompt());
  }
}
