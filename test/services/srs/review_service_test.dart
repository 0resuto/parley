import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UnitRepository repo;
  late ReviewService reviews;
  final DateTime initial = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    repo = UnitRepository(db, clock: clock);
    reviews = ReviewService(db, units: repo, clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<Review>> allReviews() => db.select(db.reviews).get();

  group('rate', () {
    test('new unit becomes Learning and updates state', () async {
      final Unit unit = await repo.add(text: 'Cow');
      expect(unit.phase, CardPhase.isNew);

      final DateTime at = initial.add(const Duration(hours: 1));
      final Unit? updated = await reviews.rate(
        unit.id,
        Rating.again,
        ReviewSource.card,
        at: at,
      );

      expect(updated, isNotNull);
      expect(updated!.phase, CardPhase.learning);
      expect(updated.lastReview, at.toUtc());
      expect(updated.stability, isNotNull);
      expect(updated.fsrsJson, isNot(unit.fsrsJson));

      final Unit? reread = await repo.getById(unit.id);
      expect(reread, updated);
    });

    test('review row is written with the right source and rating', () async {
      final Unit unit = await repo.add(text: 'Cow');
      final DateTime at = initial.add(const Duration(minutes: 5));

      await reviews.rate(unit.id, Rating.good, ReviewSource.chat, at: at);

      final List<Review> rows = await allReviews();
      expect(rows, hasLength(1));
      expect(rows.first.unitId, unit.id);
      expect(rows.first.rating, Rating.good.value);
      expect(rows.first.source, 'chat');
      expect(rows.first.reviewedAt.toUtc(), at.toUtc());
    });

    test('each source round-trips to its SPEC string', () async {
      final Unit card = await repo.add(text: 'alpha');
      final Unit chat = await repo.add(text: 'beta');
      final Unit tap = await repo.add(text: 'gamma');

      await reviews.rate(card.id, Rating.good, ReviewSource.card);
      await reviews.rate(chat.id, Rating.hard, ReviewSource.chat);
      await reviews.rate(tap.id, Rating.again, ReviewSource.tap);

      final List<Review> rows = await allReviews();
      expect(rows, hasLength(3));
      final Map<int, Review> byUnit = {
        for (final Review r in rows) r.unitId: r,
      };
      expect(byUnit[card.id]!.source, 'card');
      expect(byUnit[card.id]!.rating, 3);
      expect(byUnit[chat.id]!.source, 'chat');
      expect(byUnit[chat.id]!.rating, 2);
      expect(byUnit[tap.id]!.source, 'tap');
      expect(byUnit[tap.id]!.rating, 1);
    });

    test('rating a Known unit is ignored', () async {
      final Unit unit = await repo.add(text: 'Cow');
      await repo.setKnown(unit.id, true);
      final Unit? before = await repo.getById(unit.id);

      final Unit? result = await reviews.rate(
        unit.id,
        Rating.good,
        ReviewSource.card,
      );

      expect(result, isNull);
      expect(await allReviews(), isEmpty);
      final Unit? after = await repo.getById(unit.id);
      expect(after, before);
      expect(after!.lastReview, isNull);
    });

    test('rating a missing unit returns null and writes nothing', () async {
      final Unit? result = await reviews.rate(
        999,
        Rating.good,
        ReviewSource.card,
      );

      expect(result, isNull);
      expect(await allReviews(), isEmpty);
    });

    test('uses the clock when at is omitted', () async {
      final Unit unit = await repo.add(text: 'Cow');
      clock.advance(const Duration(hours: 2));
      final DateTime expected = clock.now().toUtc();

      final Unit? updated = await reviews.rate(
        unit.id,
        Rating.good,
        ReviewSource.card,
      );

      expect(updated!.lastReview, expected);
      final List<Review> rows = await allReviews();
      expect(rows.single.reviewedAt.toUtc(), expected);
      expect(rows.single.source, 'card');
    });

    test('uses explicit at over the clock', () async {
      final Unit unit = await repo.add(text: 'Cow');
      final DateTime at = DateTime.utc(2026, 2, 2, 8);

      final Unit? updated = await reviews.rate(
        unit.id,
        Rating.easy,
        ReviewSource.card,
        at: at,
      );

      expect(updated!.lastReview, at);
      expect((await allReviews()).single.reviewedAt.toUtc(), at);
      expect(clock.now(), initial);
    });
  });

  group('ReviewSource', () {
    test('values match the SPEC column', () {
      expect(ReviewSource.card.value, 'card');
      expect(ReviewSource.chat.value, 'chat');
      expect(ReviewSource.tap.value, 'tap');
    });

    test('fromValue round-trips and rejects unknown', () {
      expect(ReviewSource.fromValue('card'), ReviewSource.card);
      expect(ReviewSource.fromValue('chat'), ReviewSource.chat);
      expect(ReviewSource.fromValue('tap'), ReviewSource.tap);
      expect(() => ReviewSource.fromValue('other'), throwsArgumentError);
    });
  });
}
