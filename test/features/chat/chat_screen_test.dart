import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/core/theme.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/chat_screen.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
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

    testWidgets('New chat after a message starts a fresh conversation', (
      WidgetTester tester,
    ) async {
      llm.streamHandler = (_) =>
          Stream.fromIterable([const TextDelta('reply'), const StreamDone()]);
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
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

    testWidgets('typing during a stream is not wiped by send', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'first');
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

    testWidgets('streaming text keeps the list scrolled to the bottom', (
      WidgetTester tester,
    ) async {
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      llm.streamHandler = (_) => events.stream;
      await pumpChatNoHook(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hi');
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

    testWidgets('not configured reply offers Settings and opens it', (
      WidgetTester tester,
    ) async {
      settings.configured = false;
      await pumpChat(tester);

      await tester.enterText(find.byKey(const Key('chatInput')), 'hello');
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
  });
}
