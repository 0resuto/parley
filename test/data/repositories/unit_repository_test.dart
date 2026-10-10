import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/srs/srs_service.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UnitRepository repo;
  final DateTime initial = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    repo = UnitRepository(db, clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  group('add', () {
    test('trims text, normalizes key and uses clock for dates', () async {
      final Unit unit = await repo.add(text: '  Cow ');

      expect(unit.text, 'Cow');
      expect(unit.textKey, 'cow');
      expect(unit.forms, isEmpty);
      expect(unit.knownManual, isFalse);
      expect(unit.phase, CardPhase.isNew);
      expect(unit.createdAt, initial);
      expect(unit.due, initial);
      expect(unit.lastReview, isNull);

      // Read back from the database.
      final Unit? reread = await repo.getById(unit.id);
      expect(reread, unit);
    });

    test('normalizes forms, drops blanks, dupes and the key itself', () async {
      final Unit unit = await repo.add(
        text: 'Cow',
        forms: [' Cows ', 'cows', 'COW', '  ', 'oxen'],
      );

      expect(unit.forms, ['cows', 'oxen']);
    });

    test('blank text is rejected', () async {
      expect(() => repo.add(text: '   '), throwsArgumentError);
    });

    test('duplicate text_key is rejected', () async {
      await repo.add(text: 'Cow');

      expect(() => repo.add(text: 'cow'), throwsException);
      expect(() => repo.add(text: '  COW  '), throwsException);
    });
  });

  group('findByKey', () {
    test('matches text_key case-insensitively', () async {
      final Unit created = await repo.add(text: 'Cow');

      expect((await repo.findByKey('cow'))?.id, created.id);
      expect((await repo.findByKey('  COW '))?.id, created.id);
    });

    test('matches forms', () async {
      final Unit created = await repo.add(text: 'Cow', forms: ['cows']);

      expect((await repo.findByKey('cows'))?.id, created.id);
      expect((await repo.findByKey('COWS'))?.id, created.id);
    });

    test('returns null when missing or blank', () async {
      await repo.add(text: 'Cow');

      expect(await repo.findByKey('milk'), isNull);
      expect(await repo.findByKey('   '), isNull);
    });
  });

  group('getById / update / delete', () {
    test('getById returns null when missing', () async {
      expect(await repo.getById(999), isNull);
    });

    test('update persists fields and recomputes the key', () async {
      final Unit created = await repo.add(text: 'Cow');
      final Unit updated = await repo.update(created.copyWith(text: '  Milk '));

      expect(updated.text, 'Milk');
      expect(updated.textKey, 'milk');
      expect((await repo.findByKey('milk'))?.id, created.id);
      expect(await repo.findByKey('cow'), isNull);
    });

    test('update rejects a colliding key', () async {
      await repo.add(text: 'Cow');
      final Unit other = await repo.add(text: 'Milk');

      expect(() => repo.update(other.copyWith(text: 'cow')), throwsException);
    });

    test('delete removes the unit', () async {
      final Unit created = await repo.add(text: 'Cow');
      await repo.delete(created.id);

      expect(await repo.getById(created.id), isNull);
      expect(await repo.findByKey('cow'), isNull);
    });
  });

  group('setKnown', () {
    test('marking Known keeps the FSRS state', () async {
      final Unit created = await repo.add(text: 'Cow');
      // Give the unit a reviewed state first.
      final Unit reviewed = await repo.update(
        created.copyWith(
          phase: CardPhase.review,
          stability: 30,
          fsrsJson: '{"phase":2}',
          due: initial.add(const Duration(days: 30)),
          lastReview: initial,
        ),
      );

      final Unit? known = await repo.setKnown(reviewed.id, true);
      expect(known?.knownManual, isTrue);
      expect(statusOf(known!), UnitStatus.known);
      expect(known.phase, CardPhase.review);
      expect(known.stability, 30);
      expect(known.fsrsJson, '{"phase":2}');
      expect(known.due, reviewed.due);

      // Un-marking restores the previous FSRS state (never deleted).
      final Unit? unknown = await repo.setKnown(reviewed.id, false);
      expect(unknown?.knownManual, isFalse);
      expect(unknown?.phase, CardPhase.review);
      expect(unknown?.stability, 30);
      expect(unknown?.fsrsJson, '{"phase":2}');
      expect(unknown?.due, reviewed.due);
      expect(statusOf(unknown!), UnitStatus.mature);
    });
  });

  group('watchAll', () {
    test('emits newest first', () async {
      final Unit first = await repo.add(text: 'Cow');
      clock.advance(const Duration(minutes: 1));
      final Unit second = await repo.add(text: 'Milk');

      final List<Unit> units = await repo.watchAll().first;
      expect(units.map((u) => u.id), [second.id, first.id]);
    });

    test('filters by status', () async {
      final Unit fresh = await repo.add(text: 'Cow');
      final Unit known = await repo.add(text: 'Milk');
      await repo.setKnown(known.id, true);

      final List<Unit> onlyKnown = await repo
          .watchAll(status: UnitStatus.known)
          .first;
      expect(onlyKnown.map((u) => u.id), [known.id]);

      final List<Unit> onlyNew = await repo
          .watchAll(status: UnitStatus.newUnit)
          .first;
      expect(onlyNew.map((u) => u.id), [fresh.id]);
    });

    test('filters by query in text and key', () async {
      await repo.add(text: 'Cow');
      final Unit milk = await repo.add(text: 'Milk');

      List<Unit> units = await repo.watchAll(query: 'milk').first;
      expect(units.map((u) => u.id), [milk.id]);

      units = await repo.watchAll(query: 'COW').first;
      expect(units, hasLength(1));
      expect(units.first.text, 'Cow');

      units = await repo.watchAll(query: '  ').first;
      expect(units, hasLength(2));
    });
  });

  group('dueQueue', () {
    test('returns non-Known due units oldest first', () async {
      final Unit overdue = await repo.add(text: 'Cow');
      final Unit future = await repo.add(text: 'Milk');
      final Unit knownDue = await repo.add(text: 'Bread');

      await repo.update(
        overdue.copyWith(due: initial.subtract(const Duration(days: 2))),
      );
      await repo.update(
        future.copyWith(due: initial.add(const Duration(days: 2))),
      );
      await repo.update(
        knownDue.copyWith(due: initial.subtract(const Duration(days: 5))),
      );
      await repo.setKnown(knownDue.id, true);

      final Unit secondDue = await repo.add(text: 'Cheese');
      await repo.update(
        secondDue.copyWith(due: initial.subtract(const Duration(days: 1))),
      );

      final List<Unit> queue = await repo.dueQueue(initial);
      expect(queue.map((u) => u.text), ['Cow', 'Cheese']);
    });

    test('Known units are excluded even when due', () async {
      final Unit unit = await repo.add(text: 'Cow');
      await repo.update(
        unit.copyWith(due: initial.subtract(const Duration(hours: 1))),
      );
      await repo.setKnown(unit.id, true);

      expect(await repo.dueQueue(initial), isEmpty);
      expect(clock.now(), initial);
    });
  });

  group('targetWords', () {
    test('includes New, Learning and Young; due first then newest', () async {
      // Not-due new unit, created first.
      final Unit oldNew = await repo.add(text: 'alpha');
      await repo.update(
        oldNew.copyWith(due: initial.add(const Duration(days: 5))),
      );

      clock.advance(const Duration(minutes: 1));
      // Due new unit, created later but due now (oldest due wins).
      final Unit dueNew = await repo.add(text: 'beta');
      await repo.update(
        dueNew.copyWith(due: initial.subtract(const Duration(days: 1))),
      );

      clock.advance(const Duration(minutes: 1));
      // Not-due new unit, newest.
      final Unit newest = await repo.add(text: 'gamma');
      await repo.update(
        newest.copyWith(due: initial.add(const Duration(days: 5))),
      );

      // Mature and Known are excluded.
      final Unit mature = await repo.add(text: 'delta');
      await repo.update(
        mature.copyWith(
          phase: CardPhase.review,
          stability: 30,
          due: initial.subtract(const Duration(days: 3)),
        ),
      );
      final Unit known = await repo.add(text: 'epsilon');
      await repo.setKnown(known.id, true);

      // Learning unit due now.
      final Unit learning = await repo.add(text: 'zeta');
      await repo.update(
        learning.copyWith(
          phase: CardPhase.learning,
          due: initial.subtract(const Duration(hours: 1)),
        ),
      );

      final List<Unit> words = await repo.targetWords(10, initial);
      // Due first (oldest due first): beta, zeta; then newest: gamma, alpha.
      expect(words.map((u) => u.text), ['beta', 'zeta', 'gamma', 'alpha']);
    });

    test('respects the limit and young/mature boundary at 21 days', () async {
      final Unit young = await repo.add(text: 'young');
      await repo.update(
        young.copyWith(phase: CardPhase.review, stability: 20.9),
      );
      final Unit mature = await repo.add(text: 'mature');
      await repo.update(
        mature.copyWith(phase: CardPhase.review, stability: 21),
      );

      final List<Unit> words = await repo.targetWords(10, initial);
      expect(words.map((u) => u.text), contains('young'));
      expect(words.map((u) => u.text), isNot(contains('mature')));
      expect(await repo.targetWords(1, initial), hasLength(1));
    });
  });

  group('recentlyKnown', () {
    test('returns Mature and Known by latest review', () async {
      final Unit matureOld = await repo.add(text: 'a');
      await repo.update(
        matureOld.copyWith(
          phase: CardPhase.review,
          stability: 30,
          lastReview: initial.subtract(const Duration(days: 3)),
        ),
      );
      final Unit matureNew = await repo.add(text: 'b');
      await repo.update(
        matureNew.copyWith(
          phase: CardPhase.review,
          stability: 40,
          lastReview: initial.subtract(const Duration(days: 1)),
        ),
      );
      final Unit known = await repo.add(text: 'c');
      await repo.update(known.copyWith(lastReview: initial));
      await repo.setKnown(known.id, true);

      // Young and New are excluded.
      final Unit young = await repo.add(text: 'd');
      await repo.update(
        young.copyWith(
          phase: CardPhase.review,
          stability: 5,
          lastReview: initial,
        ),
      );

      final List<Unit> result = await repo.recentlyKnown(10);
      expect(result.map((u) => u.text), ['c', 'b', 'a']);
      expect(await repo.recentlyKnown(2), hasLength(2));
    });
  });
}
