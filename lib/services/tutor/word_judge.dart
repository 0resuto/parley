import 'package:flutter/foundation.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/core/json_extract.dart';
import 'package:parley/data/db/database.dart' as db;
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/features/chat/tokenizer.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

/// System prompt for the word judge (SPEC 6.5, verbatim).
const String wordJudgeSystemPrompt =
    'You judge how an English learner handled specific vocabulary in a conversation. '
    'Output ONLY JSON: {"ratings":[{"text":"<word exactly as in WORDS>","rating":"again|hard|good|easy","reason":"<short>"}]}.\n'
    'Only include words from WORDS that are clearly evidenced in the messages. '
    'Skip a word if there is no clear evidence. '
    'Judge the behaviour of the "user" messages; "assistant" messages are context.\n'
    'again = the user asked what it means, was confused by it, or used it wrongly.\n'
    'hard = the user understood or used it only with obvious difficulty or after help.\n'
    'good = the user clearly understood it (replied appropriately) or used it correctly.\n'
    'easy = the user used it correctly and effortlessly on their own initiative.';

/// Builds the non-streaming word-judge request (SPEC 6.5).
///
/// [words] are candidate unit texts, [window] are the last
/// [wordJudgeMessageWindow] user/assistant messages in order.
List<LlmMessage> buildWordJudgeMessages({
  required List<String> words,
  required List<ChatMessage> window,
}) {
  final String wordsLine = 'WORDS: ${words.join(', ')}';
  final String messagesBlock = window
      .map((ChatMessage m) => '${m.role.value}: ${m.content}')
      .join('\n');
  return [
    const LlmMessage(role: LlmRole.system, content: wordJudgeSystemPrompt),
    LlmMessage(
      role: LlmRole.user,
      content: '$wordsLine\nMESSAGES:\n$messagesBlock',
    ),
  ];
}

/// Finds candidate units in [window] using the chat tokenizer.
///
/// Parses each message with [index] (built from non-Known units) and
/// collects matched units in order of first appearance, deduplicated
/// by id. Known units never match because they are not in the index.
List<Unit> findJudgeCandidates(List<ChatMessage> window, UnitIndex index) {
  final Map<int, Unit> found = <int, Unit>{};
  final List<Unit> ordered = <Unit>[];
  for (final ChatMessage message in window) {
    final List<ChatSpan> spans = parseMessage(message.content, index);
    for (final ChatSpan span in spans) {
      final Unit? unit = span.unit;
      if (unit == null || unit.knownManual) {
        continue;
      }
      if (found.containsKey(unit.id)) {
        continue;
      }
      found[unit.id] = unit;
      ordered.add(unit);
    }
  }
  return ordered;
}

Rating _judgeRatingToRating(JudgeRating rating) {
  switch (rating) {
    case JudgeRating.again:
      return Rating.again;
    case JudgeRating.hard:
      return Rating.hard;
    case JudgeRating.good:
      return Rating.good;
    case JudgeRating.easy:
      return Rating.easy;
  }
}

/// Background word judge (PLAN 7.1, SPEC 5.6, 6.5).
///
/// After each completed assistant reply: finds non-Known dictionary
/// units in the last [wordJudgeMessageWindow] messages, asks the LLM
/// once for ratings, and applies each valid rating through
/// [ReviewService] with source `chat`. Units with any review in the
/// last [wordJudgeMinReviewGap] are skipped. All failures are caught
/// and logged with `debugPrint`, never shown in the UI.
class WordJudge {
  WordJudge({
    required db.AppDatabase db,
    required ChatRepository chats,
    required UnitRepository units,
    required LlmClient llm,
    required ConnectivityService connectivity,
    required SettingsRepository settings,
    required ReviewService reviews,
    required Clock clock,
  }) : _db = db,
       _chats = chats,
       _units = units,
       _llm = llm,
       _connectivity = connectivity,
       _settings = settings,
       _reviews = reviews,
       _clock = clock;

  final db.AppDatabase _db;
  final ChatRepository _chats;
  final UnitRepository _units;
  final LlmClient _llm;
  final ConnectivityService _connectivity;
  final SettingsRepository _settings;
  final ReviewService _reviews;
  final Clock _clock;

  /// Runs the judge for [conversationId]. Never throws.
  Future<void> judgeConversation(int conversationId) async {
    try {
      bool configured = false;
      try {
        configured = await _settings.isLlmConfigured();
      } catch (_) {
        configured = false;
      }
      if (!configured) {
        return;
      }
      bool online = false;
      try {
        online = await _connectivity.isOnline();
      } catch (_) {
        online = false;
      }
      if (!online) {
        return;
      }
      final List<ChatMessage> all = await _chats.listMessages(conversationId);
      final List<ChatMessage> usable = all
          .where((ChatMessage m) => m.role != ChatRole.event)
          .toList();
      if (usable.isEmpty) {
        return;
      }
      final List<ChatMessage> window = usable.length <= wordJudgeMessageWindow
          ? usable
          : usable.sublist(usable.length - wordJudgeMessageWindow);
      final List<Unit> allUnits = await _units.watchAll().first;
      final List<Unit> dictUnits = allUnits
          .where((Unit u) => !u.knownManual)
          .toList();
      if (dictUnits.isEmpty) {
        return;
      }
      final UnitIndex index = UnitIndex.fromUnits(dictUnits);
      final List<Unit> candidates = findJudgeCandidates(window, index);
      if (candidates.isEmpty) {
        return;
      }
      final List<LlmMessage> request = buildWordJudgeMessages(
        words: [for (final Unit u in candidates) u.text],
        window: window,
      );
      final WordJudgeResult result = await completeJson(
        _llm,
        request,
        validateWordJudgeJson,
      );
      if (result.ratings.isEmpty) {
        return;
      }
      final DateTime now = _clock.now().toUtc();
      final DateTime cutoff = now.subtract(wordJudgeMinReviewGap);
      for (final WordJudgeRating entry in result.ratings) {
        try {
          final Unit? unit = _matchCandidate(candidates, entry.text);
          if (unit == null || unit.knownManual) {
            continue;
          }
          if (await _hasRecentReview(unit.id, cutoff)) {
            continue;
          }
          await _reviews.rate(
            unit.id,
            _judgeRatingToRating(entry.rating),
            ReviewSource.chat,
          );
        } catch (e) {
          debugPrint('word judge rating failed: $e');
        }
      }
    } catch (e) {
      debugPrint('word judge failed: $e');
    }
  }

  /// Matches a judge [text] back to a candidate unit.
  ///
  /// The model must return text exactly as in WORDS, so an exact match
  /// wins first; normalized key and forms are fallbacks. Unknown words
  /// (hallucinated by the model) return null.
  Unit? _matchCandidate(List<Unit> candidates, String text) {
    for (final Unit unit in candidates) {
      if (unit.text == text) {
        return unit;
      }
    }
    final String key = normalizeKey(text);
    if (key.isEmpty) {
      return null;
    }
    for (final Unit unit in candidates) {
      if (unit.textKey == key) {
        return unit;
      }
      if (normalizeKey(unit.text) == key) {
        return unit;
      }
      if (unit.forms.contains(key)) {
        return unit;
      }
    }
    return null;
  }

  /// True when the unit has any review at or after [cutoff].
  Future<bool> _hasRecentReview(int unitId, DateTime cutoff) async {
    final List<db.Review> rows = await (_db.select(
      _db.reviews,
    )..where((t) => t.unitId.equals(unitId))).get();
    for (final db.Review row in rows) {
      if (!row.reviewedAt.toUtc().isBefore(cutoff)) {
        return true;
      }
    }
    return false;
  }
}
