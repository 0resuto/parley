import 'package:flutter/foundation.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';

/// Target length for the notes document: 80 % of [notesLimit] (SPEC 6.6).
int get notesTargetLength => (notesLimit * notesTargetRatio).round();

/// Shortening retry budget: 60 % of [notesLimit] (SPEC 6.6).
int get notesRetryLength => (notesLimit * notesRetryRatio).round();

/// Formats [today] as `YYYY-MM-DD` in UTC (SPEC 6.2, 6.6).
String formatNotesDate(DateTime today) {
  final DateTime utc = today.toUtc();
  final String month = utc.month.toString().padLeft(2, '0');
  final String day = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$day';
}

/// Builds the notes-updater system prompt exactly per SPEC 6.6.
///
/// `{date}` is today (`YYYY-MM-DD` from [today]) and `{target}` is
/// 80 % of the notes limit.
String buildNotesSystemPrompt({required DateTime today}) {
  final String date = formatNotesDate(today);
  final int target = notesTargetLength;
  return 'You maintain NOTES, a private notebook an English tutor uses to remember its learner between conversations. '
      'Update it using the new conversation excerpt. Return ONLY the full updated document in Markdown (no code fences, no commentary).\n'
      'Keep the title line "# Learner notes" and exactly these sections in this order: "## Language profile", "## About the user", "## Learning observations", "## Ongoing threads".\n'
      'Language profile: a comprehensive, evidence-based assessment of the learner\'s English, NOT just a level label. Use exactly these lines:\n'
      '**Overall:** (2-4 sentences; may mention an approximate CEFR range)\n'
      '**Vocabulary:** ...\n'
      '**Grammar:** ...\n'
      '**Fluency and expression:** ...\n'
      '**Comprehension:** ...\n'
      '**Strengths:** ...\n'
      '**Weak spots:** ...\n'
      '**Confidence:** low | medium | high\n'
      'Last reassessed: $date\n'
      'The conversation is typed text, so pronunciation and listening cannot be judged; do not claim to judge them.\n'
      'If the profile contains "Status: not assessed yet": write the first full profile only if the excerpt contains at least 6 substantive learner messages; otherwise keep the profile unchanged. When you write it, remove the status line.\n'
      'Otherwise reassess the profile every time: change a statement only when the new evidence supports it, and update the "Last reassessed" date.\n'
      'Other sections: record only durable, useful facts (interests, goals, recurring mistakes, what teaching approaches work, topics worth revisiting). No transcripts, no one-off trivia.\n'
      'Merge duplicates, drop outdated or resolved items, shorten old entries.\n'
      'The whole document MUST stay under $target characters.';
}

/// Formats one excerpt as `user: ...` / `assistant: ...` lines (SPEC 6.6).
String buildNotesExcerpt(List<ChatMessage> excerpt) {
  return [
    for (final ChatMessage message in excerpt)
      '${message.role.value}: ${message.content}',
  ].join('\n');
}

/// Builds the non-streaming notes-updater request (SPEC 6.6).
///
/// [currentNotes] is the current `notes.md` text, [excerpt] are the
/// unprocessed user/assistant messages in order.
List<LlmMessage> buildNotesMessages({
  required String currentNotes,
  required List<ChatMessage> excerpt,
  required DateTime today,
}) {
  return [
    LlmMessage(
      role: LlmRole.system,
      content: buildNotesSystemPrompt(today: today),
    ),
    LlmMessage(
      role: LlmRole.user,
      content:
          'CURRENT NOTES:\n$currentNotes\n\nNEW EXCERPT:\n${buildNotesExcerpt(excerpt)}',
    ),
  ];
}

/// Shortening retry line appended when the first result is too long.
///
/// SPEC 6.6: `Too long. Shorten to under {60 % of the limit} characters.`
String notesShortenRetryLine() {
  return 'Too long. Shorten to under $notesRetryLength characters.';
}

/// Validates a candidate notes document (SPEC 6.6).
///
/// Valid means: non-empty, contains all four `##` headings,
/// length at most [limit], and no ``` code fences.
bool isValidNotesDocument(String text, {int limit = notesLimit}) {
  if (text.trim().isEmpty) {
    return false;
  }
  if (text.length > limit) {
    return false;
  }
  if (text.contains('```')) {
    return false;
  }
  const List<String> headings = [
    '## Language profile',
    '## About the user',
    '## Learning observations',
    '## Ongoing threads',
  ];
  for (final String heading in headings) {
    if (!text.contains(heading)) {
      return false;
    }
  }
  return true;
}

