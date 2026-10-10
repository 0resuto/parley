import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/features/cards/cards_controller.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/srs/srs_service.dart';

import '../../helpers/fake_clock.dart';

/// Deterministic [Random] returning [values] in order for [nextBool].
class StubRandom implements Random {
  StubRandom(this.values);

  final List<bool> values;
  int _index = 0;

  @override
  bool nextBool() {
    final bool value = values[_index % values.length];
    _index++;
    return value;
  }

  @override
  double nextDouble() => 0.0;

  @override
  int nextInt(int max) => 0;
}

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late ProviderContainer container;
  final DateTime initial = DateTime.utc(2026, 2, 1, 12);

  ProviderContainer makeContainer({Random? random}) {
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        randomProvider.overrideWithValue(random ?? Random(42)),
      ],
    );
  }

  Future<Unit> addWord(String text, {DateTime? due}) async {
    final UnitRepository repo = container.read(unitRepositoryProvider);
    final Unit unit = await repo.add(text: text);
    if (due == null) {
      return unit;
    }
    return repo.update(unit.copyWith(due: due));
  }

  Future<CardsState> refresh() async {
    await container.read(cardsControllerProvider.notifier).refresh();
    return container.read(cardsControllerProvider);
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('CardsController', () {
    test('starts loading and empty before refresh', () {
      final CardsState state = container.read(cardsControllerProvider);

      expect(state.isLoading, isTrue);
      expect(state.isEmpty, isTrue);
      expect(state.current, isNull);
      expect(state.remaining, 0);
      expect(state.revealed, isFalse);
    });

    test('loads due queue oldest first, skips future and Known', () async {
      final Unit cow = await addWord(
        'cow',
        due: initial.subtract(const Duration(days: 2)),
      );
      await addWord('milk', due: initial.subtract(const Duration(days: 1)));
      final Unit future = await addWord(
        'bread',
        due: initial.add(const Duration(days: 2)),
      );
      final Unit known = await addWord(
        'cheese',
        due: initial.subtract(const Duration(days: 5)),
      );
      await container.read(unitRepositoryProvider).setKnown(known.id, true);
      expect(cow.id, isNotNull);
      expect(future.id, isNotNull);

      final CardsState state = await refresh();

      expect(state.isLoading, isFalse);
      expect(state.isEmpty, isFalse);
      expect(state.remaining, 2);
      expect(state.queue.map((u) => u.text), ['cow', 'milk']);
      expect(state.current?.text, 'cow');
      expect(state.revealed, isFalse);
    });

    test('reveal shows the answer and is idempotent', () async {
      await addWord('cow');
      CardsState state = await refresh();
      expect(state.revealed, isFalse);

      container.read(cardsControllerProvider.notifier).reveal();
      state = container.read(cardsControllerProvider);
      expect(state.revealed, isTrue);
      expect(state.current?.text, 'cow');

      container.read(cardsControllerProvider.notifier).reveal();
      state = container.read(cardsControllerProvider);
      expect(state.revealed, isTrue);
    });

    test('reveal on empty queue does nothing', () async {
      final CardsState before = await refresh();
      expect(before.isEmpty, isTrue);

      container.read(cardsControllerProvider.notifier).reveal();

      final CardsState after = container.read(cardsControllerProvider);
      expect(after.revealed, isFalse);
      expect(after.isEmpty, isTrue);
    });

    test('rating moves to the next card and resets reveal', () async {
      await addWord('alpha', due: initial.subtract(const Duration(days: 2)));
      await addWord('beta', due: initial.subtract(const Duration(days: 1)));
      CardsState state = await refresh();
      expect(state.queue.map((u) => u.text), ['alpha', 'beta']);

      container.read(cardsControllerProvider.notifier).reveal();
      expect(container.read(cardsControllerProvider).revealed, isTrue);

      await container.read(cardsControllerProvider.notifier).rate(Rating.good);

      state = container.read(cardsControllerProvider);
      expect(state.remaining, 1);
      expect(state.current?.text, 'beta');
      expect(state.revealed, isFalse);

      final List<Unit> queue = await container
          .read(unitRepositoryProvider)
          .dueQueue(initial);
      expect(queue.map((u) => u.text), ['beta']);
    });

    test('empty queue state with future-only units', () async {
      await addWord('bread', due: initial.add(const Duration(days: 1)));

      final CardsState state = await refresh();

      expect(state.isLoading, isFalse);
      expect(state.isEmpty, isTrue);
      expect(state.current, isNull);
      expect(state.remaining, 0);

      // Actions on empty queue are safe no-ops.
      await container.read(cardsControllerProvider.notifier).rate(Rating.good);
      await container.read(cardsControllerProvider.notifier).markKnown();
      final CardsState after = container.read(cardsControllerProvider);
      expect(after.isEmpty, isTrue);
    });

    test('markKnown removes the card and excludes it', () async {
      final Unit alpha = await addWord(
        'alpha',
        due: initial.subtract(const Duration(days: 2)),
      );
      await addWord('beta', due: initial.subtract(const Duration(days: 1)));
      CardsState state = await refresh();
      expect(state.current?.text, 'alpha');

      await container.read(cardsControllerProvider.notifier).markKnown();

      state = container.read(cardsControllerProvider);
      expect(state.remaining, 1);
      expect(state.current?.text, 'beta');

      final Unit? marked = await container
          .read(unitRepositoryProvider)
          .getById(alpha.id);
      expect(marked?.knownManual, isTrue);

      // Marking the last card empties the queue.
      await container.read(cardsControllerProvider.notifier).markKnown();
      state = container.read(cardsControllerProvider);
      expect(state.isEmpty, isTrue);
      expect(state.current, isNull);
    });

    test('direction comes from the injected Random', () async {
      container.dispose();
      container = makeContainer(random: StubRandom([true]));
      await addWord('cow');
      CardsState state = await refresh();
      expect(state.direction, CardDirection.englishFirst);

      container.dispose();
      container = makeContainer(random: StubRandom([false]));
      // Same database, queue still has the word.
      state = await refresh();
      expect(state.direction, CardDirection.russianFirst);
    });
  });
}
