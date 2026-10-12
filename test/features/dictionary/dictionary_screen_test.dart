import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/features/dictionary/dictionary_edit_screen.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/dictionary/dictionary_screen.dart';
import 'package:parley/services/dictionary/user_dictionary_lookup.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_dictionary_service.dart';
import '../../helpers/fake_unit_repository.dart';

/// Fails [watchAll] until [fail] is cleared, to exercise Retry (A-50).
class FlakyUnitRepository extends FakeUnitRepository {
  FlakyUnitRepository({required super.clock});

  bool fail = true;

  @override
  Stream<List<Unit>> watchAll({UnitStatus? status, String? query}) {
    if (fail) {
      return Stream<List<Unit>>.error(StateError('boom'));
    }
    return super.watchAll(status: status, query: query);
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

  Future<void> pumpDictionary(
    WidgetTester tester, {
    FakeDictionaryService? dictionary,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(repo),
          clockProvider.overrideWithValue(clock),
          dictionaryServiceProvider.overrideWithValue(
            dictionary ??
                FakeDictionaryService({'cow': 'корова', 'milk': 'молоко'}),
          ),
          userDictionaryLookupProvider.overrideWithValue(
            const EmptyUserDictionaryLookup(),
          ),
        ],
        child: const MaterialApp(home: DictionaryScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('DictionaryScreen', () {
    testWidgets('lists items with the resolved meaning, status chip and due', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');
      await repo.add(text: 'Milk');

      await pumpDictionary(tester);

      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('корова'), findsOneWidget);
      expect(find.text('молоко'), findsOneWidget);
      // New units are due now; each row shows the status chip.
      expect(find.text('Due now'), findsNWidgets(2));
      expect(find.widgetWithText(Chip, 'New'), findsNWidgets(2));
      expect(find.text('Search dictionary'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
    });

    testWidgets('shows the transcription when the source provides one', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');

      await pumpDictionary(
        tester,
        dictionary: FakeDictionaryService.withDetails(
          entries: {'cow': 'корова'},
          transcriptions: {'cow': 'kaʊ'},
        ),
      );

      expect(find.text('корова'), findsOneWidget);
      expect(find.byKey(const Key('wordMeaningTranscription')), findsOneWidget);
      expect(find.text('kaʊ'), findsOneWidget);
    });

    testWidgets('search filters the list', (WidgetTester tester) async {
      await repo.add(text: 'Cow');
      await repo.add(text: 'Milk');

      await pumpDictionary(tester);
      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'milk');
      await tester.pumpAndSettle();

      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('Cow'), findsNothing);
    });

    testWidgets('status chips filter the list', (WidgetTester tester) async {
      final Unit cow = await repo.add(text: 'Cow');
      final Unit milk = await repo.add(text: 'Milk');
      await repo.setKnown(milk.id, true);
      expect((await repo.getById(cow.id))!, isNotNull);
      expect(statusOf((await repo.getById(cow.id))!), UnitStatus.newUnit);

      await pumpDictionary(tester);
      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Known'));
      await tester.pumpAndSettle();

      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('Cow'), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, 'New'));
      await tester.pumpAndSettle();

      expect(find.text('Cow'), findsOneWidget);
      expect(find.text('Milk'), findsNothing);
    });

    testWidgets('empty dictionary shows empty state', (
      WidgetTester tester,
    ) async {
      await pumpDictionary(tester);

      expect(find.textContaining('Your dictionary is empty'), findsOneWidget);
      expect(find.text('Cow'), findsNothing);
    });

    testWidgets('no matches show not-found state', (WidgetTester tester) async {
      await repo.add(text: 'Cow');

      await pumpDictionary(tester);
      await tester.enterText(find.byType(TextField), 'zzz-no-match');
      await tester.pumpAndSettle();

      expect(find.text('No words found'), findsOneWidget);
      expect(find.text('Cow'), findsNothing);
    });

    testWidgets('FAB opens the add screen', (WidgetTester tester) async {
      await pumpDictionary(tester);

      await tester.tap(find.byTooltip('Add word'));
      await tester.pumpAndSettle();

      expect(find.byType(DictionaryEditScreen), findsOneWidget);
      expect(find.text('Add word'), findsWidgets);
    });

    testWidgets('a stream error offers Retry and recovers (A-50)', (
      WidgetTester tester,
    ) async {
      final FlakyUnitRepository flaky = FlakyUnitRepository(clock: clock);
      repo = flaky;
      await repo.add(text: 'Cow');

      await pumpDictionary(tester);

      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(find.byKey(const Key('dictionaryRetry')), findsOneWidget);
      expect(find.text('Cow'), findsNothing);

      flaky.fail = false;
      await tester.tap(find.byKey(const Key('dictionaryRetry')));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsNothing);
      expect(find.text('Cow'), findsOneWidget);
    });

    testWidgets('relative due labels refresh as time passes (A-50)', (
      WidgetTester tester,
    ) async {
      await repo.add(text: 'Cow');
      await pumpDictionary(tester);
      expect(find.text('Due now'), findsOneWidget);

      clock.advance(const Duration(minutes: 5));
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      expect(find.text('Due now'), findsNothing);
      expect(find.text('Overdue by 5 mins'), findsOneWidget);
    });
  });
}
