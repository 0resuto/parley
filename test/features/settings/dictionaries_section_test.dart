import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/dictionary/dictionary_importer.dart';
import 'package:parley/services/dictionary/import/import_worker.dart';
import 'package:parley/services/export/file_picker_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/stardict_fixture.dart';
import '../../helpers/temp_dictionary_file_store.dart';

class FakeDictionaryPicker implements FilePickerService {
  List<String>? nextFiles;
  Object? nextError;
  int dictionaryCalls = 0;
  Completer<List<String>?>? gate;

  @override
  Future<PickedJsonFile?> pickJsonFile() => throw UnimplementedError();

  @override
  Future<PickedCsvFile?> pickCsvFile() => throw UnimplementedError();

  @override
  Future<List<String>?> pickDictionaryFiles() async {
    dictionaryCalls++;
    final Completer<List<String>?>? blocker = gate;
    if (blocker != null) {
      return blocker.future;
    }
    if (nextError != null) {
      throw nextError!;
    }
    return nextFiles;
  }
}

/// Simulates the importer without real file I/O (which the fake-async
/// widget test zone cannot drive); the real importer is covered by
/// `test/services/dictionary/dictionary_importer_test.dart`.
class FakeImporter implements DictionaryImporter {
  FakeImporter(this.repo);

  final UserDictionaryRepository repo;
  String? nextPath;
  Object? nextError;
  int calls = 0;
  Completer<DictionaryImportSummary>? pending;
  bool cancelRequested = false;

  /// The `onProgress` callbacks the widget passed in, oldest first (A-49).
  final List<void Function(DictionaryImportProgress)> progressCallbacks = [];

  @override
  Future<DictionaryImportSummary> importFiles(
    List<String> paths, {
    required String targetLang,
    void Function(DictionaryImportProgress)? onProgress,
  }) {
    calls++;
    if (onProgress != null) {
      progressCallbacks.add(onProgress);
      onProgress(
        const DictionaryImportProgress(
          phase: ImportPhase.copying,
          fraction: 0.5,
        ),
      );
    }
    if (nextError != null) {
      return Future<DictionaryImportSummary>.error(nextError!);
    }
    final Completer<DictionaryImportSummary>? blocker = pending;
    if (blocker != null) {
      return blocker.future;
    }
    return _store(targetLang);
  }

  Future<DictionaryImportSummary> _store(String targetLang) async {
    const String name = 'Test Dictionary';
    await repo.add(
      name: name,
      path: nextPath ?? '',
      targetLang: targetLang,
      wordCount: 2,
    );
    return const DictionaryImportSummary(name: name, wordCount: 2);
  }

  @override
  void cancelImport() {
    cancelRequested = true;
    pending?.completeError(const DictionaryImportCancelledException());
  }
}

/// Blocks `setEnabled`/`move` until the test releases [gate], so the busy
/// state stays observable (A-49).
class GatedUserDictionaryRepository extends UserDictionaryRepository {
  GatedUserDictionaryRepository(
    super.db, {
    required super.clock,
    required super.files,
  });

  final Completer<void> gate = Completer<void>();
  int setEnabledCalls = 0;
  int moveCalls = 0;

  @override
  Future<void> setEnabled(int id, bool enabled) {
    setEnabledCalls++;
    return gate.future;
  }

  @override
  Future<void> move(int id, int delta) {
    moveCalls++;
    return gate.future;
  }
}

/// [UserDictionaryRepository] double whose [watchAll] always fails, to
/// exercise the section's error branch (T-19).
class FlakyUserDictionaryRepository extends UserDictionaryRepository {
  FlakyUserDictionaryRepository(
    super.db, {
    required super.clock,
    required super.files,
  });

