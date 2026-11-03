import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/core/theme.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_screen.dart';
import 'package:parley/features/chat/chat_session_store.dart';
import 'package:parley/features/chat/stt_mic_button.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/settings/stt_settings.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model_manager.dart';
import 'package:parley/services/stt/stt_providers.dart';
import 'package:parley/services/stt/stt_service.dart';
import 'package:parley/services/tts/tts_service.dart';

import '../../helpers/fake_chat_repository.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_stt_service.dart';
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

/// [FakeChatRepository] whose [getConversation] can be held open (A-35).
class GatedChatRepository extends FakeChatRepository {
  GatedChatRepository({required super.clock});

  int? gatedId;
  Completer<void>? gate;

  @override
  Future<Conversation?> getConversation(int id) async {
    if (id == gatedId) {
      final Completer<void>? blocker = gate;
      if (blocker != null) {
        await blocker.future;
      }
    }
    return super.getConversation(id);
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

class TestModelsController extends SttModelsController {
  TestModelsController({this.ready = true});

  static const SttModelsState _ready =
      SttModelsState(<SttEngineKind, SttModelStatus>{
        SttEngineKind.moonshine: SttModelStatus(phase: SttModelPhase.ready),
        SttEngineKind.whisper: SttModelStatus(
          phase: SttModelPhase.ready,
          progress: 1,
        ),
      });
  static const SttModelsState _empty =
      SttModelsState(<SttEngineKind, SttModelStatus>{
        SttEngineKind.moonshine: SttModelStatus(),
        SttEngineKind.whisper: SttModelStatus(),
      });

  bool ready;

  @override
  SttModelsState build() => ready ? _ready : _empty;

  void setReady(bool value) {
    ready = value;
    state = value ? _ready : _empty;
  }

  @override
  Future<void> ensureRequired() async {}
}

void main() {
  late FakeClock clock;
  late FakeChatRepository chats;
  late FakeUnitRepository units;
  late FakeChatSettings settings;
  late FakeConnectivityService connectivity;
  late FakeChatLlmClient llm;
  late MemoryDocumentStore docs;
  late FakeSttService stt;
  late MemorySttSettings sttSettings;
  late FakeTtsService tts;
  late MemoryChatSessionStore session;
  late TestModelsController models;
  final DateTime initial = DateTime.utc(2026, 4, 1, 12);

  setUp(() {
    clock = FakeClock(initial);
    chats = FakeChatRepository(clock: clock);
    units = FakeUnitRepository(clock: clock);
    settings = FakeChatSettings();
    connectivity = FakeConnectivityService();
    llm = FakeChatLlmClient();
    docs = MemoryDocumentStore();
    stt = FakeSttService();
    sttSettings = MemorySttSettings();
    tts = FakeTtsService();
    session = MemoryChatSessionStore();
    models = TestModelsController();
  });

  tearDown(() async {
    await connectivity.dispose();
    await stt.dispose();
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
          sttServiceProvider.overrideWithValue(stt),
          sttSettingsProvider.overrideWithValue(sttSettings),
          chatSessionStoreProvider.overrideWithValue(session),
          sttModelsControllerProvider.overrideWith(() => models),
          ttsServiceProvider.overrideWithValue(tts),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// [pumpChat] with the real reply hook replaced: it opens the app
  /// database, which leaves a pending timer in the fake-async zone.
  Future<void> pumpChatNoHook(WidgetTester tester) async {
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
          sttServiceProvider.overrideWithValue(stt),
          sttSettingsProvider.overrideWithValue(sttSettings),
          chatSessionStoreProvider.overrideWithValue(session),
          sttModelsControllerProvider.overrideWith(() => models),
          ttsServiceProvider.overrideWithValue(tts),
          chatReplyHookProvider.overrideWithValue((_) async {}),
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
      await tester.pump();
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

    testWidgets('New chat in an empty chat does not create a duplicate', (
      WidgetTester tester,
    ) async {
      await pumpChatNoHook(tester);
      expect(await chats.listConversations(), hasLength(1));
      expect(find.text('No messages yet. Say hello!'), findsOneWidget);

      // The tap is a no-op: the empty chat already is a new chat, and the
      // typed draft survives (PLAN 21.1).
      await tester.enterText(find.byKey(const Key('chatInput')), 'draft');
      await tester.tap(find.byKey(const Key('chatNewChatButton')));
      await tester.pumpAndSettle();

      expect(await chats.listConversations(), hasLength(1));
      expect(find.text('No messages yet. Say hello!'), findsOneWidget);
      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      expect(input.controller?.text, 'draft');
    });

    testWidgets('reopens the last opened chat instead of the newest', (
      WidgetTester tester,
    ) async {
      final Conversation first = await chats.createConversation();
      await chats.addMessage(
        conversationId: first.id,
        role: ChatRole.user,
        content: 'First chat',
      );
      clock.advance(const Duration(minutes: 5));
      final Conversation second = await chats.createConversation();
      await chats.addMessage(
        conversationId: second.id,
        role: ChatRole.user,
        content: 'Second chat',
      );
      await session.setLastConversationId(first.id);

      await pumpChatNoHook(tester);

      expect(find.text('First chat'), findsWidgets);
      expect(find.text('Second chat'), findsNothing);
    });

    testWidgets('falls back when the remembered chat is gone', (
      WidgetTester tester,
    ) async {
      final Conversation only = await chats.createConversation();
      await chats.addMessage(
        conversationId: only.id,
        role: ChatRole.user,
        content: 'Only chat',
      );
      await session.setLastConversationId(999);

      await pumpChatNoHook(tester);

      expect(find.text('Only chat'), findsWidgets);
    });

    testWidgets('New chat after a message starts a fresh conversation', (
      WidgetTester tester,
    ) async {
      llm.streamHandler = (_) =>
          Stream.fromIterable([const TextDelta('reply'), const StreamDone()]);
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chatNewChatButton')));
      await tester.pumpAndSettle();

      expect(await chats.listConversations(), hasLength(2));
      expect(find.text('No messages yet. Say hello!'), findsOneWidget);
    });

    testWidgets('Stop button during streaming keeps partial', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChat(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
      await tester.pump();
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

      expect(find.byKey(const Key('chatSendButton')), findsNothing);
      expect(find.byKey(const Key('chatMicButton')), findsOneWidget);
      expect(find.text('par'), findsWidgets);
      // Close with real async: cancelling the stopped subscription needs
      // real async and would hang under FakeAsync.
      await tester.runAsync(() => events.close());
    });

    testWidgets('typing during a stream is not wiped by send', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'first');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('chatStopButton')).evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const Key('chatStopButton')), findsOneWidget);

      // The user starts the next message while the reply is streaming.
      await tester.enterText(find.byKey(const Key('chatInput')), 'second');

      events.add(const TextDelta('reply'));
      events.add(const StreamDone());
      // Closing needs real async (see the Stop test above).
      await tester.runAsync(() => events.close());
      await tester.pumpAndSettle();

      // The next message typed during the stream must survive the send's
      // completion (A-32).
      expect(find.byKey(const Key('chatSendButton')), findsOneWidget);
      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      expect(input.controller?.text, 'second');
    });

