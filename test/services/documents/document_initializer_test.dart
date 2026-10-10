import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/documents/document_initializer.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/documents/file_document_store.dart';

import '../../helpers/fake_clock.dart';

class FakeTemplates implements TemplateLoader {
  FakeTemplates(this.texts);

  final Map<DocumentKind, String> texts;
  int loads = 0;

  @override
  Future<String> load(DocumentKind kind) async {
    loads++;
    return texts[kind] ?? '';
  }
}

void main() {
  final DateTime initial = DateTime.utc(2026, 1, 10, 12);
  Map<DocumentKind, String> templates() => {
    DocumentKind.rules: '# rules template',
    DocumentKind.notes: '# notes template',
  };

  group('ensureDefaultDocuments with MemoryDocumentStore', () {
    test('first run copies both templates with no versions', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));
      final loader = FakeTemplates(templates());

      await ensureDefaultDocuments(store: store, templates: loader);

      expect(await store.read(DocumentKind.rules), '# rules template');
      expect(await store.read(DocumentKind.notes), '# notes template');
      expect(await store.versions(DocumentKind.rules), isEmpty);
      expect(await store.versions(DocumentKind.notes), isEmpty);
    });

    test('second run does not overwrite edited content', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));
      final loader = FakeTemplates(templates());

      await ensureDefaultDocuments(store: store, templates: loader);
      await store.write(DocumentKind.rules, 'edited rules');
      await store.write(DocumentKind.notes, 'edited notes');
      final int loadsAfterEdit = loader.loads;

      await ensureDefaultDocuments(store: store, templates: loader);

      expect(await store.read(DocumentKind.rules), 'edited rules');
      expect(await store.read(DocumentKind.notes), 'edited notes');
      // No extra loads: existing docs are left alone.
      expect(loader.loads, loadsAfterEdit);
    });

    test('only the missing kind is copied', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));
      await store.write(DocumentKind.rules, 'my rules');
      final loader = FakeTemplates(templates());

      await ensureDefaultDocuments(store: store, templates: loader);

      expect(await store.read(DocumentKind.rules), 'my rules');
      expect(await store.read(DocumentKind.notes), '# notes template');
      expect(await store.versions(DocumentKind.rules), isEmpty);
      expect(await store.versions(DocumentKind.notes), isEmpty);
    });
  });

  group('ensureDefaultDocuments with FileDocumentStore', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('parley_init_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // Best effort cleanup.
      }
    });

    test('first run copies, second run keeps edits', () async {
      final store = FileDocumentStore(baseDir: tmp, clock: FakeClock(initial));
      final loader = FakeTemplates(templates());

      await ensureDefaultDocuments(store: store, templates: loader);
      expect(await store.read(DocumentKind.rules), '# rules template');
      expect(await store.read(DocumentKind.notes), '# notes template');

      await store.write(DocumentKind.rules, 'edited rules');
      await ensureDefaultDocuments(store: store, templates: loader);
      expect(await store.read(DocumentKind.rules), 'edited rules');
      expect(await store.read(DocumentKind.notes), '# notes template');
    });
  });
}
