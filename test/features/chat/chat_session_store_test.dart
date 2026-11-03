import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/chat/chat_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('shared preferences store round-trips the last conversation', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SharedPreferencesChatSessionStore store =
        SharedPreferencesChatSessionStore(prefs);

    expect(store.lastConversationId, isNull);

    await store.setLastConversationId(42);
    expect(store.lastConversationId, 42);
    expect(prefs.getInt('last_conversation_id'), 42);

    await store.setLastConversationId(null);
    expect(store.lastConversationId, isNull);
    expect(prefs.getInt('last_conversation_id'), isNull);
  });

  test('memory store round-trips the last conversation', () async {
    final MemoryChatSessionStore store = MemoryChatSessionStore();
    expect(store.lastConversationId, isNull);

    await store.setLastConversationId(7);
    expect(store.lastConversationId, 7);

    await store.setLastConversationId(null);
    expect(store.lastConversationId, isNull);
  });
}
