import 'package:flutter/foundation.dart';

import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/services/llm/llm_client.dart';

/// Demo chat is available in debug builds or when explicitly enabled with
/// `--dart-define=DEMO_CHAT=true`.
const bool demoChatEnabled = kDebugMode || bool.fromEnvironment('DEMO_CHAT');

/// Marker title of the seeded demo conversation.
const String demoChatTitle = 'Demo chat';

/// Creates (or reopens) the demo conversation in the regular chat history.
Future<int> ensureDemoChat(ChatRepository chats) async {
  final List<Conversation> conversations = await chats.listConversations();
  for (final Conversation conversation in conversations) {
    if (conversation.title == demoChatTitle) {
      final List<ChatMessage> messages = await chats.listMessages(
        conversation.id,
      );
      if (messages.isEmpty) {
        await _seed(chats, conversation.id);
      }
      return conversation.id;
    }
  }
  final Conversation created = await chats.createConversation();
  await _seed(chats, created.id);
  return created.id;
}

Future<void> _seed(ChatRepository chats, int conversationId) async {
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.user,
    content: demoChatTitle,
  );
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.assistant,
    content:
        'This is a local demo conversation. No API key or network is used '
        'here, so it is safe to test copy, edit and regenerate.',
  );
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.user,
    content: 'Can you explain the word "heifer"?',
  );
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.assistant,
    content:
        'A heifer is a young female cow that has not had a calf yet. '
        'It is a useful word on a farm.',
  );
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.user,
    content: 'I went to the park and read a book.',
  );
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.assistant,
    content:
        'Nice! You can also say it in the present perfect: '
        '"I have been to the park and read a book." What did you read?',
  );
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.user,
    content: 'What should I practice next?',
  );
  await chats.addMessage(
    conversationId: conversationId,
    role: ChatRole.assistant,
    content:
        'Tell me one thing you did today. I will reply with a short '
        'correction and a follow-up question.',
  );
}

/// Uses canned replies for the demo conversation and the real client elsewhere.
Future<LlmClient> resolveChatLlmClient({
  required ChatRepository chats,
  required int conversationId,
  required LlmClient real,
}) async {
  if (!demoChatEnabled) {
    return real;
  }
  try {
    final Conversation? conversation = await chats.getConversation(
      conversationId,
    );
    if (conversation?.title == demoChatTitle) {
      return demoLlmClient;
    }
  } catch (_) {
    // Fall through to the real client.
  }
  return real;
}

/// Streams short canned replies with a small typing delay.
class DemoLlmClient implements LlmClient {
  int _turn = 0;

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    return '{}';
  }

  @override
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  }) async* {
    final String user = messages
        .lastWhere(
          (LlmMessage message) => message.role == LlmRole.user,
          orElse: () => const LlmMessage(role: LlmRole.user, content: 'Hello'),
        )
        .content;
    _turn++;
    final String reply = switch (_turn % 3) {
      1 =>
        'This is a local demo reply. No API key or network is used. '
            'You said: "$user". Ask me to explain a word or correct a sentence.',
      2 =>
        'Good practice! You wrote: "$user". '
            'Try saying it in the past tense now.',
      _ =>
        'Demo reply #$_turn. I can keep answering locally, '
            'so you can test the message actions again.',
    };
    for (final String word in reply.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      yield TextDelta('$word ');
    }
    yield const StreamDone();
  }
}

/// One shared instance so regenerating produces a different reply.
final DemoLlmClient demoLlmClient = DemoLlmClient();
