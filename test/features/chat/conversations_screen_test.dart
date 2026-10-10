import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/chat/chat_screen.dart';
import 'package:parley/features/chat/conversations_screen.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_chat_repository.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_unit_repository.dart';

class FakeHistorySettings implements SettingsRepository {
  @override
  String get baseUrl => 'https://example.com/v1';

  @override
  String get model => 'test-model';

  @override
  int get newWordPercent => 10;

  @override
  bool get autoPlay => false;

  @override
  double get speechSpeed => 1.0;

  @override
  Future<void> setBaseUrl(String value) async {}

  @override
  Future<void> setModel(String value) async {}

  @override
  Future<void> setNewWordPercent(int value) async {}

  @override
  Future<void> setAutoPlay(bool value) async {}

  @override
  Future<void> setSpeechSpeed(double value) async {}

  @override
  Future<bool> isLlmConfigured() async => true;
}

class FakeHistoryLlmClient implements LlmClient {
  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) {
    throw UnimplementedError();
  }

  @override
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  }) {
    return Stream.value(const StreamDone());
  }
}

/// [ChatRepository] double that always fails listing (PLAN 9.1).
class FailingListChatRepository extends FakeChatRepository {
  FailingListChatRepository({required super.clock});

  @override
  Future<List<Conversation>> listConversations() async {
    throw StateError('db unavailable');
  }
}

/// [ChatRepository] double that fails once, then delegates (for Retry).
class FlakyListChatRepository extends FakeChatRepository {
  FlakyListChatRepository({required super.clock});

  bool failNext = true;

  @override
  Future<List<Conversation>> listConversations() async {
    if (failNext) {
      failNext = false;
      throw StateError('db unavailable');
    }
    return super.listConversations();
  }
}

void main() {
  late FakeClock clock;
  late FakeChatRepository chats;
  final DateTime initial = DateTime.utc(2026, 5, 1, 12);

  setUp(() {
    clock = FakeClock(initial);
    chats = FakeChatRepository(clock: clock);
  });

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(chats)],
        child: const MaterialApp(home: ConversationsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ConversationsScreen 6.7', () {
    testWidgets('tap opens the conversation in chat', (
      WidgetTester tester,
    ) async {
      final Conversation first = await chats.createConversation(
        title: 'First chat',
      );
      clock.advance(const Duration(minutes: 1));
      final Conversation second = await chats.createConversation(
        title: 'Second chat',
      );
      await chats.addMessage(
        conversationId: first.id,
        role: ChatRole.user,
        content: 'hello first',
      );
      await chats.addMessage(
        conversationId: second.id,
        role: ChatRole.user,
        content: 'hello second',
      );

      final FakeUnitRepository units = FakeUnitRepository(clock: clock);
      final FakeHistorySettings settings = FakeHistorySettings();
      final FakeConnectivityService connectivity = FakeConnectivityService();
      final FakeHistoryLlmClient llm = FakeHistoryLlmClient();
      final MemoryDocumentStore docs = MemoryDocumentStore();
      addTearDown(() async {
        await connectivity.dispose();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(chats),
            unitRepositoryProvider.overrideWithValue(units),
            clockProvider.overrideWithValue(clock),
            settingsRepositoryProvider.overrideWithValue(settings),
            documentStoreProvider.overrideWithValue(docs),
            connectivityServiceProvider.overrideWithValue(connectivity),
            llmClientProvider.overrideWithValue(llm),
          ],
          child: const MaterialApp(home: ChatScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Chat opens on the most recent conversation: the AppBar title and
      // the user bubble share the text, so it shows twice.
      expect(find.text('hello second'), findsWidgets);

      await tester.tap(find.byKey(const Key('chatHistoryButton')));
      await tester.pumpAndSettle();

      // History is sorted by updated_at: most recent first.
      final ListTile firstTile = tester.widget(
        find.byKey(ValueKey('conversationTile_${second.id}')),
      );
      final ListTile secondTile = tester.widget(
        find.byKey(ValueKey('conversationTile_${first.id}')),
      );
      expect(
        tester
            .getTopLeft(find.byKey(ValueKey('conversationTile_${second.id}')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(ValueKey('conversationTile_${first.id}')))
              .dy,
        ),
      );
      expect(firstTile, isNotNull);
      expect(secondTile, isNotNull);

      await tester.tap(find.text('hello first'));
      await tester.pumpAndSettle();

      // Back in chat showing the picked conversation.
      expect(find.text('hello first'), findsWidgets);
      expect(find.byKey(const Key('chatInput')), findsOneWidget);
    });

    testWidgets('delete with confirmation removes the conversation', (
      WidgetTester tester,
    ) async {
      final Conversation first = await chats.createConversation(
        title: 'First chat',
      );
      clock.advance(const Duration(minutes: 1));
      await chats.createConversation(title: 'Second chat');

      await pumpHistory(tester);

      expect(find.text('First chat'), findsOneWidget);
      expect(find.text('Second chat'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('deleteConversation_${first.id}')));
      await tester.pumpAndSettle();

      expect(find.text('Delete conversation?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirmDeleteButton')));
      await tester.pumpAndSettle();

      expect(find.text('First chat'), findsNothing);
      expect(find.text('Second chat'), findsOneWidget);
      expect(await chats.getConversation(first.id), isNull);
    });

    testWidgets('New chat creates an empty conversation', (
      WidgetTester tester,
    ) async {
      await chats.createConversation(title: 'Old chat');

      await pumpHistory(tester);
      expect(find.byType(ListTile), findsOneWidget);

      await tester.tap(find.byKey(const Key('newChatButton')));
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNWidgets(2));
      expect(find.text('Old chat'), findsOneWidget);
      // The AppBar action and the new empty conversation share the text.
      expect(find.text('New chat'), findsNWidgets(2));
      expect((await chats.listConversations()).length, 2);
    });

    testWidgets('empty state when no conversations', (
      WidgetTester tester,
    ) async {
      await pumpHistory(tester);
      expect(find.text('No conversations yet.'), findsOneWidget);
    });

    testWidgets('load failure shows an error with Retry', (
      WidgetTester tester,
    ) async {
      final FailingListChatRepository failing = FailingListChatRepository(
        clock: clock,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(failing)],
          child: const MaterialApp(home: ConversationsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(find.byKey(const Key('conversationsRetryButton')), findsOneWidget);
      expect(find.text('No conversations yet.'), findsNothing);
    });

    testWidgets('Retry after a failure loads the list', (
      WidgetTester tester,
    ) async {
      final FlakyListChatRepository flaky = FlakyListChatRepository(
        clock: clock,
      );
      await flaky.createConversation(title: 'Old chat');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(flaky)],
          child: const MaterialApp(home: ConversationsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('conversationsRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsNothing);
      expect(find.text('Old chat'), findsOneWidget);
    });
  });
}
