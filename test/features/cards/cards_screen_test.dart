import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/features/cards/cards_controller.dart';
import 'package:parley/features/cards/cards_screen.dart';
import 'package:parley/features/chat/chat_controller.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_connectivity_service.dart';
import '../../helpers/fake_dictionary_service.dart';
import '../../helpers/fake_unit_repository.dart';

/// ReviewService double that works on the fake repository.
///
/// The real [ReviewService] writes a `reviews` row into [AppDatabase],
/// which would violate the foreign key when units live only in the fake.
/// This stub applies the same FSRS transition and updates the fake, so the
/// rated card leaves the due queue without touching the database.
class StubReviewService extends ReviewService {
  StubReviewService({
    required AppDatabase db,
    required UnitRepository units,
    required Clock clock,
    SrsService? srs,
  }) : _units = units,
       _clock = clock,
       _srs = srs ?? SrsService(),
       super(db, units: units, clock: clock);

  final UnitRepository _units;
  final Clock _clock;
  final SrsService _srs;

  @override
  Future<Unit?> rate(
    int unitId,
    Rating rating,
    ReviewSource source, {
    DateTime? at,
  }) async {
    final Unit? unit = await _units.getById(unitId);
    if (unit == null || unit.knownManual) {
      return null;
    }
    final DateTime now = (at ?? _clock.now()).toUtc();
    final SrsCard next = _srs.review(
      SrsCard.fromJson(unit.fsrsJson),
      rating,
      now,
    );
    return _units.update(
      unit.copyWith(
        phase: next.phase,
        due: next.due,
        stability: next.stability,
        fsrsJson: next.toJson(),
        lastReview: now,
      ),
    );
  }
}

/// [UnitRepository] double whose queue load always fails (PLAN 9.1).
class FailingDueQueueRepository extends FakeUnitRepository {
  FailingDueQueueRepository({required super.clock});

  @override
  Future<List<Unit>> dueQueue(DateTime now) async {
    throw StateError('db unavailable');
  }
}

/// [UnitRepository] double that fails once, then works (for Retry, 9.1).
class FlakyDueQueueRepository extends FakeUnitRepository {
  FlakyDueQueueRepository({required super.clock});

  bool failNext = true;

  @override
  Future<List<Unit>> dueQueue(DateTime now) async {
    if (failNext) {
      failNext = false;
      throw StateError('db unavailable');
    }
    return super.dueQueue(now);
  }
}

void main() {
  late FakeClock clock;
  late FakeUnitRepository repo;
  late AppDatabase dummyDb;
  final DateTime initial = DateTime.utc(2026, 2, 1, 12);

  setUp(() {
    clock = FakeClock(initial);
    repo = FakeUnitRepository(clock: clock);
    dummyDb = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await dummyDb.close();
  });

  Future<void> pumpCards(
    WidgetTester tester, {
    FakeDictionaryService? dictionary,
  }) async {
    final FakeConnectivityService connectivity = FakeConnectivityService();
    addTearDown(connectivity.dispose);
    connectivity.setOnline(false);
    final StubReviewService reviews = StubReviewService(
      db: dummyDb,
      units: repo,
      clock: clock,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(repo),
          clockProvider.overrideWithValue(clock),
          connectivityServiceProvider.overrideWithValue(connectivity),
          dictionaryServiceProvider.overrideWithValue(
            dictionary ??
                FakeDictionaryService({'cow': 'корова', 'milk': 'молоко'}),
          ),
          userDictionaryLookupProvider.overrideWithValue(
            const EmptyUserDictionaryLookup(),
          ),
          reviewServiceProvider.overrideWithValue(reviews),
        ],
        child: const MaterialApp(home: CardsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('CardsScreen', () {
    testWidgets('empty queue shows caught-up state', (
      WidgetTester tester,
    ) async {
      await pumpCards(tester);

      expect(find.text('All caught up.'), findsOneWidget);
      expect(find.text('Show answer'), findsNothing);
      expect(find.text('Again'), findsNothing);
    });

    testWidgets('full cycle: reveal, rate, mark known', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');
      await repo.add(text: 'Milk');

      await pumpCards(tester);

      expect(find.text('2 left'), findsOneWidget);
      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('Show answer'), findsOneWidget);
      expect(find.text('Again'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();

      expect(find.text('корова'), findsOneWidget);
      expect(find.text('Again'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);
      expect(find.text('Show answer'), findsNothing);

      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      expect(find.text('1 left'), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('Cow'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      expect(find.text('молоко'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Mark as known'), findsOneWidget);

      await tester.tap(find.text('Mark as known'));
      await tester.pumpAndSettle();

      expect(find.text('All caught up.'), findsOneWidget);
      expect(find.text('Milk'), findsNothing);
    });

    testWidgets('front shows the English word and hides the meaning', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');

      await pumpCards(tester);

      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('корова'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();

      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('корова'), findsOneWidget);
    });

    testWidgets('a missing meaning shows the placeholder', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Heifer');

      await pumpCards(tester, dictionary: FakeDictionaryService());

      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();

      expect(find.text('(no meaning)'), findsOneWidget);
    });

    testWidgets('queue load failure shows an error with Retry', (
      WidgetTester tester,
    ) async {
      final FailingDueQueueRepository failing = FailingDueQueueRepository(
        clock: clock,
      );
      final StubReviewService reviews = StubReviewService(
        db: dummyDb,
        units: failing,
        clock: clock,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(failing),
            clockProvider.overrideWithValue(clock),
            reviewServiceProvider.overrideWithValue(reviews),
          ],
          child: const MaterialApp(home: CardsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(find.byKey(const Key('cardsRetryButton')), findsOneWidget);
      expect(find.text('All caught up.'), findsNothing);
    });

    testWidgets('Retry after a failure loads the queue', (
      WidgetTester tester,
    ) async {
      final FlakyDueQueueRepository flaky = FlakyDueQueueRepository(
        clock: clock,
      );
      await flaky.add(text: 'Cow');
      final StubReviewService reviews = StubReviewService(
        db: dummyDb,
        units: flaky,
        clock: clock,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(flaky),
            clockProvider.overrideWithValue(clock),
            reviewServiceProvider.overrideWithValue(reviews),
          ],
          child: const MaterialApp(home: CardsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cardsRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsNothing);
      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('1 left'), findsOneWidget);
    });
  });
}
