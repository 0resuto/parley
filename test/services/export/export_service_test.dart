import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/export/export_service.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

import '../../helpers/fake_clock.dart';

void main() {
  // Round-trip tests hold two separate in-memory databases at once.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late FakeClock clock;
  late UnitRepository units;
  late MemoryDocumentStore docs;
  late ExportService service;
  late ReviewService reviews;
  final DateTime initial = DateTime.utc(2026, 1, 10, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(initial);
    units = UnitRepository(db, clock: clock);
    docs = MemoryDocumentStore();
    service = ExportService(
      database: db,
      units: units,
      documents: docs,
      clock: clock,
    );
    reviews = ReviewService(db, units: units, clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  /// Seeds two reviewed units and one Known unit at distinct timestamps.
  Future<void> seed() async {
    final Unit cow = await units.add(text: 'Cow', forms: ['cows']);
    clock.advance(const Duration(minutes: 1));
    final Unit milk = await units.add(text: 'Milk', description: 'White drink');
    clock.advance(const Duration(minutes: 1));
    final Unit bread = await units.add(text: 'Bread');
    await reviews.rate(
      cow.id,
      Rating.good,
      ReviewSource.card,
      at: initial.add(const Duration(hours: 1)),
    );
    await reviews.rate(
      cow.id,
      Rating.easy,
      ReviewSource.chat,
      at: initial.add(const Duration(hours: 2)),
    );
    await reviews.rate(
      milk.id,
      Rating.hard,
      ReviewSource.tap,
      at: initial.add(const Duration(hours: 3)),
    );
    await units.setKnown(bread.id, true);
  }

  ExportService freshService(
    AppDatabase other,
    UnitRepository otherUnits,
    MemoryDocumentStore otherDocs,
  ) {
    return ExportService(
      database: other,
      units: otherUnits,
      documents: otherDocs,
      clock: clock,
    );
  }

  Map<String, dynamic> normalized(String json) {
    final Map<String, dynamic> map = jsonDecode(json) as Map<String, dynamic>;
    map.remove('exported_at');
    return map;
  }

  group('export', () {
    test('builds the v2 envelope with units, reviews and docs', () async {
      await docs.write(DocumentKind.rules, '# Rules');
      await docs.write(DocumentKind.notes, '# Notes');
      await seed();

      final Map<String, dynamic> doc =
          jsonDecode(await service.exportJson()) as Map<String, dynamic>;

      expect(doc['format'], 'parley-export');
      expect(doc['version'], 2);
      expect(
        DateTime.parse(doc['exported_at'] as String),
        initial.add(const Duration(minutes: 2)),
      );
      expect(doc['rules'], '# Rules');
      expect(doc['notes'], '# Notes');
      final List<dynamic> exportedUnits = doc['units'] as List;
      expect(exportedUnits, hasLength(3));
      final Map<String, dynamic> cow =
          exportedUnits.firstWhere((u) => (u as Map)['text'] == 'Cow')
              as Map<String, dynamic>;
      expect(cow['forms'], ['cows']);
      expect(cow.containsKey('translation_ru'), isFalse);
      expect(cow['known_manual'], isFalse);
      expect(cow['fsrs'], isA<String>());
      final List<dynamic> exportedReviews = doc['reviews'] as List;
      expect(exportedReviews, hasLength(3));
      expect(exportedReviews.first['unit_text'], 'Cow');
      expect(exportedReviews.first['rating'], 3);
      expect(exportedReviews.first['source'], 'card');
    });

    test('file name uses the clock date', () {
      expect(
        service.exportFileName(DateTime.utc(2026, 3, 5, 23, 30)),
        'parley-export-20260305.json',
      );
    });
  });

  group('import round trip', () {
    test(
      'export then import into an empty db keeps units and reviews',
      () async {
        await docs.write(DocumentKind.rules, '# Rules');
        await docs.write(DocumentKind.notes, '# Notes');
        await seed();
        final String first = await service.exportJson();

        final AppDatabase other = AppDatabase(NativeDatabase.memory());
        final UnitRepository otherUnits = UnitRepository(other, clock: clock);
        final MemoryDocumentStore otherDocs = MemoryDocumentStore();
        try {
          final ImportSummary summary = await freshService(
            other,
            otherUnits,
            otherDocs,
          ).importJson(first);

          expect(summary.added, 3);
          expect(summary.skipped, 0);
          expect(summary.overwritten, 0);
          expect(summary.reviewsAdded, 3);
          expect(summary.docsReplaced, isFalse);
          // Docs stay untouched unless the option is on.
          expect(await otherDocs.read(DocumentKind.rules), '');
          expect(await otherDocs.read(DocumentKind.notes), '');

          final String second = await freshService(
            other,
            otherUnits,
            otherDocs,
          ).exportJson();
          final Map<String, dynamic> a = normalized(first);
          final Map<String, dynamic> b = normalized(second);
          a.remove('rules');
          a.remove('notes');
          b.remove('rules');
          b.remove('notes');
          expect(b, a);
        } finally {
          await other.close();
        }
      },
    );
  });

  group('merge', () {
    test('existing units are skipped by default', () async {
      await seed();
      final String payload = await service.exportJson();

      final ImportSummary summary = await service.importJson(payload);

      expect(summary.added, 0);
      expect(summary.skipped, 3);
      expect(summary.overwritten, 0);
      // The reviews already exist, so re-importing appends nothing.
      expect(summary.reviewsAdded, 0);
      expect(await db.select(db.reviews).get(), hasLength(3));
    });

    test('overwrite does not duplicate reviews', () async {
      await seed();
      final String payload = await service.exportJson();

      final ImportSummary summary = await service.importJson(
        payload,
        options: const ImportOptions(overwriteExisting: true),
      );

      expect(summary.overwritten, 3);
      expect(summary.reviewsAdded, 0);
      expect(await db.select(db.reviews).get(), hasLength(3));
    });

    test('overwrite replaces existing units', () async {
      final Unit cow = await units.add(text: 'Cow');
      final String payload = await service.exportJson();

      final Map<String, dynamic> edited =
          jsonDecode(payload) as Map<String, dynamic>;
      final List<dynamic> list = edited['units'] as List;
      (list.firstWhere((u) => (u as Map)['text'] == 'Cow') as Map)['forms'] = [
        'kine',
      ];
      final ImportSummary summary = await service.importJson(
        jsonEncode(edited),
        options: const ImportOptions(overwriteExisting: true),
      );

      expect(summary.added, 0);
      expect(summary.skipped, 0);
      expect(summary.overwritten, 1);
      expect((await units.getById(cow.id))?.forms, ['kine']);
    });

    test('v1 files import with translations ignored', () async {
      await units.add(text: 'Cow');
      final Map<String, dynamic> doc =
          jsonDecode(await service.exportJson()) as Map<String, dynamic>;
      doc['version'] = 1;
      (doc['units'] as List).first['translation_ru'] = 'корова';

      final ImportSummary summary = await service.importJson(jsonEncode(doc));

      expect(summary.skipped, 1);
      expect((await units.findByKey('cow'))?.text, 'Cow');
    });
  });

  group('import safety', () {
    test('a broken unit leaves nothing imported', () async {
      final AppDatabase source = AppDatabase(NativeDatabase.memory());
      final UnitRepository sourceUnits = UnitRepository(source, clock: clock);
      try {
        await sourceUnits.add(text: 'Alpha');
        await sourceUnits.add(text: 'Beta');
        final String payload = await freshService(
          source,
          sourceUnits,
          MemoryDocumentStore(),
        ).exportJson();
        final Map<String, dynamic> doc =
            jsonDecode(payload) as Map<String, dynamic>;
        final List<dynamic> list = doc['units'] as List;
        list.removeWhere((u) => (u as Map)['text'] == 'Beta');
        list.add(<String, dynamic>{});

        await expectLater(
          service.importJson(jsonEncode(doc)),
          throwsA(isA<ExportFormatException>()),
        );

        expect(await units.watchAll().first, isEmpty);
      } finally {
        await source.close();
      }
    });

    test('a broken review leaves nothing imported', () async {
      final AppDatabase source = AppDatabase(NativeDatabase.memory());
      final UnitRepository sourceUnits = UnitRepository(source, clock: clock);
      try {
        final Unit alpha = await sourceUnits.add(text: 'Alpha');
        final ReviewService sourceReviews = ReviewService(
          source,
          units: sourceUnits,
          clock: clock,
        );
        await sourceReviews.rate(
          alpha.id,
          Rating.good,
          ReviewSource.card,
          at: initial.add(const Duration(hours: 1)),
        );
        final String payload = await freshService(
          source,
          sourceUnits,
          MemoryDocumentStore(),
        ).exportJson();
        final Map<String, dynamic> doc =
            jsonDecode(payload) as Map<String, dynamic>;
        (doc['reviews'] as List).add(<String, dynamic>{'unit_text': 'Ghost'});

        await expectLater(
          service.importJson(jsonEncode(doc)),
          throwsA(isA<ExportFormatException>()),
        );

        expect(await units.watchAll().first, isEmpty);
        expect(await db.select(db.reviews).get(), isEmpty);
      } finally {
        await source.close();
      }
    });

    test('overwrite clears fields the file does not carry', () async {
      final Unit cow = await units.add(text: 'Cow', description: 'White drink');
      await reviews.rate(
        cow.id,
        Rating.good,
        ReviewSource.card,
        at: initial.add(const Duration(hours: 1)),
      );
      expect((await units.getById(cow.id))?.lastReview, isNotNull);

      final AppDatabase source = AppDatabase(NativeDatabase.memory());
      final UnitRepository sourceUnits = UnitRepository(source, clock: clock);
      try {
        await sourceUnits.add(text: 'Cow');
        final String payload = await freshService(
          source,
          sourceUnits,
          MemoryDocumentStore(),
        ).exportJson();

        final ImportSummary summary = await service.importJson(
          payload,
          options: const ImportOptions(overwriteExisting: true),
        );

        expect(summary.overwritten, 1);
        final Unit? after = await units.getById(cow.id);
        expect(after!.description, isNull);
        expect(after.stability, isNull);
        expect(after.lastReview, isNull);
      } finally {
        await source.close();
      }
    });
  });

  group('documents', () {
    test('rules and notes are replaced only when asked', () async {
      await docs.write(DocumentKind.rules, 'old rules');
      await docs.write(DocumentKind.notes, 'old notes');
      await seed();
      final String payload = await service.exportJson();
      final Map<String, dynamic> edited =
          jsonDecode(payload) as Map<String, dynamic>;
      edited['rules'] = 'new rules';
      edited['notes'] = 'new notes';
      final String changed = jsonEncode(edited);

      final ImportSummary kept = await service.importJson(changed);
      expect(kept.docsReplaced, isFalse);
      expect(await docs.read(DocumentKind.rules), 'old rules');
      expect(await docs.read(DocumentKind.notes), 'old notes');

      final ImportSummary replaced = await service.importJson(
        changed,
        options: const ImportOptions(
          overwriteExisting: true,
          replaceDocs: true,
        ),
      );
      expect(replaced.docsReplaced, isTrue);
      expect(await docs.read(DocumentKind.rules), 'new rules');
      expect(await docs.read(DocumentKind.notes), 'new notes');
    });

    test(
      'oversized documents are rejected before anything is written',
      () async {
        await units.add(text: 'Cow');
        final Map<String, dynamic> doc =
            jsonDecode(await service.exportJson()) as Map<String, dynamic>;

        doc['rules'] = 'x' * (rulesLimit + 1);
        await expectLater(
          service.importJson(
            jsonEncode(doc),
            options: const ImportOptions(replaceDocs: true),
          ),
          throwsA(isA<ExportFormatException>()),
        );
        expect(await docs.read(DocumentKind.rules), isEmpty);

        // The exact limit is accepted.
        doc['rules'] = 'y' * rulesLimit;
        doc['notes'] = 'z' * notesLimit;
        final ImportSummary summary = await service.importJson(
          jsonEncode(doc),
          options: const ImportOptions(replaceDocs: true),
        );
        expect(summary.docsReplaced, isTrue);
        expect(await docs.read(DocumentKind.rules), 'y' * rulesLimit);
        expect(await docs.read(DocumentKind.notes), 'z' * notesLimit);
      },
    );
  });

  group('invalid files', () {
    test('bad envelopes throw ExportFormatException', () async {
      const List<String> bad = [
        'not json at all {',
        '[]',
        '{"format":"other","version":1,"units":[],"reviews":[]}',
        '{"format":"parley-export","version":3,"units":[],"reviews":[]}',
        '{"format":"parley-export","version":1}',
        '{"format":"parley-export","version":1,"units":{},"reviews":[]}',
        '{"format":"parley-export","version":1,"units":[],"reviews":{}}',
        '{"format":"parley-export","version":1,"units":[{}],"reviews":[]}',
        '{"format":"parley-export","version":1,"units":[{"text":"Cow","phase":9,"due":"2026-01-10T12:00:00.000Z","fsrs":"{}","created_at":"2026-01-10T12:00:00.000Z"}],"reviews":[]}',
      ];
      for (final String payload in bad) {
        await expectLater(
          service.importJson(payload),
          throwsA(isA<ExportFormatException>()),
          reason: payload,
        );
      }
    });

    test('bad reviews throw ExportFormatException', () async {
      await units.add(text: 'Cow');
      const String payload =
          '{"format":"parley-export","version":1,"units":[],"reviews":'
          '[{"unit_text":"Cow","rating":9,"reviewed_at":"2026-01-10T12:00:00.000Z","source":"card"}]}';
      await expectLater(
        service.importJson(payload),
        throwsA(isA<ExportFormatException>()),
      );
    });

    test('reviews for unknown words are skipped', () async {
      const String payload =
          '{"format":"parley-export","version":1,"units":[],"reviews":'
          '[{"unit_text":"Ghost","rating":3,"reviewed_at":"2026-01-10T12:00:00.000Z","source":"card"}]}';
      final ImportSummary summary = await service.importJson(payload);
      expect(summary.reviewsAdded, 0);
    });
  });
}
