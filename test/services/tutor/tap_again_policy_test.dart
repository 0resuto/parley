import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';
import 'package:parley/services/tutor/tap_again_policy.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UnitRepository units;
  late ReviewService reviews;
  late TapAgainPolicy policy;
  final DateTime initial = DateTime.utc(2026, 5, 2, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    units = UnitRepository(db, clock: clock);
    reviews = ReviewService(db, units: units, clock: clock);
    policy = TapAgainPolicy(db: db, reviews: reviews, clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<Review>> allReviews() => db.select(db.reviews).get();

  group('TapAgainPolicy 7.2', () {
    test('first open rates with Again and source tap', () async {
      final Unit unit = await units.add(text: 'cow', translationRu: 'корова');

      final bool rated = await policy.maybeRate(unit);

      expect(rated, isTrue);
      final List<Review> rows = await allReviews();
      expect(rows, hasLength(1));
      expect(rows.single.unitId, unit.id);
      expect(rows.single.rating, Rating.again.value);
      expect(rows.single.source, ReviewSource.tap.value);
      expect(rows.single.reviewedAt.toUtc(), initial);
      final Unit? reread = await units.getById(unit.id);
      expect(reread!.lastReview, isNotNull);
    });

    test('second open within 24 h does not rate again', () async {
      final Unit unit = await units.add(text: 'cow');
      expect(await policy.maybeRate(unit), isTrue);

      clock.advance(const Duration(hours: 23, minutes: 59));
      final Unit fresh = (await units.getById(unit.id))!;
      final bool rated = await policy.maybeRate(fresh);

      expect(rated, isFalse);
      expect(await allReviews(), hasLength(1));
    });

    test('open after 24 h rates again', () async {
      final Unit unit = await units.add(text: 'cow');
      expect(await policy.maybeRate(unit), isTrue);

      clock.advance(const Duration(hours: 24, minutes: 1));
      final Unit fresh = (await units.getById(unit.id))!;
      final bool rated = await policy.maybeRate(fresh);

      expect(rated, isTrue);
      final List<Review> rows = await allReviews();
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.source == ReviewSource.tap.value), isTrue);
      expect(rows.every((r) => r.rating == Rating.again.value), isTrue);
    });

    test('Known unit never rates', () async {
      final Unit created = await units.add(text: 'cow');
      await units.setKnown(created.id, true);
      final Unit? known = await units.getById(created.id);
      expect(known!.knownManual, isTrue);

      final bool rated = await policy.maybeRate(known);

      expect(rated, isFalse);
      expect(await allReviews(), isEmpty);
      final Unit? reread = await units.getById(created.id);
      expect(reread!.lastReview, isNull);
    });
  });
}
