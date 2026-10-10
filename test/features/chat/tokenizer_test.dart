import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/features/chat/tokenizer.dart';
import 'package:parley/services/srs/srs_service.dart';

Unit _unit({
  int id = 1,
  String text = 'Cow',
  List<String> forms = const [],
  bool known = false,
  CardPhase phase = CardPhase.isNew,
  double? stability,
}) {
  final DateTime now = DateTime.utc(2026, 1, 1, 12);
  final String key = text.toLowerCase();
  return Unit(
    id: id,
    text: text,
    textKey: key,
    forms: forms,
    translationRu: '',
    description: null,
    knownManual: known,
    phase: phase,
    due: now,
    stability: stability,
    fsrsJson: '{}',
    createdAt: now,
    lastReview: null,
  );
}

String _visible(List<ChatSpan> spans) => spans.map((s) => s.text).join();

void main() {
  group('stripMarkers', () {
    test('removes markers, keeps inner text', () {
      expect(stripMarkers('Say [[heifer]] now'), 'Say heifer now');
      expect(stripMarkers('[[cow]]'), 'cow');
      expect(stripMarkers('no markers'), 'no markers');
    });

    test('leaves unclosed markers alone', () {
      expect(stripMarkers('Say [[heifer now'), 'Say [[heifer now');
    });
  });

  group('parseMessage', () {
    test('visible text equals stripped message text', () {
      const String raw = 'Hello [[heifer]] and cow!';
      expect(
        _visible(parseMessage(raw, UnitIndex.empty())),
        'Hello heifer and cow!',
      );
      expect(_visible(parseMessage(raw, UnitIndex.empty())), stripMarkers(raw));
    });

    test('apostrophes and hyphens stay inside one token', () {
      final List<ChatSpan> spans = parseMessage(
        "don't mother-in-law",
        UnitIndex.empty(),
      );
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words.map((w) => w.surface), ["don't", 'mother-in-law']);
      expect(words.map((w) => w.key), ["don't", 'mother-in-law']);
    });

    test('matching is case-insensitive', () {
      final UnitIndex index = UnitIndex.fromUnits([_unit(text: 'Cow')]);
      final List<ChatSpan> spans = parseMessage('COW cow CoW', index);
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words, hasLength(3));
      for (final ChatSpan w in words) {
        expect(w.unit, isNotNull);
        expect(w.key, 'cow');
      }
    });

    test('form match resolves to the unit', () {
      final UnitIndex index = UnitIndex.fromUnits([
        _unit(text: 'cow', forms: ['cows']),
      ]);
      final List<ChatSpan> spans = parseMessage('cows', index);
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words, hasLength(1));
      expect(words.single.unit, isNotNull);
      expect(words.single.key, 'cows');
    });

    test('phrase match groups tokens longest first', () {
      final UnitIndex index = UnitIndex.fromUnits([
        _unit(id: 1, text: 'new york'),
        _unit(id: 2, text: 'new york city'),
      ]);
      final List<ChatSpan> spans = parseMessage(
        'I love new york city today',
        index,
      );
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words.map((w) => w.text), ['I', 'love', 'new york city', 'today']);
      expect(words[2].unit?.id, 2);
      expect(words[2].key, 'new york city');
    });

    test('short phrase still matches when long one is absent', () {
      final UnitIndex index = UnitIndex.fromUnits([
        _unit(id: 1, text: 'ice cream'),
      ]);
      final List<ChatSpan> spans = parseMessage('I like ice cream', index);
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words.map((w) => w.text), ['I', 'like', 'ice cream']);
      expect(words[2].unit?.id, 1);
    });

    test('Known unit is matched but flagged known', () {
      final UnitIndex index = UnitIndex.fromUnits([
        _unit(text: 'cow', known: true),
      ]);
      final List<ChatSpan> spans = parseMessage('cow', index);
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words.single.unit, isNotNull);
      expect(statusOf(words.single.unit!), UnitStatus.known);
    });

    test('AI-new flag comes from markers only', () {
      final UnitIndex index = UnitIndex.empty();
      final List<ChatSpan> spans = parseMessage('Say [[heifer]] now', index);
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words.map((w) => w.surface), ['Say', 'heifer', 'now']);
      expect(words[1].isAiNew, isTrue);
      expect(words[0].isAiNew, isFalse);
      expect(words[2].isAiNew, isFalse);
    });

    test('AI-new word in dictionary keeps the unit', () {
      final UnitIndex index = UnitIndex.fromUnits([_unit(text: 'cow')]);
      final List<ChatSpan> spans = parseMessage('See [[cow]] run', index);
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      final ChatSpan cow = words.firstWhere((w) => w.key == 'cow');
      expect(cow.isAiNew, isTrue);
      expect(cow.unit, isNotNull);
    });

    test('sentence is attached to each word', () {
      final List<ChatSpan> spans = parseMessage(
        'Hello world. How are you?',
        UnitIndex.empty(),
      );
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      final ChatSpan you = words.firstWhere((w) => w.surface == 'you');
      expect(you.sentence, 'How are you?');
      final ChatSpan world = words.firstWhere((w) => w.surface == 'world');
      expect(world.sentence, 'Hello world.');
    });

    test('words carry normalized keys with curly apostrophe', () {
      final List<ChatSpan> spans = parseMessage(
        'don\u2019t stop',
        UnitIndex.empty(),
      );
      final List<ChatSpan> words = spans.where((s) => s.isWord).toList();
      expect(words.first.key, "don't");
    });
  });

  group('UnitIndex', () {
    test('includes forms and prefers text_key', () {
      final Unit first = _unit(id: 1, text: 'cow', forms: ['cows']);
      final UnitIndex index = UnitIndex.fromUnits([first]);
      expect(index.lookup('cow')?.id, 1);
      expect(index.lookup('cows')?.id, 1);
      expect(index.lookup('COW'), isNull);
    });

    test('empty index matches nothing', () {
      expect(UnitIndex.empty().lookup('cow'), isNull);
      expect(UnitIndex.empty().maxPhraseWords, 1);
    });
  });

  group('sentenceForOffset', () {
    test('empty text gives empty sentence', () {
      expect(sentenceForOffset('', 0), isEmpty);
    });

    test('splits on punctuation', () {
      const String text = 'First one. Second one!';
      expect(sentenceForOffset(text, 2), 'First one.');
      expect(sentenceForOffset(text, 14), 'Second one!');
    });
  });
}
