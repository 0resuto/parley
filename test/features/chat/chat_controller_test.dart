import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/data/db/database.dart' hide Conversation;
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';

class FakeChatSettings implements SettingsRepository {
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
  Future<bool> isLlmConfigured() async => configured;
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
  late AppDatabase db;
  late FakeClock clock;
  late FakeChatSettings settings;
  late FakeConnectivityService connectivity;
  late FakeChatLlmClient llm;
  late MemoryDocumentStore docs;
  late ProviderContainer container;
  final DateTime initial = DateTime.utc(2026, 4, 1, 12);

  ProviderContainer makeContainer({ChatReplyHook? hook}) {
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        settingsRepositoryProvider.overrideWithValue(settings),
        documentStoreProvider.overrideWithValue(docs),
        connectivityServiceProvider.overrideWithValue(connectivity),
        llmClientProvider.overrideWithValue(llm),
        if (hook != null) chatReplyHookProvider.overrideWithValue(hook),
      ],
    );
  }

  Future<int> makeConversation() async {
    final ChatRepository chats = container.read(chatRepositoryProvider);
    final Conversation conversation = await chats.createConversation();
    return conversation.id;
  }

  ChatController notifier(int id) {
    return container.read(chatControllerProvider(id).notifier);
  }

  ChatState stateOf(int id) => container.read(chatControllerProvider(id));

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    settings = FakeChatSettings();
    connectivity = FakeConnectivityService();
    llm = FakeChatLlmClient();
    docs = MemoryDocumentStore();
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    await connectivity.dispose();
    await db.close();
  });

  group('ChatController 6.3', () {
    test('normal stream persists user and assistant', () async {
      int hooks = 0;
      container.dispose();
      container = makeContainer(
        hook: (_) async {
          hooks++;
        },
      );
      final int id = await makeConversation();
      await notifier(id).refresh();
      llm.streamHandler = (_) => Stream.fromIterable([
        const TextDelta('Hello'),
        const TextDelta(' world'),
        const StreamDone(),
      ]);

      await notifier(id).send('hi');

      final ChatState state = stateOf(id);
      expect(state.isStreaming, isFalse);
      expect(state.error, isNull);
      expect(state.draft, isEmpty);
      expect(state.messages, hasLength(2));
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].content, 'hi');
      expect(state.messages[1].role, ChatRole.assistant);
      expect(state.messages[1].content, 'Hello world');
      expect(state.streamingText, isEmpty);
      expect(hooks, 1);
      // Request is system + history with the new user message.
      expect(llm.streamCalls, hasLength(1));
      final List<LlmMessage> request = llm.streamCalls.single;
      expect(request.first.role, LlmRole.system);
      expect(request.map((m) => m.content), contains('hi'));
    });

    test('stop keeps partial text', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;

      final Future<void> sending = notifier(id).send('hello');
      // Let send() persist the user message and subscribe.
      for (int i = 0; i < 20 && !stateOf(id).isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(stateOf(id).isStreaming, isTrue);
      events.add(const TextDelta('par'));
      for (int i = 0; i < 20 && stateOf(id).streamingText != 'par'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(stateOf(id).streamingText, 'par');

      await notifier(id).stop();
      await sending;

      final ChatState state = stateOf(id);
      expect(state.isStreaming, isFalse);
      expect(state.messages, hasLength(2));
      expect(state.messages.last.role, ChatRole.assistant);
      expect(state.messages.last.content, 'par');
      await events.close();
    });

    test('empty stop saves nothing', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;

      final Future<void> sending = notifier(id).send('hello');
      for (int i = 0; i < 20 && !stateOf(id).isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(stateOf(id).isStreaming, isTrue);

      await notifier(id).stop();
      await sending;

      final ChatState state = stateOf(id);
      expect(state.isStreaming, isFalse);
      expect(state.messages, hasLength(1));
      expect(state.messages.single.role, ChatRole.user);
      await events.close();
    });

    test('mid-stream error discards partial and retry succeeds', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      llm.streamHandler = (_) {
        final StreamController<LlmEvent> events = StreamController<LlmEvent>();
        Future(() {
          events.add(const TextDelta('partial '));
          events.addError(const ServerFailure());
        });
        return events.stream;
      };

      await notifier(id).send('hi');

      ChatState state = stateOf(id);
      expect(state.isStreaming, isFalse);
      expect(state.error, isA<ServerFailure>());
      expect(state.streamingText, isEmpty);
      // Partial text is discarded: only the user message remains.
      expect(state.messages, hasLength(1));
      expect(state.messages.single.role, ChatRole.user);

      llm.streamHandler = (_) => Stream.fromIterable([
        const TextDelta('recovered'),
        const StreamDone(),
      ]);
      await notifier(id).retry();

      state = stateOf(id);
      expect(state.error, isNull);
      expect(state.isStreaming, isFalse);
      expect(state.messages, hasLength(2));
      expect(state.messages[1].role, ChatRole.assistant);
      expect(state.messages[1].content, 'recovered');
      expect(llm.streamCalls, hasLength(2));
      // Retry sends no new user message: history still has one user turn.
      final List<LlmMessage> retryRequest = llm.streamCalls.last;
      final int userCount = retryRequest
          .where((m) => m.role == LlmRole.user)
          .length;
      expect(userCount, 1);
    });

    test('offline send keeps typed text and saves nothing', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      connectivity.setOnline(false);

      await notifier(id).send('hello offline');

      final ChatState state = stateOf(id);
      expect(state.error, isA<OfflineFailure>());
      expect(state.error!.userMessage, "This feature isn't available offline.");
      expect(state.draft, 'hello offline');
      expect(state.messages, isEmpty);
      expect(state.isStreaming, isFalse);
      expect(llm.streamCalls, isEmpty);
    });

    test('not configured send saves nothing', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      settings.configured = false;

      await notifier(id).send('hello');

      final ChatState state = stateOf(id);
      expect(state.error, isA<NotConfiguredFailure>());
      expect(state.messages, isEmpty);
      expect(state.isStreaming, isFalse);
      expect(llm.streamCalls, isEmpty);
    });

    test('blank send is ignored', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();

      await notifier(id).send('   ');

      expect(stateOf(id).messages, isEmpty);
      expect(stateOf(id).error, isNull);
      expect(llm.streamCalls, isEmpty);
    });

    test('retry without a user message does nothing', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();

      await notifier(id).retry();

      expect(stateOf(id).messages, isEmpty);
      expect(llm.streamCalls, isEmpty);
      expect(stateOf(id).isStreaming, isFalse);
    });
  });
}
