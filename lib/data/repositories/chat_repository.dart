import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/data/db/database.dart' as db;
import 'package:parley/data/models/chat.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/llm/llm_client.dart';

/// Chat storage (PLAN 6.1, SPEC 4.1, 5.3).
///
/// Time comes from [Clock]. New conversations start titled `New chat`;
/// the first non-blank user message retitles the conversation to its
/// trimmed text truncated to [conversationTitleLength]. Every added
/// message bumps `updated_at`. `event` messages are stored but never
/// returned by [historyForLlm] and never counted by
/// [unprocessedUserCount].
class ChatRepository {
  ChatRepository(this._db, {required Clock clock}) : _clock = clock;

  final db.AppDatabase _db;
  final Clock _clock;

  /// Creates an empty conversation titled `New chat` (or [title]).
  Future<Conversation> createConversation({String? title}) async {
    final DateTime now = _clock.now().toUtc();
    final int id = await _db
        .into(_db.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            title: title ?? 'New chat',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final Conversation? created = await getConversation(id);
    return created!;
  }

  /// Reads one conversation by id, or null when missing.
  Future<Conversation?> getConversation(int id) async {
    final List<db.Conversation> rows = await (_db.select(
      _db.conversations,
    )..where((t) => t.id.equals(id))).get();
    if (rows.isEmpty) {
      return null;
    }
    return _toConversation(rows.first);
  }

  /// Conversations, most recently updated first.
  Future<List<Conversation>> listConversations() async {
    final List<db.Conversation> rows =
        await (_db.select(_db.conversations)..orderBy([
              (t) => OrderingTerm(
                expression: t.updatedAt,
                mode: OrderingMode.desc,
              ),
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ]))
            .get();
    return rows.map(_toConversation).toList();
  }

  /// Watches conversations, most recently updated first.
  Stream<List<Conversation>> watchConversations() {
    final query = _db.select(_db.conversations)
      ..orderBy([
        (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ]);
    return query.watch().map((rows) => rows.map(_toConversation).toList());
  }

  /// Deletes the conversation (messages cascade).
  Future<void> deleteConversation(int id) async {
    await (_db.delete(_db.conversations)..where((t) => t.id.equals(id))).go();
  }

  /// Appends a message, bumps `updated_at`, and retitles the conversation
  /// from the first non-blank user message (40 chars).
  Future<ChatMessage> addMessage({
    required int conversationId,
    required ChatRole role,
    required String content,
  }) async {
    final DateTime now = _clock.now().toUtc();
    final int id = await _db
        .into(_db.messages)
        .insert(
          db.MessagesCompanion.insert(
            conversationId: conversationId,
            role: role.value,
            content: content,
            createdAt: now,
          ),
        );

    final List<db.Message> userMessages =
        await (_db.select(_db.messages)
              ..where(
                (t) =>
                    t.conversationId.equals(conversationId) &
                    t.role.equals(ChatRole.user.value),
              )
              ..orderBy([
                (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
              ]))
            .get();
    String? nextTitle;
    if (role == ChatRole.user) {
      final String trimmed = content.trim();
      if (trimmed.isNotEmpty) {
        int nonBlank = 0;
        for (final db.Message row in userMessages) {
          if (row.content.trim().isNotEmpty) {
            nonBlank++;
          }
        }
        if (nonBlank == 1) {
          nextTitle = trimmed.length <= conversationTitleLength
              ? trimmed
              : trimmed.substring(0, conversationTitleLength);
        }
      }
    }
    final db.ConversationsCompanion update = nextTitle == null
        ? db.ConversationsCompanion(updatedAt: Value(now))
        : db.ConversationsCompanion(
            updatedAt: Value(now),
            title: Value(nextTitle),
          );
    await (_db.update(
      _db.conversations,
    )..where((t) => t.id.equals(conversationId))).write(update);

    final ChatMessage? created = await getMessage(id);
    return created!;
  }

  /// Reads one message by id, or null when missing.
  Future<ChatMessage?> getMessage(int id) async {
    final List<db.Message> rows = await (_db.select(
      _db.messages,
    )..where((t) => t.id.equals(id))).get();
    if (rows.isEmpty) {
      return null;
    }
    return _toMessage(rows.first);
  }

  /// Messages of one conversation, oldest first.
  Future<List<ChatMessage>> listMessages(int conversationId) async {
    final List<db.Message> rows =
        await (_db.select(_db.messages)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([
                (t) => OrderingTerm(
                  expression: t.createdAt,
                  mode: OrderingMode.asc,
                ),
                (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
              ]))
            .get();
    return rows.map(_toMessage).toList();
  }

  /// Watches messages of one conversation, oldest first.
  Stream<List<ChatMessage>> watchMessages(int conversationId) {
    final query = _db.select(_db.messages)
      ..where((t) => t.conversationId.equals(conversationId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
      ]);
    return query.watch().map((rows) => rows.map(_toMessage).toList());
  }

  /// LLM history per SPEC 5.3: last 30 user/assistant messages in order,
  /// dropping the oldest until the total is at most 12000 chars.
  ///
  /// `event` messages are never included.
  Future<List<LlmMessage>> historyForLlm(int conversationId) async {
    final List<ChatMessage> all = await listMessages(conversationId);
    final List<ChatMessage> usable = all
        .where((m) => m.role != ChatRole.event)
        .toList();
    final List<ChatMessage> window = usable.length <= chatHistoryMaxMessages
        ? usable
        : usable.sublist(usable.length - chatHistoryMaxMessages);
    int total = 0;
    for (final ChatMessage message in window) {
      total += message.content.length;
    }
    int drop = 0;
    while (drop < window.length && total > chatHistoryMaxChars) {
      total -= window[drop].content.length;
      drop++;
    }
    final List<ChatMessage> trimmed = drop == 0 ? window : window.sublist(drop);
    return [
      for (final ChatMessage message in trimmed)
        LlmMessage(
          role: message.role == ChatRole.user
              ? LlmRole.user
              : LlmRole.assistant,
          content: message.content,
        ),
    ];
  }

  /// Counts unprocessed user messages (SPEC 5.6).
  ///
  /// `event` and `assistant` messages are never counted. When
  /// [conversationId] is null the count is global, otherwise per
  /// conversation.
  Future<int> unprocessedUserCount({int? conversationId}) async {
    final query = _db.select(_db.messages)
      ..where(
        (t) =>
            t.role.equals(ChatRole.user.value) &
            t.processedByNotes.equals(false) &
            (conversationId == null
                ? const Constant<bool>(true)
                : t.conversationId.equals(conversationId)),
      );
    final List<db.Message> rows = await query.get();
    return rows.length;
  }

  /// Marks the given message ids as processed by the notes updater.
  Future<void> markProcessed(List<int> messageIds) async {
    if (messageIds.isEmpty) {
      return;
    }
    await (_db.update(_db.messages)..where((t) => t.id.isIn(messageIds))).write(
      const db.MessagesCompanion(processedByNotes: Value(true)),
    );
  }

  /// Replaces a message's content (used to mark a rules event reverted).
  Future<void> updateMessageContent(int id, String content) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(id))).write(
      db.MessagesCompanion(content: Value(content)),
    );
  }

  Conversation _toConversation(db.Conversation row) {
    return Conversation(
      id: row.id,
      title: row.title,
      createdAt: row.createdAt.toUtc(),
      updatedAt: row.updatedAt.toUtc(),
    );
  }

  ChatMessage _toMessage(db.Message row) {
    return ChatMessage(
      id: row.id,
      conversationId: row.conversationId,
      role: ChatRole.fromValue(row.role),
      content: row.content,
      createdAt: row.createdAt.toUtc(),
      processedByNotes: row.processedByNotes,
    );
  }
}

/// Builds the chat repository from the app database and clock.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(
    ref.watch(db.appDatabaseProvider),
    clock: ref.watch(clockProvider),
  );
});