  @override
  Stream<List<UserDictionary>> watchAll() =>
      Stream<List<UserDictionary>>.error(StateError('boom'));
}

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UserDictionaryRepository repo;
  late Directory tempDir;
  late Directory sourceDir;
  late FakeDictionaryPicker picker;
  late FakeImporter importer;
  int counter = 0;

  setUp(() async {
    // (T-20) Close streams synchronously so disposing the widget tree leaves
    // no drift timer pending; `unmount` and `db.close().timeout` are not
    // needed. Same pattern as `test/app_test.dart`.
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    tempDir = await Directory.systemTemp.createTemp('parley_section');
    repo = UserDictionaryRepository(
      db,
      clock: clock,
      files: TempDictionaryFileStore(tempDir),
    );
    sourceDir = Directory('${tempDir.path}/sources');
    await sourceDir.create(recursive: true);
    picker = FakeDictionaryPicker();
    importer = FakeImporter(repo);
  });

  tearDown(() async {
    await repo.dispose();
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows may still hold the files of an unfinished delete.
    }
  });

  /// Writes a StarDict fixture (real file I/O runs outside the fake zone).
  Future<String> makeFixtureDir(
    WidgetTester tester, {
    Map<String, String> entries = const {'cow': 'корова', 'bank': 'банк'},
  }) async {
    counter++;
    return (await tester.runAsync(() async {
      final Directory dir = Directory('${sourceDir.path}/d$counter');
      await dir.create(recursive: true);
      await writeStarDict(dir: dir, entries: entries);
      return dir.path;
    }))!;
  }

  Future<int> addDictionary(
    WidgetTester tester,
    String name, {
    Map<String, String> entries = const {'cow': 'корова'},
  }) async {
    final String path = await makeFixtureDir(tester, entries: entries);
    return repo.add(
      name: name,
      path: path,
      targetLang: 'ru',
      wordCount: entries.length,
    );
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    UserDictionaryRepository? repository,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
          userDictionaryRepositoryProvider.overrideWithValue(
            repository ?? repo,
          ),
          filePickerServiceProvider.overrideWithValue(picker),
          dictionaryImporterProvider.overrideWithValue(importer),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapImport(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('importDictionaryTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('importDictionaryTile')));
    await tester.pumpAndSettle();
  }

  group('DictionariesSection (5.12)', () {
    testWidgets('always shows the bundled dictionary row', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester);

      expect(find.text('Bundled English-Russian'), findsOneWidget);
      expect(find.text('Built-in · 129,797 words'), findsOneWidget);
      expect(find.text('No imported dictionaries yet.'), findsOneWidget);
    });

    testWidgets('lists the bundled dictionary after the user ones (A-67)', (
      WidgetTester tester,
    ) async {
      await addDictionary(tester, 'My words');
      await pumpSettings(tester);

      final double userDy = tester.getTopLeft(find.text('My words')).dy;
      final double bundledDy = tester
          .getTopLeft(find.byKey(const Key('bundledDictionaryTile')))
          .dy;
      final double importDy = tester
          .getTopLeft(find.byKey(const Key('importDictionaryTile')))
          .dy;

      expect(bundledDy, greaterThan(userDy));
      expect(importDy, greaterThan(bundledDy));
    });

    testWidgets('imports a StarDict dictionary and lists it', (
      WidgetTester tester,
    ) async {
      importer.nextPath = await makeFixtureDir(tester);
      picker.nextFiles = const ['x.ifo', 'x.idx', 'x.dict'];
      await pumpSettings(tester);

      await tapImport(tester);
      expect(find.text('Dictionary language'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dictionaryLanguageImport')));
      await tester.pumpAndSettle();

      expect(
        find.text('Imported "Test Dictionary" (2 words).'),
        findsOneWidget,
      );
      expect(find.text('Test Dictionary'), findsOneWidget);
      expect(find.text('ru · 2 words'), findsOneWidget);
      expect(find.text('No imported dictionaries yet.'), findsNothing);
      final String? meaning = await tester.runAsync(
        () async => (await repo.lookup('cow', targetLang: 'ru'))!.translation,
      );
      expect(meaning, 'корова');
    });

    testWidgets('the dialog language becomes the target language', (
      WidgetTester tester,
    ) async {
      importer.nextPath = await makeFixtureDir(tester);
      picker.nextFiles = const ['x.ifo', 'x.idx', 'x.dict'];
      await pumpSettings(tester);

      await tapImport(tester);
      await tester.enterText(
        find.byKey(const Key('dictionaryLanguageField')),
        'DE',
      );
      await tester.tap(find.byKey(const Key('dictionaryLanguageImport')));
      await tester.pumpAndSettle();

      expect(find.text('de · 2 words'), findsOneWidget);
      final bool resolvable = (await tester.runAsync(
        () async => await repo.lookup('cow', targetLang: 'de') != null,
      ))!;
      expect(resolvable, isTrue);
    });

    testWidgets('cancelling the language dialog imports nothing', (
      WidgetTester tester,
    ) async {
      picker.nextFiles = const ['x.ifo', 'x.idx', 'x.dict'];
      await pumpSettings(tester);

      await tapImport(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(importer.calls, 0);
      expect(find.text('No imported dictionaries yet.'), findsOneWidget);
    });

    testWidgets('an unusable selection shows the reason', (
      WidgetTester tester,
    ) async {
      importer.nextError = const DictionaryImportException(
        'Select the .ifo file of the dictionary.',
      );
      picker.nextFiles = const ['x.idx'];
      await pumpSettings(tester);

      await tapImport(tester);
      await tester.tap(find.byKey(const Key('dictionaryLanguageImport')));
      await tester.pumpAndSettle();

      expect(
        find.text('Select the .ifo file of the dictionary.'),
        findsOneWidget,
      );
    });

    testWidgets('an unreadable selection shows an error', (
      WidgetTester tester,
    ) async {
      picker.nextError = StateError('no access');
      await pumpSettings(tester);

      await tapImport(tester);

      expect(find.text('Could not read the file.'), findsOneWidget);
      expect(find.text('Dictionary language'), findsNothing);
    });

    testWidgets('a double tap opens only one picker (A-15)', (
      WidgetTester tester,
    ) async {
      picker.gate = Completer<List<String>?>();
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(const Key('importDictionaryTile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('importDictionaryTile')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('importDictionaryTile')));
      await tester.pump();

      expect(picker.dictionaryCalls, 1);

      picker.gate!.complete(null);
      await tester.pumpAndSettle();
    });

    testWidgets('a running import can be cancelled', (
      WidgetTester tester,
    ) async {
      importer.pending = Completer<DictionaryImportSummary>();
      picker.nextFiles = const ['x.ifo', 'x.idx', 'x.dict'];
      await pumpSettings(tester);

      await tapImport(tester);
      await tester.tap(find.byKey(const Key('dictionaryLanguageImport')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('importProgressLabel')), findsOneWidget);
      expect(find.byKey(const Key('importCancelButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('importCancelButton')));
      await tester.pumpAndSettle();

      expect(importer.cancelRequested, isTrue);
      expect(find.text('Import cancelled.'), findsOneWidget);
      expect(find.byKey(const Key('importCancelButton')), findsNothing);
    });

    testWidgets(
      'a straggler progress from a finished import is ignored (A-49)',
      (WidgetTester tester) async {
        importer.pending = Completer<DictionaryImportSummary>();
        picker.nextFiles = const ['x.ifo', 'x.idx', 'x.dict'];
        await pumpSettings(tester);

        // First import: start it and let it finish.
        await tapImport(tester);
        await tester.tap(find.byKey(const Key('dictionaryLanguageImport')));
        await tester.pumpAndSettle();
        expect(find.text('Copying files… 50%'), findsOneWidget);
        importer.pending!.complete(
          const DictionaryImportSummary(name: 'Test Dictionary', wordCount: 2),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('importProgressLabel')), findsNothing);
        // Let the success snackbar disappear so it cannot cover the tile.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();

        // Second import is running.
        importer.pending = Completer<DictionaryImportSummary>();
        await tapImport(tester);
        await tester.tap(find.byKey(const Key('dictionaryLanguageImport')));
        await tester.pumpAndSettle();
        expect(find.text('Copying files… 50%'), findsOneWidget);

        // The first import's callback fires late; it must not overwrite the
        // running import's progress.
        importer.progressCallbacks.first(
          const DictionaryImportProgress(
            phase: ImportPhase.indexing,
            fraction: 0.9,
          ),
        );
        await tester.pump();

        expect(find.text('Building index… 90%'), findsNothing);
        expect(find.text('Copying files… 50%'), findsOneWidget);

        importer.pending!.complete(
          const DictionaryImportSummary(name: 'Test Dictionary', wordCount: 2),
        );
        await tester.pumpAndSettle();
      },
    );

    testWidgets('the switch disables a dictionary', (
      WidgetTester tester,
    ) async {
      final int id = await addDictionary(tester, 'My words');
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(ValueKey('dictionarySwitch_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('dictionarySwitch_$id')));
      await tester.pumpAndSettle();

      // (T-20) Drift stream events are delivered on the real event loop; a
      // plain await never completes in the fake-async widget zone.
      final bool enabled = (await tester.runAsync(
        () async => (await repo.watchAll().first).single.enabled,
      ))!;
      expect(enabled, isFalse);
    });

    testWidgets('a double tap on the switch writes once (A-49)', (
      WidgetTester tester,
    ) async {
      final int id = await addDictionary(tester, 'My words');
      final GatedUserDictionaryRepository gated = GatedUserDictionaryRepository(
        db,
        clock: clock,
        files: TempDictionaryFileStore(tempDir),
      );
      await pumpSettings(tester, repository: gated);

      final Finder toggle = find.byKey(ValueKey('dictionarySwitch_$id'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();

      expect(gated.setEnabledCalls, 1);

      gated.gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('the arrows reorder the list', (WidgetTester tester) async {
      await addDictionary(tester, 'first');
      final int second = await addDictionary(
        tester,
        'second',
        entries: {'cow': 'бык'},
      );
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
        () async => (await repo.lookup('cow', targetLang: 'ru'))!.translation,
      );
      expect(meaning, 'бык');
    });

    testWidgets('a double tap on the arrows moves once (A-49)', (
      WidgetTester tester,
    ) async {
      final int id = await addDictionary(tester, 'My words');
      final GatedUserDictionaryRepository gated = GatedUserDictionaryRepository(
        db,
        clock: clock,
        files: TempDictionaryFileStore(tempDir),
      );
      await pumpSettings(tester, repository: gated);

      final Finder up = find.byKey(ValueKey('dictionaryUp_$id'));
      await tester.ensureVisible(up);
      await tester.pumpAndSettle();
      await tester.tap(up);
      await tester.pump();
      await tester.tap(up);
      await tester.pump();

      expect(gated.moveCalls, 1);

      gated.gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('remove asks for confirmation and removes', (
      WidgetTester tester,
    ) async {
      final int id = await addDictionary(tester, 'My words');
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
      // The file cleanup itself is covered by the repository tests.
      final bool removed = (await tester.runAsync(
        () async => (await repo.watchAll().first).isEmpty,
      ))!;
      expect(removed, isTrue);
    });

    testWidgets('cancel keeps the dictionary', (WidgetTester tester) async {
      final int id = await addDictionary(tester, 'My words');
      await pumpSettings(tester);

      await tester.ensureVisible(find.byKey(ValueKey('dictionaryRemove_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('dictionaryRemove_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('My words'), findsOneWidget);
      final bool kept = (await tester.runAsync(
        () async => (await repo.watchAll().first).isNotEmpty,
      ))!;
      expect(kept, isTrue);
    });

    testWidgets('a dictionaries stream error keeps import working (T-19)', (
      WidgetTester tester,
    ) async {
      final FlakyUserDictionaryRepository flaky = FlakyUserDictionaryRepository(
        db,
        clock: clock,
        files: TempDictionaryFileStore(tempDir),
      );
      importer.nextPath = await makeFixtureDir(tester);
      picker.nextFiles = const ['x.ifo', 'x.idx', 'x.dict'];
      await pumpSettings(tester, repository: flaky);

      expect(find.byKey(const Key('dictionariesError')), findsOneWidget);
      expect(
        find.text('Your dictionaries could not be loaded.'),
        findsOneWidget,
      );

      // The import tile is independent of the failed list stream.
      await tapImport(tester);
      expect(find.text('Dictionary language'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dictionaryLanguageImport')));
      await tester.pumpAndSettle();

      expect(
        find.text('Imported "Test Dictionary" (2 words).'),
        findsOneWidget,
      );
    });
  });
}
