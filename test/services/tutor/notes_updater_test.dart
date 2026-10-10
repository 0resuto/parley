import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/data/db/database.dart' hide Conversation;
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/tutor/notes_updater.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';

class FakeNotesSettings implements SettingsRepository {
  FakeNotesSettings({this.configured = true});

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

class FakeNotesLlm implements LlmClient {
  FakeNotesLlm(this.script);

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

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late ChatRepository chats;
  late MemoryDocumentStore documents;
  late FakeNotesSettings settings;
  late FakeConnectivityService connectivity;
  late FakeNotesLlm llm;
  final DateTime initial = DateTime.utc(2026, 5, 1, 12);

  NotesUpdater makeUpdater() {
    return NotesUpdater(
      chats: chats,
      documents: documents,
      llm: llm,
      clock: clock,
      connectivity: connectivity,
      settings: settings,
    );
  }

  Future<int> makeConversationWith(List<(ChatRole, String)> messages) async {
    final Conversation conversation = await chats.createConversation();
    for (final (ChatRole role, String content) in messages) {
      await chats.addMessage(
        conversationId: conversation.id,
        role: role,
        content: content,
      );
    }
    return conversation.id;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    chats = ChatRepository(db, clock: clock);
    documents = MemoryDocumentStore(clock: clock);
    settings = FakeNotesSettings();
    connectivity = FakeConnectivityService();
    llm = FakeNotesLlm([validNotes()]);
  });

  tearDown(() async {
    await connectivity.dispose();
    await db.close();
  });

