import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/ui/state_views.dart';
import 'package:parley/data/models/unit.dart';
import 'cards_controller.dart';
import 'cards_study_card.dart';

/// Flashcards queue per SPEC 5.2.
///
/// Shows the remaining count, the current card (English word on the front,
/// the meaning resolved live on the back), a `Show answer` button, then the
/// four rating buttons. The overflow menu holds `Mark as known`. Empty queue
/// shows `All caught up.`. All actions go through [CardsController]; this
/// widget holds no business logic.
class CardsScreen extends ConsumerStatefulWidget {
  const CardsScreen({super.key});

  @override
  ConsumerState<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends ConsumerState<CardsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(cardsControllerProvider.notifier).refresh(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CardsState state = ref.watch(cardsControllerProvider);
    final CardsController controller = ref.read(
      cardsControllerProvider.notifier,
    );

    return Scaffold(
      // The shell owns the keyboard inset for tab screens.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('Cards'),
        actions: [
          if (state.undo != null)
            TextButton.icon(
              key: const Key('cardsUndoButton'),
              onPressed: state.busy ? null : controller.undoRating,
              icon: const Icon(Icons.undo_rounded, size: 18),
              label: const Text('Undo'),
            ),
        ],
      ),
      body: Builder(
        builder: (BuildContext context) {
          if (state.isLoading) {
            return const LoadingStateView();
          }
          final String? error = state.error;
          if (error != null) {
            return ErrorStateView(
              onRetry: controller.refresh,
              retryKey: const Key('cardsRetryButton'),
            );
          }
          final Unit? current = state.current;
          if (current == null) {
            return _caughtUpState(controller, ahead: state.ahead);
          }
          return _study(context, state, controller);
        },
      ),
    );
  }

  Widget _study(
    BuildContext context,
    CardsState state,
    CardsController controller,
  ) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 36).clamp(0, double.infinity),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _sessionHeader(
                  context,
                  state.remaining,
                  state.ahead,
                  controller,
                ),
                const SizedBox(height: 12),
                CardsStudyCard(
                  unit: state.current!,
                  revealed: state.revealed,
                  resolving: state.resolving,
                  meaning: state.meaning,
                  busy: state.busy,
                  onReveal: controller.reveal,
                  onRate: controller.rate,
                  onMarkKnown: controller.markKnown,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sessionHeader(
    BuildContext context,
    int remaining,
    bool ahead,
    CardsController controller,
  ) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (ahead)
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: Icon(Icons.fast_forward, size: 16, color: colors.primary),
          ),
        Text(
          ahead ? 'Review ahead' : 'Review session',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: ahead ? colors.primary : colors.onSurfaceVariant,
            fontWeight: ahead ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        const Spacer(),
        if (ahead)
          IconButton(
            key: const Key('cardsBackToDueHeader'),
            tooltip: 'Back to due cards',
            onPressed: controller.reviewDue,
            icon: const Icon(Icons.event_available),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
          ),
        const SizedBox(width: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$remaining left',
            key: const Key('cardsRemaining'),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.onPrimaryContainer,
            ),
          ),
        ),
      ],
    );
  }

  Widget _caughtUpState(CardsController controller, {required bool ahead}) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                ahead ? Icons.fast_forward : Icons.task_alt,
                size: 32,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              ahead ? 'No more cards ahead.' : 'All caught up.',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              ahead
                  ? 'You reached the end of the upcoming queue.'
                  : 'No cards are due right now.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            if (ahead)
              OutlinedButton.icon(
                key: const Key('cardsBackToDueEmpty'),
                onPressed: controller.reviewDue,
                icon: const Icon(Icons.event_available),
                label: const Text('Back to due cards'),
              )
            else
              FilledButton.tonalIcon(
                key: const Key('cardsReviewAhead'),
                onPressed: controller.reviewAhead,
                icon: const Icon(Icons.fast_forward),
                label: const Text('Review ahead'),
              ),
            const SizedBox(height: 4),
            TextButton.icon(
              key: const Key('cardsRefreshButton'),
              onPressed: controller.refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Check again'),
            ),
          ],
        ),
      ),
    );
  }
}
