import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

/// Cards queue state (PLAN 3.1, PLAN 19.1).
///
/// [queue] is non-Known units with `due <= now`, oldest due first.
/// [current] is the first queue item (or null when empty).
/// [meaning] is the current card's meaning resolved live from the active
/// sources (null until resolved); cards show the English word first and
/// reveal this meaning.
/// [error] is non-null when the queue could not be loaded or an action
/// failed; the screen shows it with a Retry button (PLAN 9.1).
/// [busy] is true while a rating or mark-known action is in flight; the
/// screen disables the actions until it finishes.
class CardsState {
  const CardsState({
    required this.queue,
    required this.revealed,
    required this.meaning,
    required this.resolving,
    required this.isLoading,
    this.busy = false,
    this.error,
  });

  const CardsState.initial()
    : queue = const [],
      revealed = false,
      meaning = null,
      resolving = false,
      isLoading = true,
      busy = false,
      error = null;

  final List<Unit> queue;
  final bool revealed;
  final String? meaning;
  final bool resolving;
  final bool isLoading;
  final bool busy;

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
    String? meaning,
    bool? resolving,
    bool? isLoading,
    bool? busy,
    String? error,
    bool clearError = false,
  }) {
    return CardsState(
      queue: queue ?? this.queue,
      revealed: revealed ?? this.revealed,
      meaning: meaning ?? this.meaning,
      resolving: resolving ?? this.resolving,
      isLoading: isLoading ?? this.isLoading,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

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
/// [reveal] shows the answer and resolves the meaning. [rate] reviews
/// through [ReviewService] with source `card`. [markKnown] excludes the
/// card via `setKnown`. After [rate], [markKnown] and [refresh] the queue
/// is re-read and [revealed] resets to false.
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
    try {
      final List<Unit> queue = await units.dueQueue(clock.now());
      if (!ref.mounted) {
        return;
      }
      state = CardsState(
        queue: queue,
        revealed: false,
        meaning: null,
        resolving: false,
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
  ///
  /// The meaning is resolved live (bundle first, then the LLM when online);
  /// the back side shows a spinner until it lands (PLAN 19.1).
  Future<void> reveal() async {
    final Unit? current = state.current;
    if (current == null || state.isLoading || state.revealed) {
      return;
    }
    state = state.copyWith(revealed: true, resolving: true);
    String? meaning;
    try {
      meaning = await ref
          .read(meaningResolverProvider)
          .resolve(current.textKey);
    } catch (_) {
      meaning = null;
    }
    if (!ref.mounted || state.current?.id != current.id) {
      return;
    }
    state = state.copyWith(meaning: meaning, resolving: false);
  }

  /// Rates the current card and moves to the next one.
  ///
  /// Ignored while the answer is still resolving (the meaning must be shown
  /// first, SPEC 5.2) and while another action is in flight.
  /// Failures are exposed as [CardsState.error] instead of throwing
  /// (PLAN 9.1); the screen shows a Retry button.
  Future<void> rate(Rating rating) async {
    final Unit? current = state.current;
    if (current == null || state.resolving || state.busy) {
      return;
    }
    state = state.copyWith(busy: true);
    try {
      await ref
          .read(reviewServiceProvider)
          .rate(current.id, rating, ReviewSource.card);
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: 'Something went wrong.', busy: false);
      return;
    }
    await refresh();
  }

  /// Marks the current card as known and moves to the next one.
  ///
  /// Ignored while another action is in flight. Failures are exposed as
  /// [CardsState.error] instead of throwing (PLAN 9.1).
  Future<void> markKnown() async {
    final Unit? current = state.current;
    if (current == null || state.busy) {
      return;
    }
    state = state.copyWith(busy: true);
    try {
      await ref.read(unitRepositoryProvider).setKnown(current.id, true);
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: 'Something went wrong.', busy: false);
      return;
    }
    await refresh();
  }
}

/// Provider for the cards queue controller.
final cardsControllerProvider = NotifierProvider<CardsController, CardsState>(
  CardsController.new,
);
