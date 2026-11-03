import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/theme.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/features/cards/cards_study_card.dart';
import 'package:parley/services/srs/srs_service.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 11, 3, 12);
  final SrsCard card = SrsService().newCard(now);

  Unit unit() => Unit(
    id: 1,
    text: 'extraordinary',
    textKey: 'extraordinary',
    forms: const <String>[],
    description: null,
    knownManual: false,
    phase: CardPhase.learning,
    due: now,
    stability: null,
    fsrsJson: card.toJson(),
    createdAt: now,
    lastReview: null,
  );

  Future<void> pumpCard(
    WidgetTester tester, {
    required double textScale,
  }) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildParleyTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: CardsStudyCard(
                unit: unit(),
                revealed: true,
                resolving: false,
                meaning: 'необыкновенный',
                busy: false,
                onReveal: () {},
                onRate: (_) {},
                onMarkKnown: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('ratings stay readable at 2x text scale', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, textScale: 2);

    expect(find.text('Again'), findsOneWidget);
    expect(find.text('Hard'), findsOneWidget);
    expect(find.text('Good'), findsOneWidget);
    expect(find.text('Easy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
