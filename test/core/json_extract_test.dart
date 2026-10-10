import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/core/json_extract.dart';
import 'package:parley/services/llm/llm_client.dart';

class FakeLlmClient implements LlmClient {
  FakeLlmClient(this.script);

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

List<LlmMessage> baseMessages() {
  return const [
    LlmMessage(role: LlmRole.system, content: 'sys'),
    LlmMessage(role: LlmRole.user, content: 'hi'),
  ];
}

void main() {
  group('extractJson', () {
    test('plain object', () {
      final Map<String, dynamic> result = extractJson(
        '{"lemma":"cow","translation_ru":"корова","pos":"noun"}',
      );
      expect(result['lemma'], 'cow');
    });

    test('fenced JSON with language tag', () {
      const String raw =
          '```json\n'
          '{"lemma":"cow","translation_ru":"корова","pos":"noun"}\n'
          '```';
      final Map<String, dynamic> result = extractJson(raw);
      expect(result['lemma'], 'cow');
      expect(result['pos'], 'noun');
    });

    test('fenced JSON without language tag', () {
      const String raw = '```\n{"a":1}\n```';
      expect(extractJson(raw)['a'], 1);
    });

    test('JSON surrounded by prose', () {
      const String raw =
          'Sure, here it is: {"lemma":"run","translation_ru":"бежать","pos":"verb"} hope that helps.';
      final Map<String, dynamic> result = extractJson(raw);
      expect(result['lemma'], 'run');
      expect(result['pos'], 'verb');
    });

    test('nested braces', () {
      const String raw = 'prefix {"a":{"b":1,"c":{"d":2}},"e":3} suffix';
      final Map<String, dynamic> result = extractJson(raw);
      expect(result['e'], 3);
      expect((result['a'] as Map)['c'], {'d': 2});
    });

    test('braces inside strings are ignored', () {
      const String raw = '{"text":"a } b { c","pos":"other"}';
      final Map<String, dynamic> result = extractJson(raw);
      expect(result['text'], 'a } b { c');
    });

    test('returns the first object when two are present', () {
      const String raw = '{"a":1} {"b":2}';
      expect(extractJson(raw), {'a': 1});
    });

    test('throws when there is no object', () {
      expect(
        () => extractJson('no braces here'),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('throws on unbalanced braces', () {
      expect(
        () => extractJson('{"a":1'),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('throws on invalid JSON content', () {
      expect(
        () => extractJson('{not json}'),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('throws on non-object JSON', () {
      expect(
        () => extractJson('[1, 2, 3]'),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });
  });

  group('validateTranslateJson', () {
    test('valid result', () {
      final TranslateResult result = validateTranslateJson({
        'lemma': 'cow',
        'translation_ru': 'корова',
        'pos': 'noun',
      });
      expect(result.lemma, 'cow');
      expect(result.translationRu, 'корова');
      expect(result.pos, TranslatePos.noun);
    });

    test('contextual translation is parsed when different', () {
      final TranslateResult result = validateTranslateJson({
        'lemma': 'bank',
        'translation_ru': 'банк',
        'translation_in_context': 'берег',
        'pos': 'noun',
      });
      expect(result.translationRu, 'банк');
      expect(result.translationInContext, 'берег');
    });

    test('missing or empty contextual translation falls back', () {
      final TranslateResult missing = validateTranslateJson({
        'lemma': 'cow',
        'translation_ru': 'корова',
        'pos': 'noun',
      });
      expect(missing.translationInContext, 'корова');

      final TranslateResult empty = validateTranslateJson({
        'lemma': 'cow',
        'translation_ru': 'корова',
        'translation_in_context': '   ',
        'pos': 'noun',
      });
      expect(empty.translationInContext, 'корова');
    });

    test('non-string contextual translation throws', () {
      expect(
        () => validateTranslateJson({
          'lemma': 'cow',
          'translation_ru': 'корова',
          'translation_in_context': 42,
          'pos': 'noun',
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('every pos enum value parses', () {
      const List<String> values = [
        'noun',
        'verb',
        'adj',
        'adv',
        'phrase',
        'other',
      ];
      for (final String value in values) {
        final TranslateResult result = validateTranslateJson({
          'lemma': 'x',
          'translation_ru': 'y',
          'pos': value,
        });
        expect(result.pos.value, value);
      }
    });

    test('missing keys throw', () {
      expect(
        () => validateTranslateJson({'lemma': 'x', 'pos': 'noun'}),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(
        () => validateTranslateJson({'translation_ru': 'y', 'pos': 'noun'}),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(
        () => validateTranslateJson({'lemma': 'x', 'translation_ru': 'y'}),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('empty lemma or translation throws', () {
      expect(
        () => validateTranslateJson({
          'lemma': '   ',
          'translation_ru': 'корова',
          'pos': 'noun',
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(
        () => validateTranslateJson({
          'lemma': 'cow',
          'translation_ru': '',
          'pos': 'noun',
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('invalid pos enum value throws', () {
      expect(
        () => validateTranslateJson({
          'lemma': 'cow',
          'translation_ru': 'корова',
          'pos': 'adjective',
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('non-string types throw', () {
      expect(
        () => validateTranslateJson({
          'lemma': 42,
          'translation_ru': 'корова',
          'pos': 'noun',
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });
  });

  group('validateWordJudgeJson', () {
    test('valid result with two ratings', () {
      final WordJudgeResult result = validateWordJudgeJson({
        'ratings': [
          {'text': 'cow', 'rating': 'good', 'reason': 'used correctly'},
          {'text': 'barn', 'rating': 'again', 'reason': 'asked meaning'},
        ],
      });
      expect(result.ratings, hasLength(2));
      expect(result.ratings[0].text, 'cow');
      expect(result.ratings[0].rating, JudgeRating.good);
      expect(result.ratings[1].rating, JudgeRating.again);
    });

    test('every rating enum value parses', () {
      for (final String value in ['again', 'hard', 'good', 'easy']) {
        final WordJudgeResult result = validateWordJudgeJson({
          'ratings': [
            {'text': 'w', 'rating': value, 'reason': 'r'},
          ],
        });
        expect(result.ratings.single.rating.value, value);
      }
    });

    test('empty ratings list is allowed', () {
      final WordJudgeResult result = validateWordJudgeJson({'ratings': []});
      expect(result.ratings, isEmpty);
    });

    test('ratings not a list throws', () {
      expect(
        () => validateWordJudgeJson({'ratings': 'nope'}),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(
        () => validateWordJudgeJson({}),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('invalid rating enum value throws', () {
      expect(
        () => validateWordJudgeJson({
          'ratings': [
            {'text': 'cow', 'rating': 'perfect', 'reason': 'r'},
          ],
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });

    test('missing text, rating or reason throws', () {
      expect(
        () => validateWordJudgeJson({
          'ratings': [
            {'rating': 'good', 'reason': 'r'},
          ],
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(
        () => validateWordJudgeJson({
          'ratings': [
            {'text': 'cow', 'reason': 'r'},
          ],
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(
        () => validateWordJudgeJson({
          'ratings': [
            {'text': 'cow', 'rating': 'good'},
          ],
        }),
        throwsA(isA<InvalidResponseFailure>()),
      );
    });
  });

  group('completeJson', () {
    test('success on first try makes one call', () async {
      final FakeLlmClient client = FakeLlmClient([
        '{"lemma":"cow","translation_ru":"корова","pos":"noun"}',
      ]);

      final TranslateResult result = await completeJson(
        client,
        baseMessages(),
        validateTranslateJson,
      );

      expect(result.lemma, 'cow');
      expect(client.calls, hasLength(1));
      expect(client.calls.single, hasLength(2));
    });

    test('invalid first reply retries once with the prompt line', () async {
      final FakeLlmClient client = FakeLlmClient([
        'not json at all',
        '{"lemma":"cow","translation_ru":"корова","pos":"noun"}',
      ]);

      final TranslateResult result = await completeJson(
        client,
        baseMessages(),
        validateTranslateJson,
      );

      expect(result.lemma, 'cow');
      expect(client.calls, hasLength(2));
      final List<LlmMessage> retry = client.calls[1];
      expect(retry, hasLength(3));
      expect(retry[0].content, 'sys');
      expect(retry[1].content, 'hi');
      expect(retry.last.role, LlmRole.user);
      expect(retry.last.content, 'Return ONLY the JSON object.');
    });

    test('validator failure also triggers one retry', () async {
      final FakeLlmClient client = FakeLlmClient([
        '{"lemma":"cow","translation_ru":"корова","pos":"bogus"}',
        '{"lemma":"cow","translation_ru":"корова","pos":"noun"}',
      ]);

      final TranslateResult result = await completeJson(
        client,
        baseMessages(),
        validateTranslateJson,
      );

      expect(result.pos, TranslatePos.noun);
      expect(client.calls, hasLength(2));
    });

    test('two bad replies throw InvalidResponse', () async {
      final FakeLlmClient client = FakeLlmClient([
        'garbage one',
        'garbage two',
      ]);

      await expectLater(
        completeJson(client, baseMessages(), validateTranslateJson),
        throwsA(isA<InvalidResponseFailure>()),
      );
      expect(client.calls, hasLength(2));
    });

    test('word judge flows through completeJson', () async {
      final FakeLlmClient client = FakeLlmClient([
        'Here: {"ratings":[{"text":"cow","rating":"good","reason":"ok"}]}',
      ]);

      final WordJudgeResult result = await completeJson(
        client,
        baseMessages(),
        validateWordJudgeJson,
      );

      expect(result.ratings.single.text, 'cow');
      expect(client.calls, hasLength(1));
    });

    test('non-JSON failures do not retry', () async {
      final FakeLlmClient client = FakeLlmClient([const AuthFailure()]);

      await expectLater(
        completeJson(client, baseMessages(), validateTranslateJson),
        throwsA(isA<AuthFailure>()),
      );
      expect(client.calls, hasLength(1));
    });
  });
}
