import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/services/llm/llm_client.dart';

/// In-memory fake of [ChatRepository] for widget tests.
///
/// Mirrors the real repository without touching drift, so widget tests
/// have no pending stream timers. Titles, ordering and [historyForLlm]
/// trimming match the real implementation.
class FakeChatRepository implements ChatRepository {
  FakeChatRepository({required Clock clock}) : _clock = clock;

  final Clock _clock;
  final List<Conversation> _conversations = [];
  final List<ChatMessage> _messages = [];
  int _nextConversationId = 1;
  int _nextMessageId = 1;

  @override
  Future<Conversation> createConversation({String? title}) async {
    final DateTime now = _clock.now().toUtc();
    final Conversation conversation = Conversation(
      id: _nextConversationId++,
      title: title ?? 'New chat',
      createdAt: now,
      updatedAt: now,
    );
    _conversations.add(conversation);
    return conversation;
  }

  @override
  Future<Conversation?> getConversation(int id) async {
    for (final Conversation conversation in _conversations) {
      if (conversation.id == id) {
        return conversation;
      }
    }
    return null;
  }

  @override
  Future<List<Conversation>> listConversations() async {
    final List<Conversation> sorted = _conversations.toList()
      ..sort((a, b) {
        final int byUpdated = b.updatedAt.compareTo(a.updatedAt);
        if (byUpdated != 0) {
          return byUpdated;
        }
        return b.id.compareTo(a.id);
      });
    return sorted;
  }

  @override
  Stream<List<Conversation>> watchConversations() {
    return Stream.value(_conversations.toList());
  }

  @override
  Future<void> deleteConversation(int id) async {
    _conversations.removeWhere((c) => c.id == id);
    _messages.removeWhere((m) => m.conversationId == id);
  }

  @override
  Future<ChatMessage> addMessage({
    required int conversationId,
    required ChatRole role,
    required String content,
  }) async {
    final DateTime now = _clock.now().toUtc();
    final ChatMessage message = ChatMessage(
      id: _nextMessageId++,
      conversationId: conversationId,
      role: role,
      content: content,
      createdAt: now,
      processedByNotes: false,
    );
    _messages.add(message);

    String? nextTitle;
    if (role == ChatRole.user) {
      final String trimmed = content.trim();
      if (trimmed.isNotEmpty) {
        int nonBlank = 0;
        for (final ChatMessage existing in _messages) {
          if (existing.conversationId == conversationId &&
              existing.role == ChatRole.user &&
              existing.content.trim().isNotEmpty) {
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
    final int index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      final Conversation current = _conversations[index];
      _conversations[index] = current.copyWith(
        updatedAt: now,
        title: nextTitle ?? current.title,
      );
    }
    return message;
  }

  @override
  Future<ChatMessage?> getMessage(int id) async {
    for (final ChatMessage message in _messages) {
      if (message.id == id) {
        return message;
      }
    }
    return null;
  }

  @override
  Future<List<ChatMessage>> listMessages(int conversationId) async {
    final List<ChatMessage> rows =
        _messages.where((m) => m.conversationId == conversationId).toList()
          ..sort((a, b) {
            final int byCreated = a.createdAt.compareTo(b.createdAt);
            if (byCreated != 0) {
              return byCreated;
            }
            return a.id.compareTo(b.id);
          });
    return rows;
  }

  @override
  Stream<List<ChatMessage>> watchMessages(int conversationId) {
    return Stream.value(
      _messages.where((m) => m.conversationId == conversationId).toList(),
    );
  }

  @override
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

  @override
  Future<int> unprocessedUserCount({int? conversationId}) async {
    int count = 0;
    for (final ChatMessage message in _messages) {
      if (message.role != ChatRole.user || message.processedByNotes) {
        continue;
      }
      if (conversationId != null && message.conversationId != conversationId) {
        continue;
      }
      count++;
    }
    return count;
  }

  @override
  Future<void> markProcessed(List<int> messageIds) async {
    if (messageIds.isEmpty) {
      return;
    }
    final Set<int> ids = messageIds.toSet();
    for (int i = 0; i < _messages.length; i++) {
      if (ids.contains(_messages[i].id)) {
        _messages[i] = _messages[i].copyWith(processedByNotes: true);
      }
    }
  }

  @override
  Future<void> updateMessageContent(int id, String content) async {
    for (int i = 0; i < _messages.length; i++) {
      if (_messages[i].id == id) {
        _messages[i] = _messages[i].copyWith(content: content);
        return;
      }
    }
  }
}
