import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_screen.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_chat_repository.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_unit_repository.dart';

class FakeChatSettings implements SettingsRepository {
  @override
  String get meaningLanguage => 'ru';

  @override
  Future<void> setMeaningLanguage(String value) async {}

  FakeChatSettings({this.configured = true});

  bool configured;

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
  bool get contextTranslation => true;

  @override
  Future<void> setContextTranslation(bool value) async {}

  @override
  Future<bool> isLlmConfigured() async => configured;
}

/// [FakeChatRepository] double that always fails the initial load (9.1).
class FailingChatLoadRepository extends FakeChatRepository {
  FailingChatLoadRepository({required super.clock});

  @override
  Future<List<Conversation>> listConversations() async {
    throw StateError('db unavailable');
  }
}

/// [FakeChatRepository] double that fails once, then works (for Retry).
class FlakyChatLoadRepository extends FakeChatRepository {
  FlakyChatLoadRepository({required super.clock});

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

class FakeChatLlmClient implements LlmClient {
  FakeChatLlmClient({this.streamHandler});

  Stream<LlmEvent> Function(List<LlmMessage> messages)? streamHandler;
  final List<List<LlmMessage>> streamCalls = [];

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
    streamCalls.add(messages);
    if (streamHandler != null) {
      return streamHandler!(messages);
    }
    return Stream.value(const StreamDone());
  }
}

void main() {
  late FakeClock clock;
  late FakeChatRepository chats;
  late FakeUnitRepository units;
  late FakeChatSettings settings;
  late FakeConnectivityService connectivity;
  late FakeChatLlmClient llm;
  late MemoryDocumentStore docs;
  final DateTime initial = DateTime.utc(2026, 4, 1, 12);

  setUp(() {
    clock = FakeClock(initial);
    chats = FakeChatRepository(clock: clock);
    units = FakeUnitRepository(clock: clock);
    settings = FakeChatSettings();
    connectivity = FakeConnectivityService();
    llm = FakeChatLlmClient();
    docs = MemoryDocumentStore();
  });

  tearDown(() async {
    await connectivity.dispose();
  });

  Future<void> pumpChat(WidgetTester tester) async {
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
  }

  group('ChatScreen 6.4', () {
    testWidgets('send shows user bubble and streamed reply', (
      WidgetTester tester,
    ) async {
      llm.streamHandler = (_) => Stream.fromIterable([
        const TextDelta('Hello there'),
        const StreamDone(),
      ]);
      await pumpChat(tester);

      expect(find.text('No messages yet. Say hello!'), findsOneWidget);
      // New conversation: title and AppBar action share the text.
      expect(find.text('New chat'), findsNWidgets(2));
      expect(find.byKey(const Key('chatInput')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello chat');
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pumpAndSettle();

      // User message appears (bubble) and the title retitles to it,
      // so it shows twice; the assistant reply shows once.
      expect(find.text('hello chat'), findsWidgets);
      expect(find.text('Hello there'), findsOneWidget);
      // Composer is cleared after a successful send.
      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      expect(input.controller?.text ?? '', isEmpty);
    });

    testWidgets('Stop button during streaming keeps partial', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChat(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      // Wait until streaming starts.
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('chatStopButton')), findsOneWidget);
      expect(find.byKey(const Key('chatSendButton')), findsNothing);

      events.add(const TextDelta('par'));
      await tester.pump();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('par').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.text('par'), findsWidgets);

      await tester.tap(find.byKey(const Key('chatStopButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chatSendButton')), findsOneWidget);
      expect(find.text('par'), findsWidgets);
      // Close with real async: cancelling the stopped subscription needs
      // real async and would hang under FakeAsync.
      await tester.runAsync(() => events.close());
    });

    testWidgets('error banner with Retry recovers', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      llm.streamHandler = (_) {
        calls++;
        if (calls == 1) {
          final StreamController<LlmEvent> errorStream =
              StreamController<LlmEvent>();
          Future(() {
            errorStream.add(const TextDelta('partial '));
            errorStream.addError(const ServerFailure());
          });
          return errorStream.stream;
        }
        return Stream.fromIterable([
          const TextDelta('recovered'),
          const StreamDone(),
        ]);
      };
      await pumpChat(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hi');
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pumpAndSettle();

      expect(find.text(const ServerFailure().userMessage), findsOneWidget);
      expect(find.byKey(const Key('chatRetryButton')), findsOneWidget);
      // Partial text is discarded.
      expect(find.text('partial '), findsNothing);

      await tester.tap(find.byKey(const Key('chatRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('recovered'), findsOneWidget);
      expect(find.text(const ServerFailure().userMessage), findsNothing);
      expect(calls, 2);
    });

    testWidgets('offline send keeps typed text and shows message', (
      WidgetTester tester,
    ) async {
      connectivity.setOnline(false);
      await pumpChat(tester);

      await tester.enterText(
        find.byKey(const Key('chatInput')),
        'hello offline',
      );
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pumpAndSettle();

      expect(find.text(const OfflineFailure().userMessage), findsOneWidget);
      expect(llm.streamCalls, isEmpty);
      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      expect(input.controller?.text, 'hello offline');
    });

    testWidgets('initial load failure shows an error with Retry', (
      WidgetTester tester,
    ) async {
      final FailingChatLoadRepository failing = FailingChatLoadRepository(
        clock: clock,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(failing),
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

      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(find.byKey(const Key('chatLoadRetryButton')), findsOneWidget);
    });

    testWidgets('Retry after initial load failure opens the chat', (
      WidgetTester tester,
    ) async {
      final FlakyChatLoadRepository flaky = FlakyChatLoadRepository(
        clock: clock,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(flaky),
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

      expect(find.text('Something went wrong.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chatLoadRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsNothing);
      expect(find.text('No messages yet. Say hello!'), findsOneWidget);
    });
  });
}
