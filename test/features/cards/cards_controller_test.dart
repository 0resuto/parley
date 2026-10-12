import 'dart:async';

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
import '../../helpers/fake_dictionary_service.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late ProviderContainer container;
  final DateTime initial = DateTime.utc(2026, 2, 1, 12);

  ProviderContainer makeContainer({FakeDictionaryService? dictionary}) {
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        if (dictionary != null)
          dictionaryServiceProvider.overrideWithValue(dictionary),
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

      await container.read(cardsControllerProvider.notifier).reveal();
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

    test('a second rate while the first is in flight is ignored', () async {
      await addWord('cow');
      await refresh();

      final CardsController controller = container.read(
        cardsControllerProvider.notifier,
      );
      final Future<void> first = controller.rate(Rating.good);
      final Future<void> second = controller.rate(Rating.good);
      await Future.wait([first, second]);

      expect(await db.select(db.reviews).get(), hasLength(1));
      expect(container.read(cardsControllerProvider).isEmpty, isTrue);
    });

    test('rate is ignored while the meaning is still resolving', () async {
      container.dispose();
      final FakeDictionaryService dictionary = FakeDictionaryService({
        'cow': 'корова',
      });
      dictionary.gate = Completer<void>();
      container = makeContainer(dictionary: dictionary);
      await addWord('cow');
      await refresh();

      final CardsController controller = container.read(
        cardsControllerProvider.notifier,
      );
      final Future<void> revealFuture = controller.reveal();
      expect(container.read(cardsControllerProvider).resolving, isTrue);

      await controller.rate(Rating.good);

      expect(container.read(cardsControllerProvider).current?.text, 'cow');
      expect(await db.select(db.reviews).get(), isEmpty);

      dictionary.gate!.complete();
      await revealFuture;
      expect(container.read(cardsControllerProvider).meaning, 'корова');
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

    test('reveal resolves the meaning from the bundled dictionary', () async {
      container.dispose();
      container = makeContainer(
        dictionary: FakeDictionaryService({'cow': 'корова'}),
      );
      await addWord('cow');
      await refresh();

      await container.read(cardsControllerProvider.notifier).reveal();

      final CardsState state = container.read(cardsControllerProvider);
      expect(state.revealed, isTrue);
      expect(state.resolving, isFalse);
      expect(state.meaning, 'корова');
    });

    test('reveal without a source leaves the meaning empty', () async {
      await addWord('cow');
      await refresh();

      await container.read(cardsControllerProvider.notifier).reveal();

      final CardsState state = container.read(cardsControllerProvider);
      expect(state.revealed, isTrue);
      expect(state.meaning, isNull);
    });
  });
}
