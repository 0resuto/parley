import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Conversation;
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/services/llm/llm_client.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late ChatRepository repo;
  final DateTime initial = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    repo = ChatRepository(db, clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  group('conversations', () {
    test('create starts empty with default title', () async {
      final Conversation conversation = await repo.createConversation();

      expect(conversation.title, 'New chat');
      expect(conversation.createdAt, initial);
      expect(conversation.updatedAt, initial);
      expect(await repo.listMessages(conversation.id), isEmpty);
      expect(await repo.getConversation(999), isNull);
    });

    test('list is most recently updated first', () async {
      final Conversation first = await repo.createConversation();
      clock.advance(const Duration(minutes: 1));
      final Conversation second = await repo.createConversation();

      List<Conversation> all = await repo.listConversations();
      expect(all.map((c) => c.id), [second.id, first.id]);

      // Touching the older conversation bumps it to the front.
      clock.advance(const Duration(minutes: 1));
      await repo.addMessage(
        conversationId: first.id,
        role: ChatRole.user,
        content: 'hello',
      );
      all = await repo.listConversations();
      expect(all.map((c) => c.id), [first.id, second.id]);
    });

    test('delete removes the conversation and its messages', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'hi',
      );
      expect(await repo.listMessages(conversation.id), hasLength(1));

      await repo.deleteConversation(conversation.id);

      expect(await repo.listConversations(), isEmpty);
      expect(await repo.listMessages(conversation.id), isEmpty);
    });
  });

  group('addMessage and title', () {
    test('messages are oldest first and bump updated_at', () async {
      final Conversation conversation = await repo.createConversation();
      clock.advance(const Duration(seconds: 1));
      final DateTime atSend = clock.now();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'first',
      );
      clock.advance(const Duration(seconds: 1));
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: 'second',
      );

      final List<ChatMessage> messages = await repo.listMessages(
        conversation.id,
      );
      expect(messages.map((m) => m.content), ['first', 'second']);
      expect(messages.first.role, ChatRole.user);
      expect(messages.first.processedByNotes, isFalse);

      final Conversation? updated = await repo.getConversation(conversation.id);
      expect(updated!.updatedAt, clock.now().toUtc());
      expect(updated.updatedAt.isAfter(atSend.toUtc()), isTrue);
    });

    test('title comes from the first user message truncated to 40', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: 'assistant does not set the title at all here',
      );
      expect((await repo.getConversation(conversation.id))!.title, 'New chat');

      const String long =
          '0123456789012345678901234567890123456789 plus more text here';
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: '  $long  ',
      );
      final Conversation? renamed = await repo.getConversation(conversation.id);
      expect(renamed!.title, long.substring(0, 40));
      expect(renamed.title, hasLength(40));

      // Later user messages do not overwrite the title.
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'a different second message',
      );
      expect(
        (await repo.getConversation(conversation.id))!.title,
        renamed.title,
      );
    });

    test('event messages never set the title', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.event,
        content: '{"type":"rules_updated"}',
      );
      expect((await repo.getConversation(conversation.id))!.title, 'New chat');
    });
  });

  group('historyForLlm', () {
    test('excludes event messages and keeps order', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'hi',
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.event,
        content: '{"type":"rules_updated"}',
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: 'hello',
      );

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      expect(history.map((m) => m.content), ['hi', 'hello']);
      expect(history.first.role, LlmRole.user);
      expect(history.last.role, LlmRole.assistant);
    });

    test('keeps only the last 30 messages', () async {
      final Conversation conversation = await repo.createConversation();
      for (int i = 0; i < 35; i++) {
        await repo.addMessage(
          conversationId: conversation.id,
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          content: 'm$i',
        );
      }

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      expect(history, hasLength(30));
      expect(history.first.content, 'm5');
      expect(history.last.content, 'm34');
    });

    test('drops oldest messages over the 12000 char limit', () async {
      final Conversation conversation = await repo.createConversation();
      String chunk(String prefix) => '$prefix${'x' * 4999}';
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: chunk('a'),
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: chunk('b'),
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: chunk('c'),
      );

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      // 3 x 5000 = 15000, so the oldest must be dropped.
      expect(history, hasLength(2));
      expect(history.first.content.startsWith('b'), isTrue);
      expect(history.last.content.startsWith('c'), isTrue);
      final int total = history.fold<int>(
        0,
        (sum, m) => sum + m.content.length,
      );
      expect(total <= 12000, isTrue);
    });
  });

  group('unprocessed counts', () {
    test('counts only unprocessed user messages', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'one',
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: 'reply',
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.event,
        content: '{}',
      );

      expect(await repo.unprocessedUserCount(), 1);
      expect(
        await repo.unprocessedUserCount(conversationId: conversation.id),
        1,
      );

      final List<ChatMessage> messages = await repo.listMessages(
        conversation.id,
      );
      await repo.markProcessed([messages.first.id]);

      expect(await repo.unprocessedUserCount(), 0);
      expect(
        await repo.unprocessedUserCount(conversationId: conversation.id),
        0,
      );
    });

    test('counts per conversation and globally', () async {
      final Conversation a = await repo.createConversation();
      final Conversation b = await repo.createConversation();
      await repo.addMessage(
        conversationId: a.id,
        role: ChatRole.user,
        content: 'a1',
      );
      await repo.addMessage(
        conversationId: a.id,
        role: ChatRole.user,
        content: 'a2',
      );
      await repo.addMessage(
        conversationId: b.id,
        role: ChatRole.user,
        content: 'b1',
      );

      expect(await repo.unprocessedUserCount(conversationId: a.id), 2);
      expect(await repo.unprocessedUserCount(conversationId: b.id), 1);
      expect(await repo.unprocessedUserCount(), 3);

      await repo.markProcessed([]);
      expect(await repo.unprocessedUserCount(), 3);
    });
  });
}
