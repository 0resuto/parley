import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/tutor/notes_updater.dart';
import 'package:parley/services/tutor/tutor_scheduler.dart';

import '../../helpers/fake_chat_repository.dart';
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';

class FakeSchedulerSettings implements SettingsRepository {
  @override
  String get meaningLanguage => 'ru';

  @override
  Future<void> setMeaningLanguage(String value) async {}

  FakeSchedulerSettings({this.configured = true});

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

class FakeSchedulerLlm implements LlmClient {
  FakeSchedulerLlm(this.script);

  final List<Object> script;
  final List<List<LlmMessage>> calls = [];
  int _index = 0;

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    calls.add(messages);
    final Object next = _index < script.length ? script[_index++] : script.last;
    if (next is String) {
      return next;
    }
    if (next is AppFailure) {
      throw next;
    }
    throw StateError('Bad script entry: $next');
  }

  @override
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  }) {
    throw UnimplementedError();
  }
}

String validNotes({String date = '2026-05-01'}) {
  return '# Learner notes\n'
      '\n'
      '## Language profile\n'
      '**Overall:** The learner chats simply and clearly.\n'
      '**Vocabulary:** Basic everyday words.\n'
      '**Grammar:** Simple present, some errors.\n'
      '**Fluency and expression:** Short sentences.\n'
      '**Comprehension:** Understands simple replies.\n'
      '**Strengths:** Willing to try.\n'
      '**Weak spots:** Articles.\n'
      '**Confidence:** medium\n'
      'Last reassessed: $date\n'
      '\n'
      '## About the user\n'
      '- likes football\n'
      '\n'
      '## Learning observations\n'
      '- confuses a and the\n'
      '\n'
      '## Ongoing threads\n'
      '- weekend plans\n';
}

/// Controllable [NotesUpdater] for mutex / failure tests.
class ScriptNotesUpdater extends NotesUpdater {
  ScriptNotesUpdater({
    required super.chats,
    required super.documents,
    required super.llm,
    required super.clock,
    required super.connectivity,
    required super.settings,
    required this.script,
    this.blockFirst = false,
  });

  final List<Object> script;
  final bool blockFirst;
  final Completer<void> gate = Completer<void>();
  int calls = 0;
  int _index = 0;

  @override
  Future<bool> updateOnce() async {
    calls++;
    if (blockFirst && calls == 1) {
      await gate.future;
    }
    if (_index >= script.length) {
      final Object last = script.last;
      if (last is bool) {
        return last;
      }
      throw last;
    }
    final Object next = script[_index++];
    if (next is bool) {
      return next;
    }
    throw next;
  }
}

