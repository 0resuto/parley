import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/chat/chat_screen.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/tts/tts_service.dart';

import '../../helpers/fake_chat_repository.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_unit_repository.dart';

class FakeSpeechSettings implements SettingsRepository {
  @override
  String get meaningLanguage => 'ru';

  @override
  Future<void> setMeaningLanguage(String value) async {}

  FakeSpeechSettings({this.configured = true, this.autoPlayValue = false});

  bool configured;
  bool autoPlayValue;

  @override
  String get baseUrl => 'https://example.com/v1';

  @override
  String get model => 'test-model';

  @override
  int get newWordPercent => 10;

  @override
  bool get autoPlay => autoPlayValue;

  @override
  double get speechSpeed => 1.0;

  @override
  Future<void> setBaseUrl(String value) async {}

  @override
  Future<void> setModel(String value) async {}

  @override
  Future<void> setNewWordPercent(int value) async {}

  @override
  Future<void> setAutoPlay(bool value) async {
    autoPlayValue = value;
  }

  @override
  Future<void> setSpeechSpeed(double value) async {}

  @override
  bool get contextTranslation => true;

  @override
  Future<void> setContextTranslation(bool value) async {}

  @override
  Future<bool> isLlmConfigured() async => configured;
}

class FakeSpeechLlm implements LlmClient {
  FakeSpeechLlm(this.replies);

  final List<String> replies;
  int _index = 0;
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
    final String reply = _index < replies.length
        ? replies[_index++]
        : replies.last;
    return Stream.fromIterable([TextDelta(reply), const StreamDone()]);
  }
}

class TestTtsService extends FakeTtsService {
  int stopCalls = 0;

  @override
  Future<void> stop() async {
    stopCalls++;
    await super.stop();
  }
}

void main() {
  late FakeClock clock;
  late FakeChatRepository chats;
  late FakeUnitRepository units;
  late FakeSpeechSettings settings;
  late FakeConnectivityService connectivity;
  late FakeSpeechLlm llm;
  late TestTtsService tts;
  late MemoryDocumentStore docs;
  final DateTime initial = DateTime.utc(2026, 4, 1, 12);

  setUp(() {
    clock = FakeClock(initial);
    chats = FakeChatRepository(clock: clock);
    units = FakeUnitRepository(clock: clock);
    settings = FakeSpeechSettings();
    connectivity = FakeConnectivityService();
    docs = MemoryDocumentStore();
  });

  tearDown(() async {
    await connectivity.dispose();
    await tts.dispose();
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
          ttsServiceProvider.overrideWithValue(tts),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('chatInput')), text);
    await tester.tap(find.byKey(const Key('chatSendButton')));
    await tester.pumpAndSettle();
  }

  Future<List<ChatMessage>> allMessages() async {
    final List<Conversation> conversations = await chats.listConversations();
    expect(conversations, isNotEmpty);
    return chats.listMessages(conversations.first.id);
  }

  group('Chat speech 8.2', () {
    testWidgets('play speaks and stop returns to Play, text unchanged', (
      WidgetTester tester,
    ) async {
      llm = FakeSpeechLlm(['Say [[heifer]] please']);
      tts = TestTtsService();
      await pumpChat(tester);

      await send(tester, 'hi');

      // Visible text is stripped of markers.
      expect(find.text('Say heifer please'), findsOneWidget);
      expect(find.textContaining('[['), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      // Play passes the message through TTS (service cleans markers).
      expect(tts.spokenTexts, hasLength(1));
      expect(cleanTtsText(tts.spokenTexts.single), 'Say heifer please');
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      // Visible text is unchanged by audio.
      expect(find.text('Say heifer please'), findsOneWidget);
      expect(find.textContaining('[['), findsNothing);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pumpAndSettle();

      expect(tts.stopCalls, 1);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);
      expect(find.text('Say heifer please'), findsOneWidget);
    });

    testWidgets('switching messages stops the first', (
      WidgetTester tester,
    ) async {
      llm = FakeSpeechLlm(['first reply', 'second reply']);
      tts = TestTtsService();
      await pumpChat(tester);

      await send(tester, 'one');
      await send(tester, 'two');

      expect(find.text('first reply'), findsOneWidget);
      expect(find.text('second reply'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.play_arrow).first);
      await tester.pumpAndSettle();

      expect(tts.spokenTexts, ['first reply']);
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(tts.spokenTexts, ['first reply', 'second reply']);
      // Only one message plays at a time.
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      // Both texts are still visible and unchanged.
      expect(find.text('first reply'), findsOneWidget);
      expect(find.text('second reply'), findsOneWidget);
    });

    testWidgets('auto-play on speaks the reply without tapping', (
      WidgetTester tester,
    ) async {
      settings.autoPlayValue = true;
      llm = FakeSpeechLlm(['auto hello']);
      tts = TestTtsService();
      await pumpChat(tester);

      await send(tester, 'hi');

      expect(find.text('auto hello'), findsOneWidget);
      expect(tts.spokenTexts, ['auto hello']);
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('auto-play off speaks nothing', (WidgetTester tester) async {
      settings.autoPlayValue = false;
      llm = FakeSpeechLlm(['quiet hello']);
      tts = TestTtsService();
      await pumpChat(tester);

      await send(tester, 'hi');

      expect(find.text('quiet hello'), findsOneWidget);
      expect(tts.spokenTexts, isEmpty);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);
    });

    testWidgets('play buttons use per-message keys', (
      WidgetTester tester,
    ) async {
      llm = FakeSpeechLlm(['keyed reply']);
      tts = TestTtsService();
      await pumpChat(tester);

      await send(tester, 'hi');

      final List<ChatMessage> messages = await allMessages();
      final ChatMessage assistant = messages.firstWhere(
        (m) => m.role == ChatRole.assistant,
      );
      expect(
        find.byKey(Key('assistantPlayButton_${assistant.id}')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(Key('assistantPlayButton_${assistant.id}')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('assistantStopButton_${assistant.id}')),
        findsOneWidget,
      );
      expect(tts.spokenTexts, ['keyed reply']);
    });
  });
}
