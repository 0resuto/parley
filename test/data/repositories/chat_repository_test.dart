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

    test('title truncation does not split a surrogate pair', () async {
      final Conversation conversation = await repo.createConversation();
      // 39 'a's, then an emoji (2 UTF-16 units): a plain substring cut at 40
      // code units would keep only the emoji's high surrogate.
      final String message = '${'a' * 39}🚀 plus further text';
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: message,
      );

      final String title = (await repo.getConversation(conversation.id))!.title;
      expect(title, '${'a' * 39}🚀');
      expect(title.runes.length, 40);
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

  group('updateMessageContent', () {
    test('replaces content and bumps the conversation updated_at', () async {
      final Conversation conversation = await repo.createConversation();
      final ChatMessage message = await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'original',
      );
      final DateTime before = (await repo.getConversation(
        conversation.id,
      ))!.updatedAt;

      clock.advance(const Duration(minutes: 5));
      await repo.updateMessageContent(message.id, 'reverted');

      expect((await repo.getMessage(message.id))!.content, 'reverted');
      final Conversation? updated = await repo.getConversation(conversation.id);
      expect(updated!.updatedAt, clock.now().toUtc());
      expect(updated.updatedAt.isAfter(before), isTrue);
    });

    test('rises to the top of watchConversations after an undo', () async {
      final Conversation first = await repo.createConversation();
      final ChatMessage message = await repo.addMessage(
        conversationId: first.id,
        role: ChatRole.user,
        content: 'hello',
      );
      clock.advance(const Duration(minutes: 1));
      final Conversation second = await repo.createConversation();
      expect((await repo.watchConversations().first).map((c) => c.id), [
        second.id,
        first.id,
      ]);

      clock.advance(const Duration(minutes: 1));
      await repo.updateMessageContent(message.id, 'reverted');

      expect((await repo.watchConversations().first).map((c) => c.id), [
        first.id,
        second.id,
      ]);
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

    test(
      'keeps and truncates the newest message when it alone is too long',
      () async {
        final Conversation conversation = await repo.createConversation();
        await repo.addMessage(
          conversationId: conversation.id,
          role: ChatRole.user,
          content: 'x' * 13001,
        );

        final List<LlmMessage> history = await repo.historyForLlm(
          conversation.id,
        );
        expect(history, hasLength(1));
        expect(history.single.role, LlmRole.user);
        expect(history.single.content, 'x' * 12000);
      },
    );

    test('drops older messages before truncating the newest', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'old',
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: 'reply',
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'y' * 13001,
      );

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      expect(history, hasLength(1));
      expect(history.single.content, 'y' * 12000);
    });

    test('truncation does not split a surrogate pair', () async {
      final Conversation conversation = await repo.createConversation();
      // 11999 'x' + an astral char (2 units) + 'y' = 12002 units.
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: '${'x' * 11999}𝄞y',
      );

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      expect(history.single.content, 'x' * 11999);
    });

    test('keeps a window that totals exactly 12000 chars', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'a' * 6000,
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: 'b' * 6000,
      );

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      expect(history, hasLength(2));
      expect(history.first.content, 'a' * 6000);
      expect(history.last.content, 'b' * 6000);
    });

    test('drops the oldest when the total is 12001', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'a' * 6000,
      );
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: 'b' * 6001,
      );

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      expect(history, hasLength(1));
      expect(history.single.content, 'b' * 6001);
    });

    test('truncates a message of exactly 12001 chars to 12000', () async {
      final Conversation conversation = await repo.createConversation();
      await repo.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'x' * 12001,
      );

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      expect(history, hasLength(1));
      expect(history.single.content, 'x' * 12000);
    });

    test('applies the message cap before the char limit', () async {
      final Conversation conversation = await repo.createConversation();
      for (int i = 0; i < 35; i++) {
        await repo.addMessage(
          conversationId: conversation.id,
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          content: 'm$i'.padRight(500, 'x'),
        );
      }

      final List<LlmMessage> history = await repo.historyForLlm(
        conversation.id,
      );
      // 35 x 500 = 17500 chars: the cap keeps m5..m34 (15000), then the char
      // limit drops m5..m10, leaving m11..m34 at exactly 12000 chars.
      expect(history, hasLength(24));
      expect(history.first.content.startsWith('m11'), isTrue);
      expect(history.last.content.startsWith('m34'), isTrue);
      final int total = history.fold<int>(
        0,
        (sum, m) => sum + m.content.length,
      );
      expect(total, 12000);
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
