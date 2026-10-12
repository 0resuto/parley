import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/srs/srs_service.dart';

import 'fake_clock.dart';
import 'fake_unit_repository.dart';

/// T-16: [FakeUnitRepository.targetWords] / [FakeUnitRepository.recentlyKnown]
/// must mirror the real [UnitRepository]. Both are seeded with the same units
/// and their results are compared (ids in order).
void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UnitRepository real;
  late FakeUnitRepository fake;
  final DateTime initial = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    real = UnitRepository(db, clock: clock);
    fake = FakeUnitRepository(clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  Future<Unit> addBoth(String text) async {
    final Unit realUnit = await real.add(text: text);
    final Unit fakeUnit = await fake.add(text: text);
    expect(fakeUnit.id, realUnit.id, reason: 'ids must line up');
    return fakeUnit;
  }

  Future<void> updateBoth(Unit unit) async {
    await real.update(unit);
    await fake.update(unit);
  }

  Future<void> setKnownBoth(int id, bool known) async {
    await real.setKnown(id, known);
    await fake.setKnown(id, known);
  }

  Future<void> expectTargetsMatch(int limit, DateTime now) async {
    final List<Unit> fromReal = await real.targetWords(limit, now);
    final List<Unit> fromFake = await fake.targetWords(limit, now);
    expect(fromFake.map((u) => u.id), fromReal.map((u) => u.id));
  }

  Future<void> expectKnownMatch(int limit) async {
    final List<Unit> fromReal = await real.recentlyKnown(limit);
    final List<Unit> fromFake = await fake.recentlyKnown(limit);
    expect(fromFake.map((u) => u.id), fromReal.map((u) => u.id));
  }

  test(
    'targetWords: due first, then newest; Mature and Known excluded',
    () async {
      final Unit alpha = await addBoth('alpha');
      await updateBoth(
        alpha.copyWith(due: initial.add(const Duration(days: 5))),
      );

      clock.advance(const Duration(minutes: 1));
      final Unit beta = await addBoth('beta');
      await updateBoth(
        beta.copyWith(due: initial.subtract(const Duration(days: 1))),
      );

      clock.advance(const Duration(minutes: 1));
      final Unit gamma = await addBoth('gamma');
      await updateBoth(
        gamma.copyWith(due: initial.add(const Duration(days: 5))),
      );

      clock.advance(const Duration(minutes: 1));
      final Unit learning = await addBoth('zeta');
      await updateBoth(
        learning.copyWith(
          phase: CardPhase.learning,
          due: initial.subtract(const Duration(hours: 1)),
        ),
      );

      // Mature and Known must not show up as target words.
      final Unit mature = await addBoth('delta');
      await updateBoth(
        mature.copyWith(
          phase: CardPhase.review,
          stability: 30,
          due: initial.subtract(const Duration(days: 3)),
        ),
      );
      final Unit known = await addBoth('epsilon');
      await updateBoth(known.copyWith(phase: CardPhase.review, stability: 30));
      await setKnownBoth(known.id, true);

      // Young (review below the stability threshold) is a target word.
      clock.advance(const Duration(minutes: 1));
      final Unit young = await addBoth('eta');
      await updateBoth(
        young.copyWith(
          phase: CardPhase.review,
          stability: 5,
          due: initial.add(const Duration(days: 1)),
        ),
      );

      await expectTargetsMatch(10, initial);
      await expectKnownMatch(10);

      final List<Unit> targets = await fake.targetWords(10, initial);
      expect(targets.map((u) => u.text), [
        'beta',
        'zeta',
        'eta',
        'gamma',
        'alpha',
      ]);
    },
  );

  test('targetWords: limit truncation and the young/mature boundary', () async {
    final Unit first = await addBoth('first');
    await updateBoth(
      first.copyWith(due: initial.subtract(const Duration(days: 2))),
    );

    clock.advance(const Duration(minutes: 1));
    final Unit second = await addBoth('second');
    await updateBoth(
      second.copyWith(due: initial.subtract(const Duration(days: 1))),
    );

    clock.advance(const Duration(minutes: 1));
    final Unit young = await addBoth('young');
    await updateBoth(
      young.copyWith(
        phase: CardPhase.review,
        stability: 20.9,
        due: initial.add(const Duration(days: 3)),
      ),
    );

    final Unit mature = await addBoth('mature');
    await updateBoth(
      mature.copyWith(
        phase: CardPhase.review,
        stability: 21,
        due: initial.subtract(const Duration(days: 3)),
      ),
    );

    await expectTargetsMatch(10, initial);
    await expectTargetsMatch(2, initial);
    await expectTargetsMatch(1, initial);

    final List<Unit> all = await fake.targetWords(10, initial);
    expect(all.map((u) => u.id), [first.id, second.id, young.id]);
    expect(await fake.targetWords(1, initial), hasLength(1));
  });

  test('recentlyKnown: latest review first, null lastReview ties', () async {
    final Unit matureOld = await addBoth('a');
    await updateBoth(
      matureOld.copyWith(
        phase: CardPhase.review,
        stability: 30,
        lastReview: initial.subtract(const Duration(days: 3)),
      ),
    );

    clock.advance(const Duration(minutes: 1));
    final Unit matureNew = await addBoth('b');
    await updateBoth(
      matureNew.copyWith(
        phase: CardPhase.review,
        stability: 40,
        lastReview: initial.subtract(const Duration(days: 1)),
      ),
    );

    clock.advance(const Duration(minutes: 1));
    final Unit knownReviewed = await addBoth('c');
    await updateBoth(knownReviewed.copyWith(lastReview: initial));
    await setKnownBoth(knownReviewed.id, true);

    // Null `lastReview` ties fall back to newest created first.
    clock.advance(const Duration(minutes: 1));
    final Unit knownNullOlder = await addBoth('d');
    await setKnownBoth(knownNullOlder.id, true);

    clock.advance(const Duration(minutes: 1));
    final Unit knownNullNewer = await addBoth('e');
    await setKnownBoth(knownNullNewer.id, true);

    // Young is excluded even though it has a review date.
    final Unit young = await addBoth('f');
    await updateBoth(
      young.copyWith(
        phase: CardPhase.review,
        stability: 5,
        lastReview: initial,
      ),
    );

    await expectKnownMatch(10);
    await expectKnownMatch(2);

    final List<Unit> known = await fake.recentlyKnown(10);
    expect(known.map((u) => u.id), [
      knownReviewed.id,
      matureNew.id,
      matureOld.id,
      knownNullNewer.id,
      knownNullOlder.id,
    ]);
    expect(await fake.recentlyKnown(2), hasLength(2));
  });
}
