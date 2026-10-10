import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/export/export_service.dart';
import 'package:parley/services/export/file_picker_service.dart';
import 'package:parley/services/export/share_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_unit_repository.dart';

class FakeShareService implements ShareService {
  String? fileName;
  String? content;

  @override
  Future<void> shareJsonFile(String name, String json) async {
    fileName = name;
    content = json;
  }
}

class FakeFilePickerService implements FilePickerService {
  PickedJsonFile? nextFile;
  Object? nextError;

  @override
  Future<PickedJsonFile?> pickJsonFile() async {
    if (nextError != null) {
      throw nextError!;
    }
    return nextFile;
  }

  @override
  Future<PickedCsvFile?> pickCsvFile() async {
    throw UnimplementedError();
  }
}

void main() {
  late FakeClock clock;
  late FakeUnitRepository repo;
  late AppDatabase db;
  late MemoryDocumentStore docs;
  late FakeShareService share;
  late FakeFilePickerService picker;
  late ExportService service;
  final DateTime initial = DateTime.utc(2026, 1, 10, 12);

  setUp(() {
    clock = FakeClock(initial);
    repo = FakeUnitRepository(clock: clock);
    db = AppDatabase(NativeDatabase.memory());
    docs = MemoryDocumentStore();
    share = FakeShareService();
    picker = FakeFilePickerService();
    service = ExportService(
      database: db,
      units: repo,
      documents: docs,
      clock: clock,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(repo),
          clockProvider.overrideWithValue(clock),
          documentStoreProvider.overrideWithValue(docs),
          exportServiceProvider.overrideWithValue(service),
          shareServiceProvider.overrideWithValue(share),
          filePickerServiceProvider.overrideWithValue(picker),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Builds a valid export payload from a separate in-memory repository
  /// sharing the same database (no file system involved).
  Future<String> buildPayload() async {
    final FakeUnitRepository otherRepo = FakeUnitRepository(clock: clock);
    final MemoryDocumentStore otherDocs = MemoryDocumentStore(
      rules: '# Exported rules',
      notes: '# Exported notes',
    );
    await otherRepo.add(text: 'Cow');
    return ExportService(
      database: db,
      units: otherRepo,
      documents: otherDocs,
      clock: clock,
    ).exportJson();
  }

  group('SettingsScreen Data', () {
    testWidgets('export shares a backup file', (WidgetTester tester) async {
      await repo.add(text: 'Cow');
      await pumpSettings(tester);

      await tester.ensureVisible(find.text('Export JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export JSON'));
      await tester.pumpAndSettle();

      expect(share.fileName, 'parley-export-20260110.json');
      final Map<String, dynamic> doc =
          jsonDecode(share.content!) as Map<String, dynamic>;
      expect(doc['format'], 'parley-export');
      expect((doc['units'] as List), hasLength(1));
    });

    testWidgets('import adds units and shows a summary', (
      WidgetTester tester,
    ) async {
      picker.nextFile = PickedJsonFile(
        path: 'backup.json',
        content: await buildPayload(),
      );
      await pumpSettings(tester);

      await tester.ensureVisible(find.text('Import JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import JSON'));
      await tester.pumpAndSettle();
      expect(find.text('Overwrite existing'), findsOneWidget);
      expect(find.text('Replace rules and notes'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Import'));
      await tester.pumpAndSettle();

      expect(find.text('Import finished'), findsOneWidget);
      expect(find.textContaining('Added: 1'), findsOneWidget);
      // Docs stay untouched by default.
      expect(await docs.read(DocumentKind.rules), '');

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(await repo.findByKey('cow'), isNotNull);
    });

    testWidgets('import cancel picks nothing and stays quiet', (
      WidgetTester tester,
    ) async {
      picker.nextFile = null;
      await pumpSettings(tester);

      await tester.ensureVisible(find.text('Import JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import JSON'));
      await tester.pumpAndSettle();

      expect(find.text('Overwrite existing'), findsNothing);
    });

    testWidgets('unreadable file shows an error', (WidgetTester tester) async {
      picker.nextError = StateError('no access');
      await pumpSettings(tester);

      await tester.ensureVisible(find.text('Import JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import JSON'));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the file.'), findsOneWidget);
    });

    testWidgets('invalid file shows an error', (WidgetTester tester) async {
      picker.nextFile = const PickedJsonFile(
        path: 'bad.json',
        content: 'not json {',
      );
      await pumpSettings(tester);

      await tester.ensureVisible(find.text('Import JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Import'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid export file.'), findsOneWidget);
    });
  });
}
