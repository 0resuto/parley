import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

/// Which side of the card shows first (SPEC 5.2, random 50/50).
enum CardDirection {
  /// English text first, Russian after reveal.
  englishFirst,

  /// Russian translation first, English after reveal.
  russianFirst,
}

/// Cards queue state (PLAN 3.1).
///
/// [queue] is non-Known units with `due <= now`, oldest due first.
/// [current] is the first queue item (or null when empty).
/// [error] is non-null when the queue could not be loaded or an action
/// failed; the screen shows it with a Retry button (PLAN 9.1).
class CardsState {
  const CardsState({
    required this.queue,
    required this.revealed,
    required this.direction,
    required this.isLoading,
    this.error,
  });

  const CardsState.initial()
    : queue = const [],
      revealed = false,
      direction = CardDirection.englishFirst,
      isLoading = true,
      error = null;

  final List<Unit> queue;
  final bool revealed;
  final CardDirection direction;
  final bool isLoading;

  /// English error text shown with a Retry button (null when none).
  final String? error;

  /// Current card (first in queue) or null when the queue is empty.
  Unit? get current => queue.isEmpty ? null : queue.first;

  /// Number of cards left in the queue.
  int get remaining => queue.length;

  /// True when there is nothing to review.
  bool get isEmpty => queue.isEmpty;

  CardsState copyWith({
    List<Unit>? queue,
    bool? revealed,
    CardDirection? direction,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return CardsState(
      queue: queue ?? this.queue,
      revealed: revealed ?? this.revealed,
      direction: direction ?? this.direction,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Injectable randomness for the card direction (50/50).
///
/// Tests override this with a seeded or stub [Random].
final randomProvider = Provider<Random>((ref) => Random());

/// Applies FSRS reviews for the cards queue (source `card`).
final reviewServiceProvider = Provider<ReviewService>((ref) {
  return ReviewService(
    ref.watch(appDatabaseProvider),
    units: ref.watch(unitRepositoryProvider),
    clock: ref.watch(clockProvider),
  );
});

/// Cards queue controller (PLAN 3.1, SPEC 5.2).
///
/// Call [refresh] after creation (the cards screen does this on init).
/// [reveal] shows the answer. [rate] reviews through [ReviewService] with
/// source `card`. [markKnown] excludes the card via `setKnown`.
/// After [rate], [markKnown] and [refresh] the queue is re-read and
/// [revealed] resets to false with a fresh [direction].
class CardsController extends Notifier<CardsState> {
  @override
  CardsState build() {
    return const CardsState.initial();
  }

  /// Re-reads the due queue from the repository.
  ///
  /// Failures leave an [CardsState.error] message with a Retry button
  /// instead of hanging on the spinner (PLAN 9.1).
  Future<void> refresh() async {
    final UnitRepository units = ref.read(unitRepositoryProvider);
    final Clock clock = ref.read(clockProvider);
    final Random random = ref.read(randomProvider);
    try {
      final List<Unit> queue = await units.dueQueue(clock.now());
      if (!ref.mounted) {
        return;
      }
      state = CardsState(
        queue: queue,
        revealed: false,
        direction: queue.isEmpty ? state.direction : _pickDirection(random),
        isLoading: false,
      );
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(isLoading: false, error: 'Something went wrong.');
    }
  }

  /// Shows the answer side of the current card.
  void reveal() {
    if (state.isLoading || state.revealed || state.queue.isEmpty) {
      return;
    }
    state = state.copyWith(revealed: true);
  }

  /// Rates the current card and moves to the next one.
  ///
  /// Failures are exposed as [CardsState.error] instead of throwing
  /// (PLAN 9.1); the screen shows a Retry button.
  Future<void> rate(Rating rating) async {
    final Unit? current = state.current;
    if (current == null) {
      return;
    }
    try {
      await ref
          .read(reviewServiceProvider)
          .rate(current.id, rating, ReviewSource.card);
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: 'Something went wrong.');
      return;
    }
    await refresh();
  }

  /// Marks the current card as known and moves to the next one.
  ///
  /// Failures are exposed as [CardsState.error] instead of throwing
  /// (PLAN 9.1).
  Future<void> markKnown() async {
    final Unit? current = state.current;
    if (current == null) {
      return;
    }
    try {
      await ref.read(unitRepositoryProvider).setKnown(current.id, true);
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: 'Something went wrong.');
      return;
    }
    await refresh();
  }

  CardDirection _pickDirection(Random random) {
    return random.nextBool()
        ? CardDirection.englishFirst
        : CardDirection.russianFirst;
  }
}

/// Provider for the cards queue controller.
final cardsControllerProvider = NotifierProvider<CardsController, CardsState>(
  CardsController.new,
);
