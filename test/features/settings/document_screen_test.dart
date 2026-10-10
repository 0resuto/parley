import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parley/features/settings/document_screen.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';

import '../../helpers/fake_clock.dart';

class _FakeLlmClient implements LlmClient {
  @override
  Future<String> complete(
    List<LlmMessage> messages, {
    double temperature = 0.2,
  }) async => 'ok';

  @override
  Stream<LlmEvent> streamChat(
    List<LlmMessage> messages, {
    List<Map<String, dynamic>>? tools,
    double temperature = 0.8,
  }) {
    throw UnimplementedError();
  }
}

Future<void> _pumpDocument(
  WidgetTester tester,
  DocumentStore store,
  DocumentKind kind,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [documentStoreProvider.overrideWithValue(store)],
      child: MaterialApp(home: DocumentScreen(kind: kind)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DocumentScreen (5.3)', () {
    testWidgets('view shows stored text with Edit and History', (
      WidgetTester tester,
    ) async {
      final MemoryDocumentStore store = MemoryDocumentStore(
        rules: 'my rules',
        clock: FakeClock(DateTime.utc(2026, 1, 10, 12)),
      );

      await _pumpDocument(tester, store, DocumentKind.rules);

      expect(find.text('Rules'), findsOneWidget);
      expect(find.text('my rules'), findsOneWidget);
      expect(find.byKey(const Key('documentEditButton')), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('No previous versions.'), findsOneWidget);
    });

    testWidgets('notes screen uses notes title and limit', (
      WidgetTester tester,
    ) async {
      final MemoryDocumentStore store = MemoryDocumentStore(
        notes: 'my notes',
        clock: FakeClock(DateTime.utc(2026, 1, 10, 12)),
      );

      await _pumpDocument(tester, store, DocumentKind.notes);

      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('my notes'), findsOneWidget);
    });

    testWidgets('edit and save writes the new text', (
      WidgetTester tester,
    ) async {
      final MemoryDocumentStore store = MemoryDocumentStore(
        rules: 'old rules',
        clock: FakeClock(DateTime.utc(2026, 1, 10, 12)),
      );

      await _pumpDocument(tester, store, DocumentKind.rules);

      await tester.tap(find.byKey(const Key('documentEditButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('documentEditField')), findsOneWidget);
      // 9 chars of 'old rules' against the 6000 rules limit.
      expect(find.text('9 / 6000'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('documentEditField')),
        'new rules',
      );
      await tester.pumpAndSettle();
      expect(find.text('9 / 6000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documentSaveButton')));
      await tester.pumpAndSettle();

      expect(find.text('new rules'), findsOneWidget);
      expect(await store.read(DocumentKind.rules), 'new rules');
      // Saving the seeded text versions it, so history appears.
      expect(find.text('No previous versions.'), findsNothing);
      expect(find.text('Restore'), findsOneWidget);
    });

    testWidgets('over-limit disables Save', (WidgetTester tester) async {
      final MemoryDocumentStore store = MemoryDocumentStore(
        rules: 'short',
        clock: FakeClock(DateTime.utc(2026, 1, 10, 12)),
      );

      await _pumpDocument(tester, store, DocumentKind.rules);

      await tester.tap(find.byKey(const Key('documentEditButton')));
      await tester.pumpAndSettle();

      final String tooLong = 'x' * 6001;
      await tester.enterText(
        find.byKey(const Key('documentEditField')),
        tooLong,
      );
      await tester.pumpAndSettle();

      expect(find.text('6001 / 6000'), findsOneWidget);
      final ElevatedButton save = tester.widget(
        find.byKey(const Key('documentSaveButton')),
      );
      expect(save.onPressed, isNull);
      expect(await store.read(DocumentKind.rules), 'short');
    });

    testWidgets('restore from history brings back the old text', (
      WidgetTester tester,
    ) async {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
      final MemoryDocumentStore store = MemoryDocumentStore(clock: clock);
      await store.write(DocumentKind.rules, 'v1');
      await store.write(DocumentKind.rules, 'v2');

      await _pumpDocument(tester, store, DocumentKind.rules);

      Text view = tester.widget(find.byKey(const Key('documentViewText')));
      expect(view.data, 'v2');
      expect(find.text('Restore'), findsOneWidget);

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      view = tester.widget(find.byKey(const Key('documentViewText')));
      expect(view.data, 'v1');
      expect(await store.read(DocumentKind.rules), 'v1');
    });

    testWidgets('settings tutor links open rules and notes', (
      WidgetTester tester,
    ) async {
      final MemoryDocumentStore store = MemoryDocumentStore(
        rules: 'rules text',
        notes: 'notes text',
        clock: FakeClock(DateTime.utc(2026, 1, 10, 12)),
      );
      final MemorySettingsRepository settings = MemorySettingsRepository(
        MemorySecureKeyStore(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            documentStoreProvider.overrideWithValue(store),
            settingsRepositoryProvider.overrideWithValue(settings),
            secureKeyStoreProvider.overrideWithValue(MemorySecureKeyStore()),
            llmClientProvider.overrideWithValue(_FakeLlmClient()),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Rules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rules'));
      await tester.pumpAndSettle();

      expect(find.byType(DocumentScreen), findsOneWidget);
      expect(find.text('rules text'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes'));
      await tester.pumpAndSettle();

      expect(find.byType(DocumentScreen), findsOneWidget);
      expect(find.text('notes text'), findsOneWidget);
    });
  });
}
