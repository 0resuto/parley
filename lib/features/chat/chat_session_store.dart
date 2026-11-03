import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which conversation was open when the app was last used.
abstract class ChatSessionStore {
  int? get lastConversationId;

  Future<void> setLastConversationId(int? id);
}

/// SharedPreferences implementation used by the real app.
class SharedPreferencesChatSessionStore implements ChatSessionStore {
  SharedPreferencesChatSessionStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kLastConversationId = 'last_conversation_id';

  @override
  int? get lastConversationId => _prefs.getInt(_kLastConversationId);

  @override
  Future<void> setLastConversationId(int? id) async {
    if (id == null) {
      await _prefs.remove(_kLastConversationId);
    } else {
      await _prefs.setInt(_kLastConversationId, id);
    }
  }
}

/// In-memory implementation used by tests.
class MemoryChatSessionStore implements ChatSessionStore {
  MemoryChatSessionStore({int? lastConversationId})
    : _lastConversationId = lastConversationId;

  int? _lastConversationId;

  @override
  int? get lastConversationId => _lastConversationId;

  @override
  Future<void> setLastConversationId(int? id) async {
    _lastConversationId = id;
  }
}

/// Last-opened conversation storage. Tests use the in-memory default;
/// `main()` overrides it with [SharedPreferencesChatSessionStore].
final chatSessionStoreProvider = Provider<ChatSessionStore>((ref) {
  return MemoryChatSessionStore();
});