  group('NotesUpdater 7.3', () {
    test('valid result is written and messages marked', () async {
      final int id = await makeConversationWith([
        (ChatRole.user, 'I like football'),
        (ChatRole.assistant, 'Football is great, tell me more'),
      ]);
      await documents.write(DocumentKind.notes, '# Learner notes\nold');

      llm = FakeNotesLlm([validNotes()]);
      final bool wrote = await makeUpdater().updateOnce();

      expect(wrote, isTrue);
      expect(await documents.read(DocumentKind.notes), validNotes());
      expect(await chats.unprocessedUserCount(), 0);
      final List<ChatMessage> messages = await chats.listMessages(id);
      expect(messages.every((m) => m.processedByNotes), isTrue);
      expect(llm.calls, hasLength(1));
    });

    test('invalid result is discarded and messages stay unprocessed', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi there'),
      ]);
      await documents.write(DocumentKind.notes, 'before');

      llm = FakeNotesLlm(['just some prose without headings']);
      final bool wrote = await makeUpdater().updateOnce();

      expect(wrote, isFalse);
      expect(llm.calls, hasLength(1));
      expect(await documents.read(DocumentKind.notes), 'before');
      expect(await chats.unprocessedUserCount(), 1);
    });

    test('code fences are invalid and discarded without retry', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);
      llm = FakeNotesLlm(['${validNotes()}\n```fence```']);

      expect(await makeUpdater().updateOnce(), isFalse);
      expect(llm.calls, hasLength(1));
      expect(await chats.unprocessedUserCount(), 1);
    });

    test('empty result is discarded without retry', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);
      llm = FakeNotesLlm(['   ']);

      expect(await makeUpdater().updateOnce(), isFalse);
      expect(llm.calls, hasLength(1));
      expect(await chats.unprocessedUserCount(), 1);
    });

    test('too-long result triggers one shortening retry', () async {
      await makeConversationWith([
        (ChatRole.user, 'I like football'),
        (ChatRole.assistant, 'Nice, tell me more'),
      ]);
      final String tooLong = '${validNotes()}\n${'x' * notesLimit}';
      expect(tooLong.length > notesLimit, isTrue);
      final String fixed = validNotes();
      llm = FakeNotesLlm([tooLong, fixed]);

      final bool wrote = await makeUpdater().updateOnce();

      expect(wrote, isTrue);
      expect(llm.calls, hasLength(2));
      final List<LlmMessage> retry = llm.calls[1];
      expect(retry.last.role, LlmRole.user);
      expect(
        retry.last.content,
        'Too long. Shorten to under $notesRetryLength characters.',
      );
      expect(notesRetryLength, 4800);
      expect(await documents.read(DocumentKind.notes), fixed);
      expect(await chats.unprocessedUserCount(), 0);
    });

    test('too-long then still invalid is discarded', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);
      final String tooLong = '${validNotes()}\n${'x' * notesLimit}';
      llm = FakeNotesLlm([tooLong, 'still bad, no headings']);

      final bool wrote = await makeUpdater().updateOnce();

      expect(wrote, isFalse);
      expect(llm.calls, hasLength(2));
      expect(await documents.read(DocumentKind.notes), '');
      expect(await chats.unprocessedUserCount(), 1);
    });

    test('date and target length are in the system prompt', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);

      await makeUpdater().updateOnce();

      expect(llm.calls, hasLength(1));
      final String system = llm.calls.single.first.content;
      expect(system, contains('Last reassessed: 2026-05-01'));
      expect(system, contains('under $notesTargetLength characters'));
      expect(notesTargetLength, 6400);
    });

    test('prompt contains the exact onboarding rules', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);

      await makeUpdater().updateOnce();

      final String system = llm.calls.single.first.content;
      expect(system, contains('Status: not assessed yet'));
      expect(system, contains('at least 6 substantive learner messages'));
      expect(system, contains('remove the status line'));
      expect(system, contains('Return ONLY the full updated document'));
      expect(system, contains('"## Language profile"'));
      expect(system, contains('**Confidence:** low | medium | high'));
    });

    test('user message carries current notes and excerpt', () async {
      await makeConversationWith([
        (ChatRole.user, 'I like football'),
        (ChatRole.assistant, 'Great, tell me more'),
      ]);
      await documents.write(DocumentKind.notes, 'current notes body');

      await makeUpdater().updateOnce();

      final String user = llm.calls.single.last.content;
      expect(user, contains('CURRENT NOTES:\ncurrent notes body'));
      expect(user, contains('NEW EXCERPT:'));
      expect(user, contains('user: I like football'));
      expect(user, contains('assistant: Great, tell me more'));
    });

    test('takes at most 40 messages per call', () async {
      final Conversation conversation = await chats.createConversation();
      for (int i = 0; i < 45; i++) {
        await chats.addMessage(
          conversationId: conversation.id,
          role: ChatRole.user,
          content: 'message $i',
        );
      }

      final bool wrote = await makeUpdater().updateOnce();

      expect(wrote, isTrue);
      expect(llm.calls, hasLength(1));
      final String user = llm.calls.single.last.content;
      expect('user: '.allMatches(user).length, notesMaxMessagesPerCall);
      expect(user, contains('message 0'));
      expect(user, isNot(contains('message 44')));
      expect(await chats.unprocessedUserCount(), 5);
    });

    test('event messages are excluded from the excerpt', () async {
      final int id = await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);
      await chats.addMessage(
        conversationId: id,
        role: ChatRole.event,
        content: '{"type":"rules_updated"}',
      );

      await makeUpdater().updateOnce();

      final String user = llm.calls.single.last.content;
      expect(user, isNot(contains('rules_updated')));
      expect(user, contains('user: hello'));
    });

    test('no unprocessed messages means no LLM call', () async {
      final bool wrote = await makeUpdater().updateOnce();

      expect(wrote, isFalse);
      expect(llm.calls, isEmpty);
    });

    test('offline skips without an LLM call', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);
      connectivity.setOnline(false);

      expect(await makeUpdater().updateOnce(), isFalse);
      expect(llm.calls, isEmpty);
      expect(await chats.unprocessedUserCount(), 1);
    });

    test('not configured skips without an LLM call', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);
      settings.configured = false;

      expect(await makeUpdater().updateOnce(), isFalse);
      expect(llm.calls, isEmpty);
    });

    test('LLM failure never throws and marks nothing', () async {
      await makeConversationWith([
        (ChatRole.user, 'hello'),
        (ChatRole.assistant, 'hi'),
      ]);
      llm = FakeNotesLlm([const ServerFailure()]);

      expect(await makeUpdater().updateOnce(), isFalse);
      expect(await chats.unprocessedUserCount(), 1);
      expect(await documents.read(DocumentKind.notes), '');
    });

    test('validation helper covers the four rules', () {
      expect(isValidNotesDocument(''), isFalse);
      expect(isValidNotesDocument('   '), isFalse);
      expect(isValidNotesDocument('plain text without headings'), isFalse);
      expect(isValidNotesDocument('${validNotes()}\n```'), isFalse);
      expect(
        isValidNotesDocument('${validNotes()}\n${'x' * notesLimit}'),
        isFalse,
      );
      expect(isValidNotesDocument(validNotes()), isTrue);
      expect(
        isValidNotesDocument(
          validNotes().replaceFirst('## About the user', '## Missing'),
        ),
        isFalse,
      );
    });

    test('connectivity service type is accepted', () {
      ConnectivityService service = FakeConnectivityService();
      expect(service, isA<ConnectivityService>());
    });
  });
}
