/// Chat conversations and messages (SPEC 4.1, 5.3).
///
/// Hand-written models mirroring the `conversations` and `messages` tables.
/// [ChatRole.event] messages store JSON, are shown as chips and are never
/// sent to the LLM.
enum ChatRole {
  /// Message typed by the learner.
  user('user'),

  /// Reply from the tutor.
  assistant('assistant'),

  /// System chip (e.g. rules updated), never sent to the LLM.
  event('event');

  const ChatRole(this.value);

  final String value;

  static ChatRole fromValue(String value) {
    switch (value) {
      case 'user':
        return ChatRole.user;
      case 'assistant':
        return ChatRole.assistant;
      case 'event':
        return ChatRole.event;
      default:
        throw ArgumentError('Invalid ChatRole value: $value');
    }
  }
}

/// One chat conversation (SPEC 4.1, 5.3).
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation copyWith({
    int? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() => 'Conversation(id: $id, title: $title)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Conversation &&
        other.id == id &&
        other.title == title &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(id, title, createdAt, updatedAt);
}

/// One chat message (SPEC 4.1).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    required this.processedByNotes,
  });

  final int id;
  final int conversationId;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final bool processedByNotes;

  ChatMessage copyWith({
    int? id,
    int? conversationId,
    ChatRole? role,
    String? content,
    DateTime? createdAt,
    bool? processedByNotes,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      processedByNotes: processedByNotes ?? this.processedByNotes,
    );
  }

  @override
  String toString() =>
      'ChatMessage(id: $id, role: ${role.value}, content: $content)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatMessage &&
        other.id == id &&
        other.conversationId == conversationId &&
        other.role == role &&
        other.content == content &&
        other.createdAt == createdAt &&
        other.processedByNotes == processedByNotes;
  }

  @override
  int get hashCode => Object.hash(
    id,
    conversationId,
    role,
    content,
    createdAt,
    processedByNotes,
  );
}
