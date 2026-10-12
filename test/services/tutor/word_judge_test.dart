import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/data/db/database.dart' hide Conversation, Unit;
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';
import 'package:parley/services/tutor/word_judge.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';

class FakeJudgeSettings implements SettingsRepository {
  @override
  String get meaningLanguage => 'ru';

  @override
  Future<void> setMeaningLanguage(String value) async {}

  FakeJudgeSettings({this.configured = true});

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

class FakeJudgeLlm implements LlmClient {
  FakeJudgeLlm(this.script);

  final List<Object> script;
  final List<List<LlmMessage>> calls = [];
  int _index = 0;

  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async {
    calls.add(messages);
    if (_index >= script.length) {
      throw StateError('script exhausted');
    }
    final Object next = script[_index++];
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

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UnitRepository units;
  late ChatRepository chats;
  late ReviewService reviews;
  late FakeJudgeSettings settings;
  late FakeConnectivityService connectivity;
  late FakeJudgeLlm llm;
  final DateTime initial = DateTime.utc(2026, 5, 1, 12);

  WordJudge makeJudge() {
    return WordJudge(
      db: db,
      chats: chats,
      units: units,
      llm: llm,
      connectivity: connectivity,
      settings: settings,
      reviews: reviews,
      clock: clock,
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

  Future<List<Review>> allReviews() => db.select(db.reviews).get();

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    units = UnitRepository(db, clock: clock);
    chats = ChatRepository(db, clock: clock);
    reviews = ReviewService(db, units: units, clock: clock);
    settings = FakeJudgeSettings();
    connectivity = FakeConnectivityService();
    llm = FakeJudgeLlm(['{"ratings":[]}']);
  });

  tearDown(() async {
    await connectivity.dispose();
    await db.close();
  });

  group('WordJudge 7.1', () {
    test('no candidates means no LLM call', () async {
      final int id = await makeConversationWith([
        (ChatRole.user, 'Hello there'),
        (ChatRole.assistant, 'Hi, how are you?'),
      ]);

      await makeJudge().judgeConversation(id);

      expect(llm.calls, isEmpty);
      expect(await allReviews(), isEmpty);
    });

    test('ratings are applied with source chat', () async {
      final Unit cow = await units.add(text: 'cow');
      final Unit barn = await units.add(text: 'barn');
      final int id = await makeConversationWith([
        (ChatRole.user, 'I saw a cow near the barn'),
        (ChatRole.assistant, 'The cow in the barn sounds lovely'),
      ]);
      llm = FakeJudgeLlm([
        '{"ratings":[{"text":"cow","rating":"good","reason":"used correctly"},'
            '{"text":"barn","rating":"easy","reason":"effortless"}]}',
      ]);

      await makeJudge().judgeConversation(id);

      expect(llm.calls, hasLength(1));
      final List<LlmMessage> request = llm.calls.single;
      expect(request.first.role, LlmRole.system);
      expect(request.first.content, contains('Output ONLY JSON'));
      expect(request.last.content, contains('cow'));
      expect(request.last.content, contains('barn'));
      expect(request.last.content, contains('user:'));
      expect(request.last.content, contains('assistant:'));

      final List<Review> rows = await allReviews();
      expect(rows, hasLength(2));
      final Map<int, Review> byUnit = {for (final r in rows) r.unitId: r};
      expect(byUnit[cow.id]!.source, 'chat');
      expect(byUnit[cow.id]!.rating, Rating.good.value);
      expect(byUnit[barn.id]!.source, 'chat');
      expect(byUnit[barn.id]!.rating, Rating.easy.value);
      expect((await units.getById(cow.id))!.lastReview, isNotNull);
      expect((await units.getById(barn.id))!.lastReview, isNotNull);
    });

    test('unit with a review in the last 30 minutes is skipped', () async {
      final Unit cow = await units.add(text: 'cow');
      final Unit barn = await units.add(text: 'barn');
      await reviews.rate(cow.id, Rating.good, ReviewSource.card);
      clock.advance(const Duration(minutes: 10));
      final int id = await makeConversationWith([
        (ChatRole.user, 'The cow is in the barn'),
        (ChatRole.assistant, 'Yes, the cow and the barn'),
      ]);
      llm = FakeJudgeLlm([
        '{"ratings":[{"text":"cow","rating":"easy","reason":"ok"},'
            '{"text":"barn","rating":"good","reason":"ok"}]}',
        '{"ratings":[{"text":"cow","rating":"easy","reason":"ok"},'
            '{"text":"barn","rating":"good","reason":"ok"}]}',
      ]);

      await makeJudge().judgeConversation(id);

      List<Review> rows = await allReviews();
      expect(rows, hasLength(2));
      expect(rows.where((r) => r.unitId == cow.id), hasLength(1));
      expect(rows.where((r) => r.unitId == barn.id), hasLength(1));

      clock.advance(const Duration(minutes: 31));
      await makeJudge().judgeConversation(id);

      rows = await allReviews();
      expect(rows.where((r) => r.unitId == cow.id), hasLength(2));
      expect(rows.where((r) => r.unitId == barn.id), hasLength(2));
    });

    test('Known units are ignored and never sent as WORDS', () async {
      final Unit cow = await units.add(text: 'cow');
      await units.setKnown(cow.id, true);
      final Unit barn = await units.add(text: 'barn');
      final int id = await makeConversationWith([
        (ChatRole.user, 'The cow is near the barn'),
        (ChatRole.assistant, 'Nice cow and barn'),
      ]);
      llm = FakeJudgeLlm([
        '{"ratings":[{"text":"cow","rating":"good","reason":"ok"},'
            '{"text":"barn","rating":"good","reason":"ok"}]}',
      ]);

      await makeJudge().judgeConversation(id);

      expect(llm.calls, hasLength(1));
      // Known unit is not a candidate, so WORDS has only the other unit.
      expect(llm.calls.single.last.content, contains('barn'));
      expect(llm.calls.single.last.content, isNot(contains('WORDS: cow')));

      final List<Review> rows = await allReviews();
      expect(rows, hasLength(1));
      expect(rows.single.unitId, barn.id);
      expect(rows.single.source, 'chat');
    });

    test('only Known units means no LLM call', () async {
      final Unit cow = await units.add(text: 'cow');
      await units.setKnown(cow.id, true);
      final int id = await makeConversationWith([
        (ChatRole.user, 'I like the cow'),
        (ChatRole.assistant, 'The cow is nice'),
      ]);

      await makeJudge().judgeConversation(id);

      expect(llm.calls, isEmpty);
      expect(await allReviews(), isEmpty);
    });

    test('invalid JSON applies nothing and never throws', () async {
      await units.add(text: 'cow');
      final int id = await makeConversationWith([
        (ChatRole.user, 'I saw a cow'),
        (ChatRole.assistant, 'Cows are great, the cow is nice'),
      ]);
      llm = FakeJudgeLlm(['not json at all', 'still not json']);

      await makeJudge().judgeConversation(id);

      expect(llm.calls, hasLength(2));
      expect(await allReviews(), isEmpty);
    });

    test('offline skips without an LLM call', () async {
      await units.add(text: 'cow');
      final int id = await makeConversationWith([
        (ChatRole.user, 'I saw a cow'),
        (ChatRole.assistant, 'The cow is nice'),
      ]);
      connectivity.setOnline(false);

      await makeJudge().judgeConversation(id);

      expect(llm.calls, isEmpty);
      expect(await allReviews(), isEmpty);
    });

    test('not configured skips without an LLM call', () async {
      await units.add(text: 'cow');
      final int id = await makeConversationWith([
        (ChatRole.user, 'I saw a cow'),
        (ChatRole.assistant, 'The cow is nice'),
      ]);
      settings.configured = false;

      await makeJudge().judgeConversation(id);

      expect(llm.calls, isEmpty);
      expect(await allReviews(), isEmpty);
    });

    test('only the last 4 messages are considered', () async {
      await units.add(text: 'cow');
      final int id = await makeConversationWith([
        (ChatRole.user, 'I saw a cow'),
        (ChatRole.user, 'hello one'),
        (ChatRole.assistant, 'hello two'),
        (ChatRole.user, 'hello three'),
        (ChatRole.assistant, 'hello four'),
      ]);

      await makeJudge().judgeConversation(id);

      expect(llm.calls, isEmpty);
      expect(await allReviews(), isEmpty);
    });

    test('unknown rating words are skipped', () async {
      final Unit barn = await units.add(text: 'barn');
      final int id = await makeConversationWith([
        (ChatRole.user, 'The barn is big'),
        (ChatRole.assistant, 'Yes, the barn'),
      ]);
      llm = FakeJudgeLlm([
        '{"ratings":[{"text":"zebra","rating":"good","reason":"ok"},'
            '{"text":"barn","rating":"hard","reason":"with help"}]}',
      ]);

      await makeJudge().judgeConversation(id);

      final List<Review> rows = await allReviews();
      expect(rows, hasLength(1));
      expect(rows.single.unitId, barn.id);
      expect(rows.single.rating, Rating.hard.value);
    });

    test('prompt builder uses the verbatim system prompt', () async {
      final Conversation conversation = await chats.createConversation();
      final List<ChatMessage> window = [
        ChatMessage(
          id: 1,
          conversationId: conversation.id,
          role: ChatRole.user,
          content: 'hi',
          createdAt: initial,
          processedByNotes: false,
        ),
      ];
      final List<LlmMessage> messages = buildWordJudgeMessages(
        words: ['cow'],
        window: window,
      );
      expect(messages.first.role, LlmRole.system);
      expect(messages.first.content, wordJudgeSystemPrompt);
      expect(messages.last.content, 'WORDS: cow\nMESSAGES:\nuser: hi');
    });
  });
}
