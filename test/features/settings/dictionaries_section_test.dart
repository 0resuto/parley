import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/export/file_picker_service.dart';

import '../../helpers/fake_clock.dart';

class FakeDictionaryPicker implements FilePickerService {
  PickedDictionaryFile? nextFile;
  Object? nextError;

  @override
  Future<PickedJsonFile?> pickJsonFile() => throw UnimplementedError();

  @override
  Future<PickedCsvFile?> pickCsvFile() => throw UnimplementedError();

  @override
  Future<PickedDictionaryFile?> pickDictionaryFile() async {
    if (nextError != null) {
      throw nextError!;
    }
    return nextFile;
  }
}

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UserDictionaryRepository repo;
  late FakeDictionaryPicker picker;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    repo = UserDictionaryRepository(db, clock: clock);
    picker = FakeDictionaryPicker();
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> importDict(String name, Map<String, String> entries) {
    return repo.importEntries(
      name: name,
      entries: [
        for (final MapEntry<String, String> e in entries.entries)
          (textKey: e.key, translation: e.value),
      ],
    );
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
          userDictionaryRepositoryProvider.overrideWithValue(repo),
          filePickerServiceProvider.overrideWithValue(picker),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Unmounts the tree so drift's stream-store close timer fires before the
  /// test ends (a pending timer would fail the test and hang `db.close()`).
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  }

  group('DictionariesSection (5.12)', () {
    testWidgets('imports a CSV dictionary and lists it', (
      WidgetTester tester,
    ) async {
      picker.nextFile = const PickedDictionaryFile(
        path: 'C:/tmp/My words.csv',
        isSqlite: false,
        csvContent: 'word;translation\ncow;корова\nbank;банк\n',
      );
      await pumpSettings(tester);

      expect(find.text('No imported dictionaries yet.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('importDictionaryTile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('importDictionaryTile')));
      await tester.pumpAndSettle();

      expect(find.text('Imported "My words" (2 words).'), findsOneWidget);
      expect(find.text('My words'), findsOneWidget);
      expect(find.text('2 words'), findsOneWidget);
      expect(find.text('No imported dictionaries yet.'), findsNothing);
      expect((await repo.lookup('cow'))!.translation, 'корова');
      await unmount(tester);
    });

    testWidgets('an unusable file shows the reason', (
      WidgetTester tester,
    ) async {
      picker.nextFile = const PickedDictionaryFile(
        path: 'C:/tmp/empty.csv',
        isSqlite: false,
        csvContent: 'word;translation\n',
      );
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(const Key('importDictionaryTile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('importDictionaryTile')));
      await tester.pumpAndSettle();

      expect(find.text('The file has no dictionary entries.'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an unreadable file shows an error', (
      WidgetTester tester,
    ) async {
      picker.nextError = StateError('no access');
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(const Key('importDictionaryTile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('importDictionaryTile')));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the file.'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the switch disables a dictionary', (
      WidgetTester tester,
    ) async {
      final int id = (await tester.runAsync(
        () => importDict('My words', {'cow': 'корова'}),
      ))!;
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(ValueKey('dictionarySwitch_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('dictionarySwitch_$id')));
      await tester.pumpAndSettle();

      final bool enabled = (await tester.runAsync(
        () async => (await repo.watchAll().first).single.enabled,
      ))!;
      expect(enabled, isFalse);
      await unmount(tester);
    });

    testWidgets('the arrows reorder the list', (WidgetTester tester) async {
      await tester.runAsync(() => importDict('first', {'cow': 'корова'}));
      final int second = (await tester.runAsync(
        () => importDict('second', {'cow': 'бык'}),
      ))!;
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(ValueKey('dictionaryUp_$second')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('dictionaryUp_$second')));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('second')).dy,
        lessThan(tester.getTopLeft(find.text('first')).dy),
      );
      final String? meaning = await tester.runAsync(
        () async => (await repo.lookup('cow'))!.translation,
      );
      expect(meaning, 'бык');
      await unmount(tester);
    });

    testWidgets('remove asks for confirmation and removes', (
      WidgetTester tester,
    ) async {
      final int id = (await tester.runAsync(
        () => importDict('My words', {'cow': 'корова'}),
      ))!;
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(ValueKey('dictionaryRemove_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('dictionaryRemove_$id')));
      await tester.pumpAndSettle();

      expect(find.text('Remove dictionary?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('My words'), findsNothing);
      expect(find.text('No imported dictionaries yet.'), findsOneWidget);
      final bool removed = (await tester.runAsync(
        () async => await repo.lookup('cow') == null,
      ))!;
      expect(removed, isTrue);
      await unmount(tester);
    });

    testWidgets('cancel keeps the dictionary', (WidgetTester tester) async {
      final int id = (await tester.runAsync(
        () => importDict('My words', {'cow': 'корова'}),
      ))!;
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(ValueKey('dictionaryRemove_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('dictionaryRemove_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('My words'), findsOneWidget);
      final bool kept = (await tester.runAsync(
        () async => await repo.lookup('cow') != null,
      ))!;
      expect(kept, isTrue);
      await unmount(tester);
    });
  });
}