/// Background notes updater (PLAN 7.3, SPEC 5.6, 6.6).
///
/// Collects unprocessed user/assistant messages (oldest first, at most
/// [notesMaxMessagesPerCall] per call), asks the LLM once for the full
/// updated `notes.md`, validates it, writes it via [DocumentStore] and
/// marks the excerpt processed only after a successful write. A result
/// longer than the limit gets one shortening retry; any other invalid
/// result is discarded. All failures are caught and logged with
/// `debugPrint`, never shown in the UI and never thrown.
class NotesUpdater {
  NotesUpdater({
    required ChatRepository chats,
    required DocumentStore documents,
    required LlmClient llm,
    required Clock clock,
    required ConnectivityService connectivity,
    required SettingsRepository settings,
  }) : _chats = chats,
       _documents = documents,
       _llm = llm,
       _clock = clock,
       _connectivity = connectivity,
       _settings = settings;

  final ChatRepository _chats;
  final DocumentStore _documents;
  final LlmClient _llm;
  final Clock _clock;
  final ConnectivityService _connectivity;
  final SettingsRepository _settings;

  /// Runs one updater chunk. Returns true when notes were written.
  ///
  /// Never throws.
  Future<bool> updateOnce() async {
    try {
      bool configured = false;
      try {
        configured = await _settings.isLlmConfigured();
      } catch (_) {
        configured = false;
      }
      if (!configured) {
        return false;
      }
      bool online = false;
      try {
        online = await _connectivity.isOnline();
      } catch (_) {
        online = false;
      }
      if (!online) {
        return false;
      }
      final List<ChatMessage> chunk = await _collectUnprocessed();
      if (chunk.isEmpty) {
        return false;
      }
      final String current = await _documents.read(DocumentKind.notes);
      final DateTime now = _clock.now().toUtc();
      final List<LlmMessage> request = buildNotesMessages(
        currentNotes: current,
        excerpt: chunk,
        today: now,
      );
      String first;
      try {
        first = await _llm.complete(request);
      } catch (e) {
        debugPrint('notes updater failed: $e');
        return false;
      }
      if (isValidNotesDocument(first)) {
        return _commit(chunk, first);
      }
      if (first.length <= notesLimit) {
        return false;
      }
      final List<LlmMessage> retryRequest = [
        ...request,
        LlmMessage(role: LlmRole.user, content: notesShortenRetryLine()),
      ];
      String second;
      try {
        second = await _llm.complete(retryRequest);
      } catch (e) {
        debugPrint('notes updater retry failed: $e');
        return false;
      }
      if (!isValidNotesDocument(second)) {
        return false;
      }
      return _commit(chunk, second);
    } catch (e) {
      debugPrint('notes updater failed: $e');
      return false;
    }
  }

  /// Writes [text] and marks [chunk] processed. Never throws.
  Future<bool> _commit(List<ChatMessage> chunk, String text) async {
    try {
      await _documents.write(DocumentKind.notes, text);
      await _chats.markProcessed([for (final ChatMessage m in chunk) m.id]);
      return true;
    } catch (e) {
      debugPrint('notes updater write failed: $e');
      return false;
    }
  }

  /// Oldest-first unprocessed user/assistant messages, at most
  /// [notesMaxMessagesPerCall]. Event messages are never included.
  Future<List<ChatMessage>> _collectUnprocessed() async {
    final List<Conversation> conversations = await _chats.listConversations();
    final List<ChatMessage> all = [];
    for (final Conversation conversation in conversations) {
      final List<ChatMessage> messages = await _chats.listMessages(
        conversation.id,
      );
      for (final ChatMessage message in messages) {
        if (message.processedByNotes) {
          continue;
        }
        if (message.role != ChatRole.user &&
            message.role != ChatRole.assistant) {
          continue;
        }
        all.add(message);
      }
    }
    all.sort((a, b) {
      final int byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) {
        return byTime;
      }
      return a.id.compareTo(b.id);
    });
    if (all.length <= notesMaxMessagesPerCall) {
      return all;
    }
    return all.sublist(0, notesMaxMessagesPerCall);
  }
}
