import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/data/models/unit.dart';
import 'package:parley/services/srs/srs_service.dart';
import 'cards_controller.dart';

/// Flashcards queue per SPEC 5.2.
///
/// Shows the remaining count, the current card (English or Russian first
/// per [CardDirection]), a `Show answer` button, then the four rating
/// buttons. The overflow menu holds `Mark as known`. Empty queue shows
/// `All caught up.`. All actions go through [CardsController]; this widget
/// holds no business logic.
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
      appBar: AppBar(title: const Text('Cards')),
      body: Builder(
        builder: (BuildContext context) {
          if (state.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          final String? error = state.error;
          if (error != null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    key: const Key('cardsRetryButton'),
                    onPressed: controller.refresh,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          final Unit? current = state.current;
          if (current == null) {
            return const Center(child: Text('All caught up.'));
          }
          final String front = _frontText(current, state.direction);
          final String back = _backText(current, state.direction);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${state.remaining} left'),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              front,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            tooltip: 'More',
                            onSelected: (String value) {
                              if (value == 'markKnown') {
                                controller.markKnown();
                              }
                            },
                            itemBuilder: (BuildContext context) {
                              return const [
                                PopupMenuItem<String>(
                                  value: 'markKnown',
                                  child: Text('Mark as known'),
                                ),
                              ];
                            },
                          ),
                        ],
                      ),
                      if (state.revealed) ...[
                        const SizedBox(height: 12),
                        Text(
                          back,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (!state.revealed)
                        ElevatedButton(
                          onPressed: controller.reveal,
                          child: const Text('Show answer'),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _rateButton(controller, Rating.again, 'Again'),
                            _rateButton(controller, Rating.hard, 'Hard'),
                            _rateButton(controller, Rating.good, 'Good'),
                            _rateButton(controller, Rating.easy, 'Easy'),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _rateButton(CardsController controller, Rating rating, String label) {
    return ElevatedButton(
      onPressed: () => controller.rate(rating),
      child: Text(label),
    );
  }
}

/// Front side text for [direction].
String _frontText(Unit unit, CardDirection direction) {
  if (direction == CardDirection.englishFirst) {
    return unit.text;
  }
  if (unit.translationRu.isEmpty) {
    return '(no translation)';
  }
  return unit.translationRu;
}

/// Back side text (the other side) for [direction].
String _backText(Unit unit, CardDirection direction) {
  if (direction == CardDirection.englishFirst) {
    if (unit.translationRu.isEmpty) {
      return '(no translation)';
    }
    return unit.translationRu;
  }
  return unit.text;
}
