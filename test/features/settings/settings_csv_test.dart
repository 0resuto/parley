import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/export/csv_importer.dart';
import 'package:parley/services/export/export_service.dart';
import 'package:parley/services/export/file_picker_service.dart';
import 'package:parley/services/export/share_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_unit_repository.dart';

class FakeShareService implements ShareService {
  @override
  Future<void> shareJsonFile(String name, String json) async {}
}

class FakeFilePickerService implements FilePickerService {
  PickedJsonFile? nextJson;
  PickedCsvFile? nextCsv;
  Object? nextError;
  int csvCalls = 0;
  Completer<PickedCsvFile?>? gate;

  @override
  Future<PickedJsonFile?> pickJsonFile() async {
    if (nextError != null) {
      throw nextError!;
    }
    return nextJson;
  }

  @override
  Future<PickedCsvFile?> pickCsvFile() async {
    csvCalls++;
    final Completer<PickedCsvFile?>? blocker = gate;
    if (blocker != null) {
      return blocker.future;
    }
    if (nextError != null) {
      throw nextError!;
    }
    return nextCsv;
  }

  @override
  Future<List<String>?> pickDictionaryFiles() {
    throw UnimplementedError();
  }
}

void main() {
  late FakeClock clock;
  late FakeUnitRepository repo;
  late AppDatabase db;
  late MemoryDocumentStore docs;
  late ExportService service;
  late CsvImporter csvImporter;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    repo = FakeUnitRepository(clock: clock);
    // (T-20) Close streams synchronously so no drift timer stays pending;
    // same pattern as `test/app_test.dart`.
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    docs = MemoryDocumentStore();
    service = ExportService(
      database: db,
      units: repo,
      documents: docs,
      clock: clock,
    );
    csvImporter = CsvImporter(units: repo);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpSettings(
    WidgetTester tester,
    FakeFilePickerService picker,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(repo),
          clockProvider.overrideWithValue(clock),
          documentStoreProvider.overrideWithValue(docs),
          exportServiceProvider.overrideWithValue(service),
          csvImporterProvider.overrideWithValue(csvImporter),
          shareServiceProvider.overrideWithValue(FakeShareService()),
          filePickerServiceProvider.overrideWithValue(picker),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('SettingsScreen CSV import', () {
    testWidgets('import adds units and shows a summary', (
      WidgetTester tester,
    ) async {
      final picker = FakeFilePickerService()
        ..nextCsv = const PickedCsvFile(
          path: 'words.csv',
          content: 'word;translation\ncow;корова\nmilk;молоко',
        );
      await pumpSettings(tester, picker);

      await tester.ensureVisible(find.text('Import CSV'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import CSV'));
      await tester.pumpAndSettle();

      expect(find.text('Import finished'), findsOneWidget);
      expect(find.textContaining('Added: 2'), findsOneWidget);
      expect(find.textContaining('Skipped: 0'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(await repo.findByKey('cow'), isNotNull);
      expect(await repo.findByKey('milk'), isNotNull);
    });

    testWidgets('import cancel picks nothing and stays quiet', (
      WidgetTester tester,
    ) async {
      final picker = FakeFilePickerService()..nextCsv = null;
      await pumpSettings(tester, picker);

      await tester.ensureVisible(find.text('Import CSV'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import CSV'));
      await tester.pumpAndSettle();

      expect(find.text('Import finished'), findsNothing);
    });

    testWidgets('unreadable file shows an error', (WidgetTester tester) async {
      final picker = FakeFilePickerService()
        ..nextError = StateError('no access');
      await pumpSettings(tester, picker);

      await tester.ensureVisible(find.text('Import CSV'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import CSV'));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the file.'), findsOneWidget);
    });

    testWidgets('a double tap opens only one picker (A-15)', (
      WidgetTester tester,
    ) async {
      final picker = FakeFilePickerService()
        ..gate = Completer<PickedCsvFile?>();
      await pumpSettings(tester, picker);

      await tester.ensureVisible(find.text('Import CSV'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import CSV'));
      await tester.pump();
      await tester.tap(find.text('Import CSV'));
      await tester.pump();

      expect(picker.csvCalls, 1);

      picker.gate!.complete(null);
      await tester.pumpAndSettle();
    });
  });
}
