import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_screen.dart';
import 'package:parley/features/chat/rules_tool.dart';
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

class FakeChipSettings implements SettingsRepository {
  FakeChipSettings({this.configured = true});

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

class FakeChipLlmClient implements LlmClient {
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

void main() {
  late FakeClock clock;
  late FakeChatRepository chats;
  late FakeUnitRepository units;
  late FakeChipSettings settings;
  late FakeConnectivityService connectivity;
  late FakeChipLlmClient llm;
  late MemoryDocumentStore docs;
  final DateTime initial = DateTime.utc(2026, 4, 1, 12);

  setUp(() {
    clock = FakeClock(initial);
    chats = FakeChatRepository(clock: clock);
    units = FakeUnitRepository(clock: clock);
    settings = FakeChipSettings();
    connectivity = FakeConnectivityService();
    llm = FakeChipLlmClient();
    docs = MemoryDocumentStore(rules: 'old rules', clock: clock);
  });

  tearDown(() async {
    await connectivity.dispose();
  });

  Future<int> seedRulesEvent() async {
    final Conversation conversation = await chats.createConversation();
    await chats.addMessage(
      conversationId: conversation.id,
      role: ChatRole.user,
      content: 'please shorten the rules',
    );
    await docs.write(DocumentKind.rules, 'new rules text');
    final versions = await docs.versions(DocumentKind.rules);
    final String eventJson = buildRulesUpdatedEvent(
      summary: 'shorter',
      versionId: versions.single.id,
    );
    await chats.addMessage(
      conversationId: conversation.id,
      role: ChatRole.event,
      content: eventJson,
    );
    await chats.addMessage(
      conversationId: conversation.id,
      role: ChatRole.assistant,
      content: 'Done.',
    );
    return conversation.id;
  }

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

  group('ChatScreen 6.8 rules chips', () {
    testWidgets('tool flow shows Rules updated chip', (
      WidgetTester tester,
    ) async {
      await seedRulesEvent();
      await pumpChat(tester);

      expect(find.text('Rules updated'), findsOneWidget);
      expect(find.byKey(const Key('rulesUndoButton')), findsOneWidget);
      expect(find.byKey(const Key('rulesViewButton')), findsOneWidget);
      expect(find.text('Done.'), findsOneWidget);
    });

    testWidgets('Undo restores old text and shows Reverted', (
      WidgetTester tester,
    ) async {
      await seedRulesEvent();
      expect(await docs.read(DocumentKind.rules), 'new rules text');
      await pumpChat(tester);

      await tester.tap(find.byKey(const Key('rulesUndoButton')));
      await tester.pumpAndSettle();

      expect(await docs.read(DocumentKind.rules), 'old rules');
      expect(find.text('Reverted'), findsOneWidget);
      expect(find.byKey(const Key('rulesUndoButton')), findsNothing);
    });

    testWidgets('View opens the Rules screen', (WidgetTester tester) async {
      await seedRulesEvent();
      await pumpChat(tester);

      await tester.tap(find.byKey(const Key('rulesViewButton')));
      await tester.pumpAndSettle();

      expect(find.text('Rules'), findsWidgets);
      expect(find.text('new rules text'), findsOneWidget);
    });

    testWidgets('unknown event JSON falls back to raw chip', (
      WidgetTester tester,
    ) async {
      final Conversation conversation = await chats.createConversation();
      await chats.addMessage(
        conversationId: conversation.id,
        role: ChatRole.event,
        content: jsonEncode({'type': 'other'}),
      );
      await pumpChat(tester);

      expect(find.text('Rules updated'), findsNothing);
      expect(find.text(jsonEncode({'type': 'other'})), findsOneWidget);
    });
  });
}
