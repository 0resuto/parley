import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart' hide Unit;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/export/csv_importer.dart';

import '../../helpers/fake_clock.dart';

/// Counts repository calls so the bulk path can be asserted (A-13).
class CountingUnits extends UnitRepository {
  // The super field `_db` is private, so a super parameter is impossible.
  // ignore: use_super_parameters
  CountingUnits(AppDatabase db, {required Clock clock})
    : super(db, clock: clock);

  final List<String> calls = [];

  @override
  Future<List<Unit>> addAll(List<String> texts) {
    calls.add('addAll');
    return super.addAll(texts);
  }

  @override
  Future<Set<String>> allKeys() {
    calls.add('allKeys');
    return super.allKeys();
  }

  @override
  Future<Unit?> findByKey(String query) {
    calls.add('findByKey');
    return super.findByKey(query);
  }

  @override
  Future<Unit> add({
    required String text,
    String? description,
    List<String> forms = const [],
  }) {
    calls.add('add');
    return super.add(text: text, description: description, forms: forms);
  }
}

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
    test('adds the words, ignoring the translation column', () async {
      final summary = await importer.importCsv('cow;корова\nmilk;молоко');

      expect(summary.added, 2);
      expect(summary.skipped, 0);
      expect(await units.findByKey('cow'), isNotNull);
      expect(await units.findByKey('milk'), isNotNull);
    });

    test('header line is ignored', () async {
      final summary = await importer.importCsv('word;translation\ncow;корова');

      expect(summary.added, 1);
      expect(summary.skipped, 0);
      expect(await units.findByKey('word'), isNull);
      expect(await units.findByKey('cow'), isNotNull);
    });

    test('header with extra columns is ignored (A-58)', () async {
      final summary = await importer.importCsv(
        'word;translation;note\ncow;корова;животное',
      );

      expect(summary.added, 1);
      expect(summary.skipped, 0);
      expect(await units.findByKey('word'), isNull);
      expect(await units.findByKey('cow'), isNotNull);
    });

    test('header detection trims, ignores case and accepts "text"', () async {
      final summary = await importer.importCsv('  TEXT ; Meaning \ncow;корова');

      expect(summary.added, 1);
      expect(summary.skipped, 0);
      expect(await units.findByKey('text'), isNull);
      expect(await units.findByKey('cow'), isNotNull);
    });

    test('empty lines are skipped', () async {
      final summary = await importer.importCsv(
        'cow;корова\n\n   \nmilk;молоко\n',
      );

      expect(summary.added, 2);
      expect(summary.skipped, 0);
    });

    test('the translation column is optional', () async {
      final withSemicolon = await importer.importCsv('cow;');
      expect(withSemicolon.added, 1);
      expect(await units.findByKey('cow'), isNotNull);

      await db.close();
      db = AppDatabase(NativeDatabase.memory());
      units = UnitRepository(db, clock: clock);
      importer = CsvImporter(units: units);

      final withoutSemicolon = await importer.importCsv('bread');
      expect(withoutSemicolon.added, 1);
      expect(await units.findByKey('bread'), isNotNull);
    });

    test('existing duplicates are skipped', () async {
      await units.add(text: 'Cow');

      final summary = await importer.importCsv(
        'cow;другая\nCOW;ещё\nmilk;молоко',
      );

      expect(summary.added, 1);
      expect(summary.skipped, 2);
      expect(await units.findByKey('cow'), isNotNull);
      expect(await units.findByKey('milk'), isNotNull);
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
        expect(await units.findByKey('cow'), isNotNull);
      },
    );

    test('summary describes added and skipped', () async {
      await units.add(text: 'Cow');
      final summary = await importer.importCsv('cow;x\nmilk;молоко');

      expect(summary.added, 1);
      expect(summary.skipped, 1);
      expect(summary.describe(), 'Added: 1\nSkipped: 1');
    });

    test('BOM, CRLF and lone CR line endings are handled', () async {
      final summary = await importer.importCsv(
        '\uFEFFcow;корова\r\nmilk;молоко\regg;яйцо',
      );

      expect(summary.added, 3);
      expect(summary.skipped, 0);
      expect(await units.findByKey('cow'), isNotNull);
      expect(await units.findByKey('milk'), isNotNull);
      expect(await units.findByKey('egg'), isNotNull);
    });

    test('apostrophes are kept in the word', () async {
      final summary = await importer.importCsv("don't;не надо");

      expect(summary.added, 1);
      expect(await units.findByKey("don't"), isNotNull);
    });

    test('duplicates in different cases are skipped inside the file', () async {
      final summary = await importer.importCsv('Cow\nCOW\ncow');

      expect(summary.added, 1);
      expect(summary.skipped, 2);
    });

    test('a large file uses one key query and one batch insert', () async {
      final CountingUnits counting = CountingUnits(db, clock: clock);
      final CsvImporter bulkImporter = CsvImporter(units: counting);
      final StringBuffer csv = StringBuffer();
      for (int i = 0; i < 1200; i++) {
        csv.writeln('word$i;перевод');
      }

      final summary = await bulkImporter.importCsv(csv.toString());

      expect(summary.added, 1200);
      expect(summary.skipped, 0);
      expect(counting.calls.where((c) => c == 'allKeys'), hasLength(1));
      expect(counting.calls.where((c) => c == 'addAll'), hasLength(1));
      expect(counting.calls.where((c) => c == 'findByKey'), isEmpty);
      expect(counting.calls.where((c) => c == 'add'), hasLength(1200));
      final Set<String> keys = await counting.allKeys();
      expect(keys.length, 1200);
      expect(keys, contains('word0'));
      expect(keys, contains('word1199'));
    });
  });
}
