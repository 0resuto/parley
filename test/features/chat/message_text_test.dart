import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/features/chat/message_text.dart';
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
  return Unit(
    id: id,
    text: text,
    textKey: text.toLowerCase(),
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

Future<RichText> _pump(
  WidgetTester tester, {
  required String raw,
  required UnitIndex index,
  WordTapCallback? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MessageText(rawText: raw, index: index, onWordTap: onTap),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final Finder rich = find.descendant(
    of: find.byType(MessageText),
    matching: find.byType(RichText),
  );
  // Empty text renders a plain Text (still a RichText underneath).
  expect(rich, findsOneWidget);
  return tester.widget<RichText>(rich);
}

List<TextSpan> _wordSpans(RichText rich) {
  final List<TextSpan> out = [];
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.recognizer != null) {
        out.add(span);
      }
      for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }
  }

  visit(rich.text);
  return out;
}

void main() {
  group('MessageText 6.5', () {
    testWidgets('visible text equals stripped message text', (
      WidgetTester tester,
    ) async {
      const String raw = 'Hello [[heifer]] and cow!';
      final RichText rich = await _pump(
        tester,
        raw: raw,
        index: UnitIndex.empty(),
      );
      expect(rich.text.toPlainText(), stripMarkers(raw));
      expect(rich.text.toPlainText(), 'Hello heifer and cow!');
    });

    testWidgets('dictionary word has solid primary underline', (
      WidgetTester tester,
    ) async {
      final UnitIndex index = UnitIndex.fromUnits([_unit(text: 'cow')]);
      final RichText rich = await _pump(
        tester,
        raw: 'see cow run',
        index: index,
      );
      final BuildContext ctx = tester.element(find.byType(MessageText));
      final ColorScheme colors = Theme.of(ctx).colorScheme;
      final List<TextSpan> words = _wordSpans(rich);
      expect(words.map((w) => w.text), ['see', 'cow', 'run']);
      // Only the dictionary word is styled; every word is tappable.
      expect(words.every((w) => w.recognizer != null), isTrue);
      final TextSpan cow = words.firstWhere((w) => w.text == 'cow');
      expect(cow.style?.decoration, TextDecoration.underline);
      expect(cow.style?.decorationStyle, TextDecorationStyle.solid);
      expect(cow.style?.color, colors.primary);
      final TextSpan see = words.firstWhere((w) => w.text == 'see');
      expect(see.style?.decoration, isNot(TextDecoration.underline));
    });

    testWidgets(
      'AI-new word outside dictionary has dotted tertiary underline',
      (WidgetTester tester) async {
        final RichText rich = await _pump(
          tester,
          raw: 'see [[heifer]] run',
          index: UnitIndex.empty(),
        );
        final BuildContext ctx = tester.element(find.byType(MessageText));
        final ColorScheme colors = Theme.of(ctx).colorScheme;
        final List<TextSpan> words = _wordSpans(rich);
        final TextSpan heifer = words.firstWhere((w) => w.text == 'heifer');
        expect(heifer.style?.decoration, TextDecoration.underline);
        expect(heifer.style?.decorationStyle, TextDecorationStyle.dotted);
        expect(heifer.style?.color, colors.tertiary);
      },
    );

    testWidgets('AI-new word in dictionary uses the dictionary style', (
      WidgetTester tester,
    ) async {
      final UnitIndex index = UnitIndex.fromUnits([_unit(text: 'cow')]);
      final RichText rich = await _pump(
        tester,
        raw: 'see [[cow]] run',
        index: index,
      );
      final BuildContext ctx = tester.element(find.byType(MessageText));
      final ColorScheme colors = Theme.of(ctx).colorScheme;
      final List<TextSpan> words = _wordSpans(rich);
      final TextSpan cow = words.firstWhere((w) => w.text == 'cow');
      expect(cow.style?.decoration, TextDecoration.underline);
      expect(cow.style?.decorationStyle, TextDecorationStyle.solid);
      expect(cow.style?.color, colors.primary);
    });

    testWidgets('Known unit has no style but is tappable', (
      WidgetTester tester,
    ) async {
      final UnitIndex index = UnitIndex.fromUnits([
        _unit(text: 'cow', known: true),
      ]);
      String? tapped;
      final RichText rich = await _pump(
        tester,
        raw: 'see cow run',
        index: index,
        onTap: (surface, key, sentence) => tapped = surface,
      );
      final List<TextSpan> words = _wordSpans(rich);
      final TextSpan cow = words.firstWhere((w) => w.text == 'cow');
      expect(
        cow.style?.decoration,
        isNot(TextDecoration.underline),
        reason: 'Known units have no styling',
      );
      expect(cow.recognizer, isNotNull);
      (cow.recognizer! as TapGestureRecognizer).onTap!();
      expect(tapped, 'cow');
    });

    testWidgets('tap reports surface, key and sentence', (
      WidgetTester tester,
    ) async {
      final UnitIndex index = UnitIndex.fromUnits([
        _unit(text: 'cows', forms: const []),
      ]);
      final List<List<String>> calls = [];
      final RichText rich = await _pump(
        tester,
        raw: 'Hello world. I love COWS a lot.',
        index: UnitIndex.fromUnits([_unit(text: 'cows')]),
        onTap: (surface, key, sentence) => calls.add([surface, key, sentence]),
      );
      expect(index.lookup('cows'), isNotNull);
      final List<TextSpan> words = _wordSpans(rich);
      final TextSpan cows = words.firstWhere((w) => w.text == 'COWS');
      (cows.recognizer! as TapGestureRecognizer).onTap!();
      expect(calls, hasLength(1));
      expect(calls.single[0], 'COWS');
      expect(calls.single[1], 'cows');
      expect(calls.single[2], 'I love COWS a lot.');
    });

    testWidgets('phrase match is one tappable span', (
      WidgetTester tester,
    ) async {
      final UnitIndex index = UnitIndex.fromUnits([
        _unit(id: 7, text: 'ice cream'),
      ]);
      String? tappedKey;
      final RichText rich = await _pump(
        tester,
        raw: 'I like ice cream today',
        index: index,
        onTap: (surface, key, sentence) => tappedKey = key,
      );
      final List<TextSpan> words = _wordSpans(rich);
      expect(words.map((w) => w.text), ['I', 'like', 'ice cream', 'today']);
      final TextSpan phrase = words.firstWhere((w) => w.text == 'ice cream');
      expect(phrase.style?.decoration, TextDecoration.underline);
      (phrase.recognizer! as TapGestureRecognizer).onTap!();
      expect(tappedKey, 'ice cream');
    });
  });
}
