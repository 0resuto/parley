import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
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
/// The real [ReviewService] records every review in [AppDatabase]; the fake
/// units are mirrored into that database by [seedDatabase], so the real
/// foreign key holds. This stub only keeps the test hooks ([gate],
/// [rateCalls]) around the real logic, so tests still catch a regression
/// that stops writing the review row.
class StubReviewService extends ReviewService {
  StubReviewService({
    required AppDatabase db,
    required UnitRepository units,
    required Clock clock,
    SrsService? srs,
  }) : super(db, units: units, clock: clock, srs: srs);

  /// When set, [rate] waits for it before applying the review (for
  /// in-flight tests).
  Completer<void>? gate;

  /// Number of [rate] calls, for assertions.
  int rateCalls = 0;

  @override
  Future<Unit?> rate(
    int unitId,
    Rating rating,
    ReviewSource source, {
    DateTime? at,
  }) async {
    rateCalls++;
    final Completer<void>? pending = gate;
    if (pending != null) {
      await pending.future;
    }
    // (T-18) Go through the real logic so the review row is written.
    return super.rate(unitId, rating, source, at: at);
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
    // (T-20) Close streams synchronously so disposing the widget tree leaves
    // no drift timer pending; same pattern as `test/app_test.dart`.
    dummyDb = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
  });

  tearDown(() async {
    await dummyDb.close();
  });

  /// Mirrors the fake repository units into [dummyDb] so the real
  /// [ReviewService] insert satisfies the `reviews.unit_id` foreign key
  /// (T-18).
  Future<void> seedDatabase() async {
    final List<Unit> units = await repo.watchAll().first;
    for (final Unit unit in units) {
      await dummyDb
          .into(dummyDb.units)
          .insert(
            UnitsCompanion.insert(
              id: Value(unit.id),
              unitText: unit.text,
              textKey: unit.textKey,
              forms: Value(encodeForms(unit.forms)),
              description: Value(unit.description),
              knownManual: Value(unit.knownManual),
              phase: unit.phase.value,
              due: unit.due,
              stability: Value(unit.stability),
              fsrsJson: unit.fsrsJson,
              createdAt: unit.createdAt,
              lastReview: Value(unit.lastReview),
            ),
          );
    }
  }

  Future<void> pumpCards(
    WidgetTester tester, {
    FakeDictionaryService? dictionary,
    StubReviewService? reviews,
  }) async {
    final FakeConnectivityService connectivity = FakeConnectivityService();
    addTearDown(connectivity.dispose);
    connectivity.setOnline(false);
    final StubReviewService reviewsService =
        reviews ?? StubReviewService(db: dummyDb, units: repo, clock: clock);
    await seedDatabase();
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
          reviewServiceProvider.overrideWithValue(reviewsService),
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

    testWidgets('rating writes a review row for the current card', (
      WidgetTester tester,
    ) async {
      final Unit cow = await repo.add(text: 'Cow');
      await repo.add(text: 'Milk');

      await pumpCards(tester);
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      final List<Review> rows = await dummyDb.select(dummyDb.reviews).get();
      expect(rows, hasLength(1));
      expect(rows.single.unitId, cow.id);
      expect(rows.single.rating, Rating.good.value);
      expect(rows.single.source, ReviewSource.card.value);
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

    testWidgets('rating buttons appear only after the meaning resolves', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');
      final FakeDictionaryService dictionary = FakeDictionaryService({
        'cow': 'корова',
      });
      dictionary.gate = Completer<void>();

      await pumpCards(tester, dictionary: dictionary);

      await tester.tap(find.text('Show answer'));
      await tester.pump();

      expect(find.byKey(const Key('cardMeaningSpinner')), findsOneWidget);
      expect(find.text('Again'), findsNothing);
      expect(find.text('Good'), findsNothing);

      dictionary.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.text('корова'), findsOneWidget);
      expect(find.text('Again'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
    });

    testWidgets('a double tap on a rating applies only one review', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');
      await repo.add(text: 'Milk');
      final StubReviewService reviews = StubReviewService(
        db: dummyDb,
        units: repo,
        clock: clock,
      );
      reviews.gate = Completer<void>();

      await pumpCards(tester, reviews: reviews);
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Good'));
      await tester.tap(find.text('Good'));
      expect(reviews.rateCalls, 1);

      await tester.pump();
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Good'))
            .onPressed,
        isNull,
      );

      reviews.gate!.complete();
      await tester.pumpAndSettle();

      expect(reviews.rateCalls, 1);
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('1 left'), findsOneWidget);
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