void main() {
  late FakeClock clock;
  late FakeChatRepository chats;
  late MemoryDocumentStore documents;
  late FakeSchedulerSettings settings;
  late FakeConnectivityService connectivity;
  late FakeSchedulerLlm llm;
  final DateTime initial = DateTime.utc(2026, 5, 1, 12);

  NotesUpdater makeNotes() {
    return NotesUpdater(
      chats: chats,
      documents: documents,
      llm: llm,
      clock: clock,
      connectivity: connectivity,
      settings: settings,
    );
  }

  TutorScheduler makeScheduler({NotesUpdater? notes}) {
    return TutorScheduler(
      chats: chats,
      notes: notes ?? makeNotes(),
      connectivity: connectivity,
    );
  }

  Future<void> addUserMessages(int count) async {
    final Conversation conversation = await chats.createConversation();
    for (int i = 0; i < count; i++) {
      await chats.addMessage(
        conversationId: conversation.id,
        role: ChatRole.user,
        content: 'message $i',
      );
    }
  }

  setUp(() {
    clock = FakeClock(initial);
    chats = FakeChatRepository(clock: clock);
    documents = MemoryDocumentStore();
    settings = FakeSchedulerSettings();
    connectivity = FakeConnectivityService();
    llm = FakeSchedulerLlm([validNotes()]);
  });

  tearDown(() async {
    await connectivity.dispose();
  });

  group('TutorScheduler 7.4', () {
    test('after-reply below 8 does nothing', () async {
      await addUserMessages(7);

      await makeScheduler().onAssistantReplyDone();

      expect(llm.calls, isEmpty);
      expect(await chats.unprocessedUserCount(), 7);
    });

    test('after-reply at 8 runs the updater', () async {
      await addUserMessages(8);

      await makeScheduler().onAssistantReplyDone();

      expect(llm.calls, hasLength(1));
      expect(await chats.unprocessedUserCount(), 0);
    });

    test('leave below 2 does nothing, at 2 runs', () async {
      await addUserMessages(1);

      await makeScheduler().onConversationLeft();
      expect(llm.calls, isEmpty);

      final Conversation extra = await chats.createConversation();
      await chats.addMessage(
        conversationId: extra.id,
        role: ChatRole.user,
        content: 'second',
      );

      await makeScheduler().onConversationLeft();

      expect(llm.calls, hasLength(1));
    });

    test('new-chat below 2 does nothing, at 2 runs', () async {
      await addUserMessages(1);

      await makeScheduler().onNewConversation();
      expect(llm.calls, isEmpty);

      final Conversation extra = await chats.createConversation();
      await chats.addMessage(
        conversationId: extra.id,
        role: ChatRole.user,
        content: 'second',
      );

      await makeScheduler().onNewConversation();

      expect(llm.calls, hasLength(1));
    });

    test('pause with nothing does no LLM call, with 1 runs', () async {
      await makeScheduler().onAppPaused();
      expect(llm.calls, isEmpty);

      await addUserMessages(1);

      await makeScheduler().onAppPaused();

      expect(llm.calls, hasLength(1));
      expect(await chats.unprocessedUserCount(), 0);
    });

    test('offline skips without an LLM call', () async {
      await addUserMessages(8);
      connectivity.setOnline(false);

      final TutorScheduler scheduler = makeScheduler();
      await scheduler.onAssistantReplyDone();
      await scheduler.onAppPaused();
      await scheduler.onConversationLeft();
      await scheduler.onNewConversation();
      await scheduler.run();

      expect(llm.calls, isEmpty);
      expect(await chats.unprocessedUserCount(), 8);
    });

    test('run takes up to 3 chunks of 40', () async {
      await addUserMessages(200);
      llm = FakeSchedulerLlm([
        validNotes(),
        validNotes(),
        validNotes(),
        validNotes(),
      ]);

      await makeScheduler().run();

      expect(llm.calls, hasLength(3));
      expect(notesMaxCallsPerRun, 3);
      expect(notesMaxMessagesPerCall, 40);
      // 200 - 3*40 = 80 left unprocessed.
      expect(await chats.unprocessedUserCount(), 80);
    });

    test('no parallel runs: second run returns immediately', () async {
      final ScriptNotesUpdater notes = ScriptNotesUpdater(
        chats: chats,
        documents: documents,
        llm: llm,
        clock: clock,
        connectivity: connectivity,
        settings: settings,
        script: [false],
        blockFirst: true,
      );
      final TutorScheduler scheduler = makeScheduler(notes: notes);

      final Future<void> first = scheduler.run();
      // Wait until the first run entered updateOnce.
      for (int i = 0; i < 100 && notes.calls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(notes.calls, 1);
      expect(scheduler.isRunning, isTrue);

      // Second run while the first is blocked must not call updateOnce.
      await scheduler.run();
      expect(notes.calls, 1);

      notes.gate.complete();
      await first;
      expect(scheduler.isRunning, isFalse);
      expect(notes.calls, 1);
    });

    test('failure does not break the next run', () async {
      final ScriptNotesUpdater notes = ScriptNotesUpdater(
        chats: chats,
        documents: documents,
        llm: llm,
        clock: clock,
        connectivity: connectivity,
        settings: settings,
        script: [StateError('boom'), false],
      );
      final TutorScheduler scheduler = makeScheduler(notes: notes);

      // First run throws inside updateOnce; run() must not throw
      // and must reset the mutex.
      await scheduler.run();
      expect(notes.calls, 1);
      expect(scheduler.isRunning, isFalse);

      // Next run succeeds (returns false to stop after one chunk).
      await scheduler.run();
      expect(notes.calls, 2);
      expect(scheduler.isRunning, isFalse);
    });

    test('LLM failure never throws and unblocks the next run', () async {
      await addUserMessages(8);
      llm = FakeSchedulerLlm([const ServerFailure()]);

      final TutorScheduler scheduler = makeScheduler();
      await scheduler.onAssistantReplyDone();
      expect(llm.calls, hasLength(1));
      expect(await chats.unprocessedUserCount(), 8);
      expect(scheduler.isRunning, isFalse);

      llm = FakeSchedulerLlm([validNotes()]);
      await makeScheduler().onAssistantReplyDone();
      expect(await chats.unprocessedUserCount(), 0);
    });

    test('connectivity service type is accepted', () {
      ConnectivityService service = FakeConnectivityService();
      expect(service, isA<ConnectivityService>());
    });
  });
}
