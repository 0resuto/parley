import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/documents/file_document_store.dart';

import '../../helpers/fake_clock.dart';

void main() {
  final DateTime initial = DateTime.utc(2026, 1, 10, 12);

  group('MemoryDocumentStore', () {
    test('fresh store reads empty with no versions', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));

      expect(await store.read(DocumentKind.rules), '');
      expect(await store.versions(DocumentKind.rules), isEmpty);
    });

    test('limits match SPEC 4.4', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));

      expect(store.limitFor(DocumentKind.rules), rulesLimit);
      expect(store.limitFor(DocumentKind.notes), notesLimit);
      expect(rulesLimit, 6000);
      expect(notesLimit, 8000);
    });

    test('second write versions the first text', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));

      await store.write(DocumentKind.rules, 'v1');
      expect(await store.versions(DocumentKind.rules), isEmpty);

      await store.write(DocumentKind.rules, 'v2');
      final versions = await store.versions(DocumentKind.rules);
      expect(versions, hasLength(1));
      expect(versions.single.text, 'v1');
      expect(await store.read(DocumentKind.rules), 'v2');
    });

    test('seeded content is versioned on first write', () async {
      final store = MemoryDocumentStore(
        rules: 'template',
        clock: FakeClock(initial),
      );

      await store.write(DocumentKind.rules, 'edited');
      final versions = await store.versions(DocumentKind.rules);
      expect(versions, hasLength(1));
      expect(versions.single.text, 'template');
    });

    test('only the last 20 versions are kept', () async {
      final clock = FakeClock(initial);
      final store = MemoryDocumentStore(clock: clock);

      await store.write(DocumentKind.notes, 'v0');
      for (int i = 1; i <= 25; i++) {
        clock.advance(const Duration(seconds: 1));
        await store.write(DocumentKind.notes, 'v$i');
      }

      final versions = await store.versions(DocumentKind.notes);
      expect(versions, hasLength(historyVersionsKept));
      expect(versions.first.text, 'v24');
      expect(versions.last.text, 'v5');
    });

    test('restore works and is itself undoable', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));

      await store.write(DocumentKind.rules, 'v1');
      await store.write(DocumentKind.rules, 'v2');
      final String v1id = (await store.versions(DocumentKind.rules)).single.id;

      await store.restore(DocumentKind.rules, v1id);
      expect(await store.read(DocumentKind.rules), 'v1');

      final after = await store.versions(DocumentKind.rules);
      expect(after, hasLength(2));
      expect(after.first.text, 'v2');

      await store.restore(DocumentKind.rules, after.first.id);
      expect(await store.read(DocumentKind.rules), 'v2');
    });

    test('restore of a missing version throws', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));

      await expectLater(
        store.restore(DocumentKind.rules, 'rules_1.md'),
        throwsArgumentError,
      );
    });

    test('same-clock writes get unique ids', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));

      await store.write(DocumentKind.rules, 'v1');
      await store.write(DocumentKind.rules, 'v2');
      await store.write(DocumentKind.rules, 'v3');

      final ids = (await store.versions(
        DocumentKind.rules,
      )).map((v) => v.id).toSet();
      expect(ids, hasLength(2));
    });

    test('kinds are versioned separately', () async {
      final store = MemoryDocumentStore(clock: FakeClock(initial));

      await store.write(DocumentKind.rules, 'r1');
      await store.write(DocumentKind.notes, 'n1');
      await store.write(DocumentKind.rules, 'r2');

      expect((await store.versions(DocumentKind.rules)), hasLength(1));
      expect((await store.versions(DocumentKind.notes)), isEmpty);
    });
  });

  group('FileDocumentStore', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('parley_docs_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // Best effort cleanup.
      }
    });

    FileDocumentStore store(FakeClock clock) =>
        FileDocumentStore(baseDir: tmp, clock: clock);

    test('fresh store reads empty with no versions', () async {
      final s = store(FakeClock(initial));

      expect(await s.read(DocumentKind.rules), '');
      expect(await s.versions(DocumentKind.rules), isEmpty);
    });

    test('limits match SPEC 4.4', () async {
      final s = store(FakeClock(initial));

      expect(s.limitFor(DocumentKind.rules), rulesLimit);
      expect(s.limitFor(DocumentKind.notes), notesLimit);
    });

    test('second write versions the first text', () async {
      final s = store(FakeClock(initial));

      await s.write(DocumentKind.rules, 'v1');
      expect(await s.versions(DocumentKind.rules), isEmpty);

      await s.write(DocumentKind.rules, 'v2');
      final versions = await s.versions(DocumentKind.rules);
      expect(versions, hasLength(1));
      expect(versions.single.text, 'v1');
      expect(await s.read(DocumentKind.rules), 'v2');
    });

    test('only the last 20 versions are kept', () async {
      final clock = FakeClock(initial);
      final s = store(clock);

      await s.write(DocumentKind.notes, 'v0');
      for (int i = 1; i <= 25; i++) {
        clock.advance(const Duration(seconds: 1));
        await s.write(DocumentKind.notes, 'v$i');
      }

      final versions = await s.versions(DocumentKind.notes);
      expect(versions, hasLength(historyVersionsKept));
      expect(versions.first.text, 'v24');
      expect(versions.last.text, 'v5');
    });

    test('restore works and is itself undoable', () async {
      final s = store(FakeClock(initial));

      await s.write(DocumentKind.rules, 'v1');
      await s.write(DocumentKind.rules, 'v2');
      final String v1id = (await s.versions(DocumentKind.rules)).single.id;

      await s.restore(DocumentKind.rules, v1id);
      expect(await s.read(DocumentKind.rules), 'v1');

      final after = await s.versions(DocumentKind.rules);
      expect(after, hasLength(2));
      expect(after.first.text, 'v2');

      await s.restore(DocumentKind.rules, after.first.id);
      expect(await s.read(DocumentKind.rules), 'v2');
    });

    test('restore of a missing version throws', () async {
      final s = store(FakeClock(initial));

      await expectLater(
        s.restore(DocumentKind.rules, 'rules_999.md'),
        throwsArgumentError,
      );
    });

    test('same-clock writes get unique history files', () async {
      final s = store(FakeClock(initial));

      await s.write(DocumentKind.rules, 'v1');
      await s.write(DocumentKind.rules, 'v2');
      await s.write(DocumentKind.rules, 'v3');

      final versions = await s.versions(DocumentKind.rules);
      expect(versions, hasLength(2));
      expect(versions.map((v) => v.id).toSet(), hasLength(2));
    });

    test('kinds are versioned separately', () async {
      final s = store(FakeClock(initial));

      await s.write(DocumentKind.rules, 'r1');
      await s.write(DocumentKind.notes, 'n1');
      await s.write(DocumentKind.rules, 'r2');

      expect(await s.versions(DocumentKind.rules), hasLength(1));
      expect(await s.versions(DocumentKind.notes), isEmpty);
    });
  });
}
