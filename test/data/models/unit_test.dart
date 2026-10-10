import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/services/srs/srs_service.dart';

Unit _unit({
  bool known = false,
  CardPhase phase = CardPhase.isNew,
  double? stability,
}) {
  final DateTime now = DateTime.utc(2026, 1, 1, 12);
  return Unit(
    id: 1,
    text: 'Cow',
    textKey: 'cow',
    forms: const [],
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

void main() {
  group('normalizeKey', () {
    test('lowercases, trims and collapses spaces', () {
      expect(normalizeKey('  Cow  '), 'cow');
      expect(normalizeKey('COW'), 'cow');
      expect(normalizeKey('a  b   c'), 'a b c');
      expect(normalizeKey('  a\tb\nc  '), 'a b c');
    });

    test('replaces curly apostrophe', () {
      expect(normalizeKey('don\u2019t'), "don't");
      expect(normalizeKey('DON\u2019T'), "don't");
    });

    test('keeps inner apostrophes and hyphens', () {
      expect(normalizeKey("mother-in-law's"), "mother-in-law's");
    });

    test('blank input stays blank', () {
      expect(normalizeKey('   '), isEmpty);
    });
  });

  group('statusOf', () {
    test('known_manual true is Known regardless of phase', () {
      expect(
        statusOf(_unit(known: true, phase: CardPhase.review, stability: 30)),
        UnitStatus.known,
      );
      expect(
        statusOf(_unit(known: true, phase: CardPhase.isNew)),
        UnitStatus.known,
      );
    });

    test('new phase is New', () {
      expect(statusOf(_unit(phase: CardPhase.isNew)), UnitStatus.newUnit);
    });

    test('learning and relearning phases are Learning', () {
      expect(statusOf(_unit(phase: CardPhase.learning)), UnitStatus.learning);
      expect(statusOf(_unit(phase: CardPhase.relearning)), UnitStatus.learning);
    });

    test('review below 21 days stability is Young', () {
      expect(
        statusOf(_unit(phase: CardPhase.review, stability: 5)),
        UnitStatus.young,
      );
      expect(
        statusOf(_unit(phase: CardPhase.review, stability: 20.9)),
        UnitStatus.young,
      );
    });

    test('review at or above 21 days stability is Mature', () {
      expect(
        statusOf(_unit(phase: CardPhase.review, stability: 21)),
        UnitStatus.mature,
      );
      expect(
        statusOf(_unit(phase: CardPhase.review, stability: 30)),
        UnitStatus.mature,
      );
    });

    test('review with null stability is Young', () {
      expect(statusOf(_unit(phase: CardPhase.review)), UnitStatus.young);
    });
  });

  group('isTargetWord', () {
    test('New, Learning and Young are targets', () {
      expect(isTargetWord(_unit(phase: CardPhase.isNew)), isTrue);
      expect(isTargetWord(_unit(phase: CardPhase.learning)), isTrue);
      expect(
        isTargetWord(_unit(phase: CardPhase.review, stability: 5)),
        isTrue,
      );
    });

    test('Mature and Known are not targets', () {
      expect(
        isTargetWord(_unit(phase: CardPhase.review, stability: 30)),
        isFalse,
      );
      expect(isTargetWord(_unit(known: true)), isFalse);
    });
  });

  group('forms codec', () {
    test('round trip', () {
      expect(decodeForms(encodeForms(['cows', 'cow'])), ['cows', 'cow']);
      expect(decodeForms('[]'), isEmpty);
    });

    test('invalid input gives empty list', () {
      expect(decodeForms(''), isEmpty);
      expect(decodeForms('not json'), isEmpty);
      expect(decodeForms('{}'), isEmpty);
    });
  });
}
