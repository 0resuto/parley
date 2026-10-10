import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/export/csv_importer.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UnitRepository units;
  late CsvImporter importer;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    units = UnitRepository(db, clock: clock);
    importer = CsvImporter(units: units);
  });

  tearDown(() async {
    await db.close();
  });

  group('CsvImporter', () {
    test('adds word and translation pairs', () async {
      final summary = await importer.importCsv('cow;корова\nmilk;молоко');

      expect(summary.added, 2);
      expect(summary.skipped, 0);
      expect((await units.findByKey('cow'))?.translationRu, 'корова');
      expect((await units.findByKey('milk'))?.translationRu, 'молоко');
    });

    test('header line is ignored', () async {
      final summary = await importer.importCsv('word;translation\ncow;корова');

      expect(summary.added, 1);
      expect(summary.skipped, 0);
      expect(await units.findByKey('word'), isNull);
      expect((await units.findByKey('cow'))?.translationRu, 'корова');
    });

    test('empty lines are skipped', () async {
      final summary = await importer.importCsv(
        'cow;корова\n\n   \nmilk;молоко\n',
      );

      expect(summary.added, 2);
      expect(summary.skipped, 0);
    });

    test('missing translation creates a unit with empty translation', () async {
      final withSemicolon = await importer.importCsv('cow;');
      expect(withSemicolon.added, 1);
      expect((await units.findByKey('cow'))?.translationRu, '');

      await db.close();
      db = AppDatabase(NativeDatabase.memory());
      units = UnitRepository(db, clock: clock);
      importer = CsvImporter(units: units);

      final withoutSemicolon = await importer.importCsv('bread');
      expect(withoutSemicolon.added, 1);
      expect((await units.findByKey('bread'))?.translationRu, '');
    });

    test('existing duplicates are skipped', () async {
      await units.add(text: 'Cow', translationRu: 'корова');

      final summary = await importer.importCsv(
        'cow;другая\nCOW;ещё\nmilk;молоко',
      );

      expect(summary.added, 1);
      expect(summary.skipped, 2);
      // The stored translation is untouched.
      expect((await units.findByKey('cow'))?.translationRu, 'корова');
      expect((await units.findByKey('milk'))?.translationRu, 'молоко');
    });

    test('duplicates within the file are skipped', () async {
      final summary = await importer.importCsv('cow;корова\ncow;корова');

      expect(summary.added, 1);
      expect(summary.skipped, 1);
    });

    test(
      'semicolons inside have nothing special: only two columns used',
      () async {
        final summary = await importer.importCsv('cow;корова;extra;more');

        expect(summary.added, 1);
        expect(summary.skipped, 0);
        expect((await units.findByKey('cow'))?.translationRu, 'корова');
      },
    );

    test('summary describes added and skipped', () async {
      await units.add(text: 'Cow');
      final summary = await importer.importCsv('cow;x\nmilk;молоко');

      expect(summary.added, 1);
      expect(summary.skipped, 1);
      expect(summary.describe(), 'Added: 1\nSkipped: 1');
    });
  });
}