    testWidgets('the composer stays usable while a reply streams', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'first');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('chatStopButton')).evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const Key('chatStopButton')), findsOneWidget);

      // While the reply is still streaming the field accepts the next
      // message; Send is replaced by Stop (T-19).
      await tester.enterText(
        find.byKey(const Key('chatInput')),
        'second draft',
      );
      await tester.pump();

      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      expect(input.controller?.text, 'second draft');
      expect(find.byKey(const Key('chatSendButton')), findsNothing);
      expect(find.byKey(const Key('chatStopButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('chatStopButton')));
      await tester.pumpAndSettle();
      // Stopping keeps the unsent draft.
      final TextField afterStop = tester.widget(
        find.byKey(const Key('chatInput')),
      );
      expect(afterStop.controller?.text, 'second draft');
      await tester.runAsync(() => events.close());
    });

    testWidgets('opens the conversation at the newest message', (
      WidgetTester tester,
    ) async {
      final Conversation conversation = await chats.createConversation();
      for (int i = 0; i < 30; i++) {
        await chats.addMessage(
          conversationId: conversation.id,
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          content:
              'message $i\n'
              '${List<String>.generate(i + 1, (int j) => 'line $j').join('\n')}',
        );
      }

      await pumpChatNoHook(tester);

      final ListView list = tester.widget(find.byKey(const Key('chatList')));
      final ScrollController controller = list.controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));
      // Restarting the app must show the end of the conversation, not the
      // first stored message (bug: list stayed at offset 0).
      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1),
      );
      expect(find.textContaining('message 29'), findsOneWidget);
    });

    testWidgets('hiding the keyboard also drops composer focus', (
      WidgetTester tester,
    ) async {
      addTearDown(tester.view.resetViewInsets);
      await pumpChatNoHook(tester);

      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      final FocusNode focus = input.focusNode!;
      await tester.tap(find.byKey(const Key('chatInput')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      // The keyboard opens, then the system back button hides it while
      // the field itself keeps focus.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      await tester.pump();

      // Without the fix the field stayed focused and any later route or
      // bottom-sheet pop restored focus and reopened the keyboard.
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('tapping the chat keeps the composer focused', (
      WidgetTester tester,
    ) async {
      await pumpChatNoHook(tester);

      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      final FocusNode focus = input.focusNode!;
      await tester.tap(find.byKey(const Key('chatInput')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tapAt(const Offset(400, 400));
      await tester.pump();

      // The keyboard must stay open so the chat can be scrolled.
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('opening history drops composer focus', (
      WidgetTester tester,
    ) async {
      await pumpChatNoHook(tester);

      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      final FocusNode focus = input.focusNode!;
      await tester.tap(find.byKey(const Key('chatInput')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('chatHistoryButton')));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('streaming text keeps the list scrolled to the bottom', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hi');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('chatStopButton')).evaluate().isNotEmpty) {
          break;
        }
      }

      final ListView list = tester.widget(find.byKey(const Key('chatList')));
      final ScrollController controller = list.controller!;
      expect(controller.position.pixels, 0);

      // A long chunk makes the streaming bubble overflow the viewport;
      // the list must follow the growing text (A-33).
      final String long = List<String>.generate(
        80,
        (int i) => 'line $i',
      ).join('\n');
      events.add(TextDelta(long));
      await tester.pumpAndSettle();

      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1),
      );
      await tester.runAsync(() => events.close());
    });

    testWidgets('a growing stream pulls the list back to the bottom', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hi');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('chatStopButton')).evaluate().isNotEmpty) {
          break;
        }
      }

      final ListView list = tester.widget(find.byKey(const Key('chatList')));
      final ScrollController controller = list.controller!;

      final String long = List<String>.generate(
        80,
        (int i) => 'line $i',
      ).join('\n');
      events.add(TextDelta(long));
      await tester.pumpAndSettle();
      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1),
      );

      // The user scrolls up to re-read; the next grown chunk must bring
      // the list back to the newest text (T-19: auto-scroll).
      await tester.drag(
        find.byKey(const Key('chatList')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(
        controller.position.pixels,
        lessThan(controller.position.maxScrollExtent),
      );

      events.add(const TextDelta('\nand more'));
      await tester.pumpAndSettle();
      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1),
      );
      await tester.runAsync(() => events.close());
    });

    testWidgets('streaming text uses the real unit index', (
      WidgetTester tester,
    ) async {
      await units.add(text: 'heifer');
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hi');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('chatStopButton')).evaluate().isNotEmpty) {
          break;
        }
      }

      events.add(const TextDelta('Say heifer please'));
      await tester.pumpAndSettle();

      // Before the reply is persisted the streaming bubble must already
      // highlight the dictionary word (A-34).
      final RichText rich = tester.widget<RichText>(
        find.byWidgetPredicate(
          (Widget w) =>
              w is RichText && w.text.toPlainText().contains('heifer'),
        ),
      );
      final TextSpan root = rich.text as TextSpan;
      // Text wraps the given span in its own root span.
      final TextSpan inner = root.children!.single as TextSpan;
      final TextSpan heifer = inner.children!.whereType<TextSpan>().firstWhere(
        (TextSpan span) => span.text == 'heifer',
      );
      expect(heifer.style?.color, learningWordColor);
      expect(heifer.recognizer, isNotNull);

      await tester.runAsync(() => events.close());
    });

    testWidgets('a slow switch cannot overwrite a newer one', (
      WidgetTester tester,
    ) async {
      final GatedChatRepository gated = GatedChatRepository(clock: clock);
      final Conversation alpha = await gated.createConversation(title: 'Alpha');
      await gated.addMessage(
        conversationId: alpha.id,
        role: ChatRole.user,
        content: 'alpha msg',
      );
      clock.advance(const Duration(minutes: 1));
      await gated.createConversation(title: 'Beta');
      chats = gated;
      gated.gatedId = alpha.id;
      gated.gate = Completer<void>();

      await pumpChatNoHook(tester);
      // The most recent conversation (Beta, empty) is open.
      expect(find.text('No messages yet. Say hello!'), findsOneWidget);

      // Pick Alpha in history (its title became the first message): the
      // lookup hangs.
      await tester.tap(find.byKey(const Key('chatHistoryButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('alpha msg'));
      await tester.pumpAndSettle();

      // While Alpha is still loading, the user creates a new chat.
      await tester.tap(find.byKey(const Key('chatNewChatButton')));
      await tester.pumpAndSettle();
      expect(find.text('No messages yet. Say hello!'), findsOneWidget);

      // The slow Alpha switch finishes last and must be ignored (A-35).
      gated.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.text('No messages yet. Say hello!'), findsOneWidget);
      expect(find.text('alpha msg'), findsNothing);
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
      await tester.pump();
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
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pumpAndSettle();

      expect(find.text(const OfflineFailure().userMessage), findsOneWidget);
      expect(llm.streamCalls, isEmpty);
      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      expect(input.controller?.text, 'hello offline');
    });

    testWidgets('not configured reply offers Settings and opens it', (
      WidgetTester tester,
    ) async {
      settings.configured = false;
      await pumpChat(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pumpAndSettle();

      expect(
        find.text(const NotConfiguredFailure().userMessage),
        findsOneWidget,
      );
      // NotConfigured offers Settings instead of Retry (T-19).
      expect(find.byKey(const Key('chatRetryButton')), findsNothing);
      // The typed text is kept for after the user configures the app.
      final TextField input = tester.widget(find.byKey(const Key('chatInput')));
      expect(input.controller?.text, 'hello');

      await tester.tap(find.byKey(const Key('chatSettingsButton')));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
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

    testWidgets('composer floats over the chat list', (
      WidgetTester tester,
    ) async {
      final Conversation conversation = await chats.createConversation();
      await chats.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'hello',
      );
      await pumpChatNoHook(tester);

      final Rect list = tester.getRect(find.byKey(const Key('chatList')));
      final Rect input = tester.getRect(find.byKey(const Key('chatInput')));
      // The list reaches below the field: chat content can scroll behind it.
      expect(list.bottom, greaterThan(input.bottom));
    });
  });

  group('ChatScreen voice input (22.1)', () {
    String inputText(WidgetTester tester) {
      return tester
          .widget<TextField>(find.byKey(const Key('chatInput')))
          .controller!
          .text;
    }

    testWidgets('mic inserts partial and final text', (
      WidgetTester tester,
    ) async {
      await sttSettings.setEngine(SttEngineKind.moonshine);
      await pumpChatNoHook(tester);
      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();

      expect(tts.stopCalls, 1);
      expect(stt.calls, contains('start'));
      expect(find.byKey(const Key('chatListeningIndicator')), findsOneWidget);
      expect(find.byKey(const Key('chatSpectrum')), findsOneWidget);
      stt.emitSpectrum(<double>[0.2, 0.8, 0.4]);
      await tester.pump();

      stt.emitPartial('hello');
      await tester.pump();
      expect(inputText(tester), 'hello');

      stt.emitFinal('hello world');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(inputText(tester), 'hello world');
      expect(find.byKey(const Key('chatMicBusy')), findsOneWidget);
      expect(find.byKey(const Key('chatMicButton')), findsNothing);
      expect(find.byKey(const Key('chatListeningIndicator')), findsNothing);
      expect(find.byKey(const Key('chatProcessingIndicator')), findsOneWidget);

      stt.emitStopped();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.byKey(const Key('chatSendButton')), findsOneWidget);
      expect(find.byKey(const Key('chatMicButton')), findsNothing);
      expect(find.byKey(const Key('chatProcessingIndicator')), findsNothing);
    });

    testWidgets('mic stays hidden until the required model is ready', (
      WidgetTester tester,
    ) async {
      models.ready = false;
      await pumpChatNoHook(tester);

      expect(find.byKey(const Key('chatMicButton')), findsNothing);
      expect(find.byKey(const Key('chatSendButton')), findsNothing);
      expect(find.byKey(const Key('chatTrailingAction')), findsNothing);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chatSendButton')), findsOneWidget);
      expect(find.byKey(const Key('chatMicButton')), findsNothing);

      models.setReady(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chatMicButton')), findsNothing);

      await tester.enterText(find.byKey(const Key('chatInput')), '');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chatMicButton')), findsOneWidget);
      expect(find.byKey(const Key('chatSendButton')), findsNothing);
    });

    testWidgets('send matches the mic footprint', (WidgetTester tester) async {
      await pumpChatNoHook(tester);
      final Size mic = tester.getSize(find.byKey(const Key('chatMicButton')));
      expect(mic, const Size(composerActionSize, composerActionSize));

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
      await tester.pumpAndSettle();
      final Size send = tester.getSize(find.byKey(const Key('chatSendButton')));
      expect(send, mic);
    });

    testWidgets('typing swaps the mic for send and clearing swaps it back', (
      WidgetTester tester,
    ) async {
      await pumpChatNoHook(tester);
      expect(find.byKey(const Key('chatTrailingAction')), findsOneWidget);
      expect(find.byKey(const Key('chatMicButton')), findsOneWidget);
      expect(find.byKey(const Key('chatSendButton')), findsNothing);

      await tester.enterText(find.byKey(const Key('chatInput')), 'I said');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chatTrailingAction')), findsOneWidget);
      expect(find.byKey(const Key('chatSendButton')), findsOneWidget);
      expect(find.byKey(const Key('chatMicButton')), findsNothing);

      await tester.enterText(find.byKey(const Key('chatInput')), '');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chatTrailingAction')), findsOneWidget);
      expect(find.byKey(const Key('chatMicButton')), findsOneWidget);
      expect(find.byKey(const Key('chatSendButton')), findsNothing);
    });

    testWidgets('shows processing while the engine is starting', (
      WidgetTester tester,
    ) async {
      stt.startEmitsStarted = false;
      await pumpChatNoHook(tester);

      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();
      expect(find.byKey(const Key('chatProcessingIndicator')), findsOneWidget);

      stt.emitStarted();
      await tester.pump();
      expect(find.byTooltip('Stop voice input'), findsOneWidget);
      expect(find.byKey(const Key('chatProcessingIndicator')), findsNothing);
    });

    testWidgets('mic button grows with the input level', (
      WidgetTester tester,
    ) async {
      double scale() => tester
          .widget<Transform>(find.byKey(const Key('chatMicScale')))
          .transform
          .getMaxScaleOnAxis();

      await pumpChatNoHook(tester);
      expect(scale(), 1);

      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();
      stt.emitLevel(0.9);
      await tester.pump();
      expect(scale(), greaterThan(1.2));

      stt.emitStopped();
      await tester.pump();
      expect(scale(), 1);
    });

    testWidgets('mic size follows intermediate levels', (
      WidgetTester tester,
    ) async {
      double scale() => tester
          .widget<Transform>(find.byKey(const Key('chatMicScale')))
          .transform
          .getMaxScaleOnAxis();

      await pumpChatNoHook(tester);
      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();

      stt.emitLevel(0.25);
      await tester.pump();
      final double soft = scale();

      stt.emitLevel(0.8);
      await tester.pump();
      final double loud = scale();

      expect(soft, greaterThan(1.05));
      expect(loud, greaterThan(soft + 0.1));
    });

    testWidgets('mic keeps a soft pulse while listening', (
      WidgetTester tester,
    ) async {
      double scale() => tester
          .widget<Transform>(find.byKey(const Key('chatMicScale')))
          .transform
          .getMaxScaleOnAxis();

      await pumpChatNoHook(tester);
      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();
      stt.emitLevel(0.5);
      await tester.pump();

      final List<double> samples = <double>[];
      for (int i = 0; i < 8; i++) {
        samples.add(scale());
        await tester.pump(const Duration(milliseconds: 100));
      }
      final double low = samples.reduce((double a, double b) => a < b ? a : b);
      final double high = samples.reduce((double a, double b) => a > b ? a : b);
      expect(high - low, greaterThan(0.015));
    });

    testWidgets('auto-send sends the final text once', (
      WidgetTester tester,
    ) async {
      await sttSettings.setAutoSend(true);
      llm.streamHandler = (_) =>
          Stream.fromIterable([const TextDelta('reply'), const StreamDone()]);
      await pumpChatNoHook(tester);

      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();
      stt.emitFinal('hello there');
      await tester.pumpAndSettle();

      expect(find.text('hello there'), findsWidgets);
      expect(inputText(tester), isEmpty);
      expect(llm.streamCalls, hasLength(1));
    });

    testWidgets('a recognition failure shows a clear message', (
      WidgetTester tester,
    ) async {
      await pumpChatNoHook(tester);
      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();

      stt.emitFailure(const SttUnavailableFailure());
      await tester.pumpAndSettle();

      expect(
        find.text(const SttUnavailableFailure().userMessage),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chatMicButton')), findsOneWidget);
    });

    testWidgets('tapping the mic again stops listening', (
      WidgetTester tester,
    ) async {
      await pumpChatNoHook(tester);
      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('chatMicButton')));
      await tester.pump();

      expect(stt.calls, contains('stop'));
      expect(find.byKey(const Key('chatMicBusy')), findsOneWidget);
    });
  });
}
