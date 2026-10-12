import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/features/dictionary/dictionary_edit_screen.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/srs/srs_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_unit_repository.dart';

/// [FakeUnitRepository] double whose Known toggle always fails (9.1).
class FailingKnownRepository extends FakeUnitRepository {
  FailingKnownRepository({required super.clock});

  @override
  Future<Unit?> setKnown(int id, bool known) async {
    throw StateError('db unavailable');
  }
}

/// [FakeUnitRepository] double whose delete always fails (9.1).
class FailingDeleteRepository extends FakeUnitRepository {
  FailingDeleteRepository({required super.clock});

  @override
  Future<void> delete(int id) async {
    throw StateError('db unavailable');
  }
}

/// [FakeUnitRepository] whose [findByKey] can be held open (A-29).
class GatedLookupRepository extends FakeUnitRepository {
  GatedLookupRepository({required super.clock});

  Completer<void>? gate;
  bool failAfterGate = false;

  @override
  Future<Unit?> findByKey(String query) async {
    final Completer<void>? blocker = gate;
    if (blocker != null) {
      await blocker.future;
    }
    if (failAfterGate) {
      throw StateError('db unavailable');
    }
    return super.findByKey(query);
  }
}

void main() {
  late FakeClock clock;
  late FakeUnitRepository repo;
  final DateTime initial = DateTime.utc(2026, 1, 10, 12);

  setUp(() {
    clock = FakeClock(initial);
    repo = FakeUnitRepository(clock: clock);
  });

  /// Pumps a host page with a button that opens the editor, so tests can
  /// verify the editor pops back on save and delete.
  Future<void> pumpHarness(WidgetTester tester, {int? unitId}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(repo),
          clockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (BuildContext context) {
                  return ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DictionaryEditScreen(unitId: unitId),
                        ),
                      );
                    },
                    child: const Text('Open editor'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();
  }

  group('DictionaryEditScreen', () {
    testWidgets('add creates a unit and closes the screen', (
      WidgetTester tester,
    ) async {
      await pumpHarness(tester);
      expect(find.text('Add word'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Cow');
      await save(tester);

      expect(find.text('Open editor'), findsOneWidget);
      final Unit? created = await repo.findByKey('cow');
      expect(created, isNotNull);
      expect(created!.text, 'Cow');
    });

    testWidgets('add shows an error when the word is empty', (
      WidgetTester tester,
    ) async {
      await pumpHarness(tester);

      await save(tester);

      expect(find.text('Enter a word'), findsOneWidget);
      expect(find.byType(DictionaryEditScreen), findsOneWidget);
      expect(await repo.findByKey('cow'), isNull);
    });

    testWidgets('add shows a duplicate error', (WidgetTester tester) async {
      await repo.add(text: 'Cow');
      await pumpHarness(tester);

      await tester.enterText(find.byType(TextField).first, '  COW  ');
      await save(tester);

      expect(
        find.text('This word is already in the dictionary.'),
        findsOneWidget,
      );
      expect(find.byType(DictionaryEditScreen), findsOneWidget);
      expect(find.text('Open editor'), findsNothing);
    });

    testWidgets('edit updates the unit and closes the screen', (
      WidgetTester tester,
    ) async {
      final Unit created = await repo.add(
        text: 'Cow',
        description: 'A farm animal',
      );
      await pumpHarness(tester, unitId: created.id);
      expect(find.text('Edit word'), findsOneWidget);

      // Existing values are shown, with dates and the description.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'Cow',
      );
      expect(find.textContaining('Added:'), findsOneWidget);
      expect(find.textContaining('Last review:'), findsOneWidget);
      expect(find.textContaining('Due:'), findsOneWidget);
      expect(find.text('A farm animal'), findsOneWidget);
      expect(find.text('I already know this'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Milk');
      await save(tester);

      expect(find.text('Open editor'), findsOneWidget);
      final Unit? updated = await repo.getById(created.id);
      expect(updated?.text, 'Milk');
    });

    testWidgets('edit shows a duplicate error for another unit', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');
      final Unit other = await repo.add(text: 'Milk');
      await pumpHarness(tester, unitId: other.id);

      await tester.enterText(find.byType(TextField).first, 'cow');
      await save(tester);

      expect(
        find.text('This word is already in the dictionary.'),
        findsOneWidget,
      );
      expect((await repo.getById(other.id))?.text, 'Milk');
    });

    testWidgets('a review during editing is not rolled back by save', (
      WidgetTester tester,
    ) async {
      final Unit created = await repo.add(text: 'Cow');
      await pumpHarness(tester, unitId: created.id);

      // A background review lands while the editor is open.
      await repo.update(
        created.copyWith(
          phase: CardPhase.review,
          stability: 42,
          fsrsJson: '{"reviewed":true}',
          due: initial.add(const Duration(days: 42)),
          lastReview: initial,
        ),
      );

      await tester.enterText(find.byType(TextField), 'Milk');
      await save(tester);

      final Unit? updated = await repo.getById(created.id);
      expect(updated?.text, 'Milk');
      expect(updated?.fsrsJson, '{"reviewed":true}');
      expect(updated?.stability, 42);
      expect(updated?.lastReview, initial);
      expect(updated?.phase, CardPhase.review);
    });

    testWidgets('known switch toggles the unit', (WidgetTester tester) async {
      final Unit created = await repo.add(text: 'Cow');
      await pumpHarness(tester, unitId: created.id);

      final Finder knownSwitch = find.byType(Switch);
      expect(knownSwitch, findsOneWidget);
      expect((await repo.getById(created.id))?.knownManual, isFalse);

      await tester.tap(knownSwitch);
      await tester.pumpAndSettle();
      expect((await repo.getById(created.id))?.knownManual, isTrue);
      expect(tester.widget<Switch>(knownSwitch).value, isTrue);
      expect(find.text('Edit word'), findsOneWidget);

      await tester.tap(knownSwitch);
      await tester.pumpAndSettle();
      expect((await repo.getById(created.id))?.knownManual, isFalse);
    });

    testWidgets('delete removes the unit after confirmation', (
      WidgetTester tester,
    ) async {
      final Unit created = await repo.add(text: 'Cow');
      await pumpHarness(tester, unitId: created.id);

      final Finder deleteButton = find.widgetWithText(
        OutlinedButton,
        'Delete word',
      );
      await tester.ensureVisible(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      expect(find.text('Delete this word?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await repo.getById(created.id), isNull);
      expect(find.text('Open editor'), findsOneWidget);
    });

    testWidgets('delete cancel keeps the unit', (WidgetTester tester) async {
      final Unit created = await repo.add(text: 'Cow');
      await pumpHarness(tester, unitId: created.id);

      final Finder deleteButton = find.widgetWithText(
        OutlinedButton,
        'Delete word',
      );
      await tester.ensureVisible(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await repo.getById(created.id), isNotNull);
      expect(find.text('Edit word'), findsOneWidget);
    });

    testWidgets('missing unit shows not found', (WidgetTester tester) async {
      await pumpHarness(tester, unitId: 999);

      expect(find.text('Word not found.'), findsOneWidget);
    });

    testWidgets('known toggle failure shows an error', (
      WidgetTester tester,
    ) async {
      final FailingKnownRepository failing = FailingKnownRepository(
        clock: clock,
      );
      final Unit created = await failing.add(text: 'Cow');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(failing),
            clockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(home: DictionaryEditScreen(unitId: created.id)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit word'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('Could not update.'), findsOneWidget);
      expect(find.text('Edit word'), findsOneWidget);
    });

    testWidgets('delete failure shows an error and stays open', (
      WidgetTester tester,
    ) async {
      final FailingDeleteRepository failing = FailingDeleteRepository(
        clock: clock,
      );
      final Unit created = await failing.add(text: 'Cow');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(failing),
            clockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(home: DictionaryEditScreen(unitId: created.id)),
        ),
      );
      await tester.pumpAndSettle();

      final Finder deleteButton = find.widgetWithText(
        OutlinedButton,
        'Delete word',
      );
      await tester.ensureVisible(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      expect(find.text('Delete this word?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Could not delete the word.'), findsOneWidget);
      expect(find.text('Edit word'), findsOneWidget);
    });

    testWidgets('add: a duplicate found after closing does not setState', (
      WidgetTester tester,
    ) async {
      final GatedLookupRepository gated = GatedLookupRepository(clock: clock);
      await gated.add(text: 'Cow');
      gated.gate = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(gated),
            clockProvider.overrideWithValue(clock),
          ],
          child: const MaterialApp(home: DictionaryEditScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'cow');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();

      // The screen is closed while the duplicate lookup is in flight.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      gated.gate!.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('add: a lookup error after closing does not setState', (
      WidgetTester tester,
    ) async {
      final GatedLookupRepository gated = GatedLookupRepository(clock: clock)
        ..gate = Completer<void>()
        ..failAfterGate = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(gated),
            clockProvider.overrideWithValue(clock),
          ],
          child: const MaterialApp(home: DictionaryEditScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'cow');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      gated.gate!.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('edit: a duplicate found after closing does not setState', (
      WidgetTester tester,
    ) async {
      final GatedLookupRepository gated = GatedLookupRepository(clock: clock);
      await gated.add(text: 'Cow');
      final Unit other = await gated.add(text: 'Milk');
      gated.gate = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(gated),
            clockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(home: DictionaryEditScreen(unitId: other.id)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'cow');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      gated.gate!.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('edit: a lookup error after closing does not setState', (
      WidgetTester tester,
    ) async {
      final GatedLookupRepository gated = GatedLookupRepository(clock: clock);
      final Unit created = await gated.add(text: 'Cow');
      gated
        ..gate = Completer<void>()
        ..failAfterGate = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitRepositoryProvider.overrideWithValue(gated),
            clockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(home: DictionaryEditScreen(unitId: created.id)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Milk');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      gated.gate!.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
