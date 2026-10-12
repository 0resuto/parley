import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/data/db/database.dart' hide Conversation;
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/chat/rules_tool.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';

class FakeRulesSettings implements SettingsRepository {
  @override
  String get meaningLanguage => 'ru';

  @override
  Future<void> setMeaningLanguage(String value) async {}

  FakeRulesSettings({this.configured = true});

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

class FakeRulesLlmClient implements LlmClient {
  FakeRulesLlmClient({this.handler});

  Stream<LlmEvent> Function(
    List<LlmMessage> messages,
    List<Map<String, dynamic>>? tools,
  )?
  handler;

  final List<List<LlmMessage>> messageCalls = [];
  final List<List<Map<String, dynamic>>?> toolsCalls = [];

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
    messageCalls.add(messages);
    toolsCalls.add(tools);
    if (handler != null) {
      return handler!(messages, tools);
    }
    return Stream.value(const StreamDone());
  }
}

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late FakeRulesSettings settings;
  late FakeConnectivityService connectivity;
  late FakeRulesLlmClient llm;
  late MemoryDocumentStore docs;
  late ProviderContainer container;
  final DateTime initial = DateTime.utc(2026, 4, 1, 12);

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        settingsRepositoryProvider.overrideWithValue(settings),
        documentStoreProvider.overrideWithValue(docs),
        connectivityServiceProvider.overrideWithValue(connectivity),
        llmClientProvider.overrideWithValue(llm),
      ],
    );
  }

  Future<int> makeConversation() async {
    final ChatRepository chats = container.read(chatRepositoryProvider);
    final Conversation conversation = await chats.createConversation();
    return conversation.id;
  }

  ChatController notifier(int id) {
    // The controller provider is auto-disposed (A-31): keep a listener so
    // the state survives between calls in this test.
    container.listen(chatControllerProvider(id), (_, _) {});
    return container.read(chatControllerProvider(id).notifier);
  }

  ChatState stateOf(int id) {
    container.listen(chatControllerProvider(id), (_, _) {});
    return container.read(chatControllerProvider(id));
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    settings = FakeRulesSettings();
    connectivity = FakeConnectivityService();
    llm = FakeRulesLlmClient();
    docs = MemoryDocumentStore(rules: 'old rules', clock: clock);
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    await connectivity.dispose();
    await db.close();
  });

  group('ChatController 6.8 update_rules', () {
    test('successful call writes rules and appends event', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      int calls = 0;
      llm.handler = (messages, tools) {
        calls++;
        if (calls == 1) {
          expect(tools, isNotNull);
          expect(tools!.single['function']['name'], 'update_rules');
          return Stream.fromIterable([
            ToolCallRequest(
              id: 'call-1',
              name: 'update_rules',
              argsJson: jsonEncode({
                'content': 'new rules text',
                'summary': 'shorter rules',
              }),
            ),
            const StreamDone(),
          ]);
        }
        final toolMsg = messages.where((m) => m.role == LlmRole.tool);
        expect(toolMsg, hasLength(1));
        expect(toolMsg.single.content, 'OK: rules updated.');
        return Stream.fromIterable([
          const TextDelta('Done, I updated the rules.'),
          const StreamDone(),
        ]);
      };

      await notifier(id).send('please make the rules shorter');

      final ChatState state = stateOf(id);
      expect(state.isStreaming, isFalse);
      expect(state.error, isNull);
      expect(await docs.read(DocumentKind.rules), 'new rules text');
      final versions = await docs.versions(DocumentKind.rules);
      expect(versions, hasLength(1));
      expect(versions.single.text, 'old rules');
      // user + event + assistant.
      expect(state.messages, hasLength(3));
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[1].role, ChatRole.event);
      final event = parseRulesUpdatedEvent(state.messages[1].content);
      expect(event, isNotNull);
      expect(event!.summary, 'shorter rules');
      expect(event.versionId, versions.single.id);
      expect(event.reverted, isFalse);
      expect(state.messages[2].role, ChatRole.assistant);
      expect(state.messages[2].content, 'Done, I updated the rules.');
      expect(calls, 2);
    });

    test('too-long args get ERROR result and no write', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      final String long = List.filled(rulesLimit + 1, 'a').join();
      int calls = 0;
      llm.handler = (messages, tools) {
        calls++;
        if (calls == 1) {
          return Stream.fromIterable([
            ToolCallRequest(
              id: 'c1',
              name: 'update_rules',
              argsJson: jsonEncode({'content': long, 'summary': 'x'}),
            ),
            const StreamDone(),
          ]);
        }
        final toolMsg = messages.where((m) => m.role == LlmRole.tool);
        expect(toolMsg.single.content, contains('ERROR: too long'));
        expect(
          toolMsg.single.content,
          'ERROR: too long (${rulesLimit + 1} > $rulesLimit). '
          'Shorten it and call again.',
        );
        return Stream.fromIterable([
          const TextDelta('That is too long.'),
          const StreamDone(),
        ]);
      };

      await notifier(id).send('change rules');

      expect(await docs.read(DocumentKind.rules), 'old rules');
      expect(await docs.versions(DocumentKind.rules), isEmpty);
      final ChatState state = stateOf(id);
      // No event on validation failure: user + assistant only.
      expect(state.messages, hasLength(2));
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[1].content, 'That is too long.');
      expect(calls, 2);
    });

    test('invalid JSON args handled with empty ERROR', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      int calls = 0;
      llm.handler = (messages, tools) {
        calls++;
        if (calls == 1) {
          return Stream.fromIterable([
            const ToolCallRequest(
              id: 'c1',
              name: 'update_rules',
              argsJson: 'not json at all',
            ),
            const StreamDone(),
          ]);
        }
        expect(
          messages.where((m) => m.role == LlmRole.tool).single.content,
          'ERROR: content is empty.',
        );
        return Stream.fromIterable([
          const TextDelta('I need the full text.'),
          const StreamDone(),
        ]);
      };

      await notifier(id).send('change rules');

      expect(await docs.read(DocumentKind.rules), 'old rules');
      expect(stateOf(id).messages, hasLength(2));
      expect(calls, 2);
    });

    test('empty content handled with empty ERROR', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      int calls = 0;
      llm.handler = (messages, tools) {
        calls++;
        if (calls == 1) {
          return Stream.fromIterable([
            ToolCallRequest(
              id: 'c1',
              name: 'update_rules',
              argsJson: jsonEncode({'content': '   ', 'summary': 'x'}),
            ),
            const StreamDone(),
          ]);
        }
        expect(
          messages.where((m) => m.role == LlmRole.tool).single.content,
          'ERROR: content is empty.',
        );
        return Stream.fromIterable([const TextDelta('ok'), const StreamDone()]);
      };

      await notifier(id).send('change rules');

      expect(await docs.read(DocumentKind.rules), 'old rules');
      expect(calls, 2);
    });

    test('event is never sent to the LLM', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      int calls = 0;
      llm.handler = (messages, tools) {
        calls++;
        if (calls == 1) {
          return Stream.fromIterable([
            ToolCallRequest(
              id: 'c1',
              name: 'update_rules',
              argsJson: jsonEncode({'content': 'v2 rules', 'summary': 'v2'}),
            ),
            const StreamDone(),
          ]);
        }
        return Stream.fromIterable([
          const TextDelta('done'),
          const StreamDone(),
        ]);
      };

      await notifier(id).send('update please');
      expect(calls, 2);

      final ChatRepository chats = container.read(chatRepositoryProvider);
      final history = await chats.historyForLlm(id);
      for (final m in history) {
        expect(m.content, isNot(contains('rules_updated')));
      }
      expect(history.where((m) => m.role == LlmRole.user), hasLength(1));
      expect(history.where((m) => m.role == LlmRole.assistant), hasLength(1));
    });

    test('no tool call without the model asking', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      llm.handler = (messages, tools) {
        expect(tools, isNotNull);
        expect(tools!.single['function']['name'], 'update_rules');
        return Stream.fromIterable([
          const TextDelta('plain reply'),
          const StreamDone(),
        ]);
      };

      await notifier(id).send('hello');

      expect(await docs.read(DocumentKind.rules), 'old rules');
      final ChatState state = stateOf(id);
      expect(state.messages, hasLength(2));
      expect(state.messages.where((m) => m.role == ChatRole.event), isEmpty);
    });

    test('second tool round falls back without tools', () async {
      final int id = await makeConversation();
      await notifier(id).refresh();
      int calls = 0;
      llm.handler = (messages, tools) {
        calls++;
        if (calls <= 2) {
          expect(tools, isNotNull);
          return Stream.fromIterable([
            ToolCallRequest(
              id: 'c$calls',
              name: 'update_rules',
              argsJson: jsonEncode({
                'content': 'round $calls rules',
                'summary': 'round $calls',
              }),
            ),
            const StreamDone(),
          ]);
        }
        expect(tools, isNull);
        return Stream.fromIterable([
          const TextDelta('final answer'),
          const StreamDone(),
        ]);
      };

      await notifier(id).send('keep changing');

      expect(calls, 3);
      expect(await docs.read(DocumentKind.rules), 'round 2 rules');
      expect(
        stateOf(id).messages.where((m) => m.role == ChatRole.event).length,
        2,
      );
      expect(stateOf(id).messages.last.content, 'final answer');
    });
  });
}
