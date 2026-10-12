import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:parley/data/db/database.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/services/dictionary/dictionary_importer.dart';
import 'package:parley/services/dictionary/import/import_runner.dart';
import 'package:parley/services/dictionary/import/import_worker.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/stardict_fixture.dart';
import '../../helpers/temp_dictionary_file_store.dart';

/// Runs the worker inline (no isolate) for deterministic tests.
class InlineImportRunner implements DictionaryImportRunner {
  @override
  Future<ImportOutcome> run(
    ImportRequest request, {
    void Function(DictionaryImportProgress)? onProgress,
  }) {
    return runDictionaryImport(request, onProgress: onProgress);
  }

  @override
  void cancel() {}
}

/// Runner stub that reports a cancellation immediately.
class CancellingRunner implements DictionaryImportRunner {
  @override
  Future<ImportOutcome> run(
    ImportRequest request, {
    void Function(DictionaryImportProgress)? onProgress,
  }) async {
    return const ImportOutcome.cancelled();
  }

  @override
  void cancel() {}
}

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late UserDictionaryRepository repo;
  late Directory tempDir;
  late Directory storeRoot;
  late FileDictionaryImporter importer;
  int counter = 0;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    tempDir = await Directory.systemTemp.createTemp('parley_import_src');
    storeRoot = await Directory.systemTemp.createTemp('parley_import_dst');
    repo = UserDictionaryRepository(
      db,
      clock: clock,
      files: TempDictionaryFileStore(storeRoot),
    );
    importer = FileDictionaryImporter(
      dictionaries: repo,
      files: TempDictionaryFileStore(storeRoot),
      clock: clock,
      runner: InlineImportRunner(),
    );
  });

  tearDown(() async {
    await repo.dispose();
    await db.close();
    // A killed isolate may still hold file handles on Windows; cleanup is
    // best-effort so the test result is not masked by a delete failure.
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    try {
      await storeRoot.delete(recursive: true);
    } catch (_) {}
  });

  Future<Directory> makeDir() async {
    counter++;
    final Directory dir = Directory('${tempDir.path}/d$counter');
    await dir.create(recursive: true);
    return dir;
  }

  /// Writes a StarDict fixture and returns its file paths (ifo, idx, dict).
  Future<List<String>> makeStarFiles({
    Map<String, String> entries = const {'cow': 'корова', 'bank': 'банк'},
    String bookName = 'Test Dictionary',
    bool dictZip = false,
    int? idxFileSize,
  }) async {
    final Directory dir = await makeDir();
    final String ifoPath = await writeStarDict(
      dir: dir,
      entries: entries,
      bookName: bookName,
      dictZip: dictZip,
      idxFileSize: idxFileSize,
    );
    final String base = p.basenameWithoutExtension(ifoPath);
    return [
      ifoPath,
      p.join(dir.path, '$base.idx'),
      if (dictZip)
        p.join(dir.path, '$base.dict.dz')
      else
        p.join(dir.path, '$base.dict'),
    ];
  }

  Future<String> makeDslFile({
    Map<String, String> entries = const {'cow': 'корова', 'bank': 'банк'},
    Map<String, String> transcriptions = const {},
    String encoding = 'utf8',
  }) async {
    final Directory dir = await makeDir();
    return writeDsl(
      dir: dir,
      entries: entries,
      transcriptions: transcriptions,
      encoding: encoding,
    );
  }

  Future<List<Directory>> storeDirs() async {
    return [
      await for (final FileSystemEntity e in storeRoot.list()) e,
    ].whereType<Directory>().toList();
  }

  group('FileDictionaryImporter', () {
    test('imports a StarDict dictionary and builds the cache', () async {
      final List<String> paths = await makeStarFiles();

      final DictionaryImportSummary summary = await importer.importFiles(
        paths,
        targetLang: 'RU',
      );

      expect(summary.name, 'Test Dictionary');
      expect(summary.wordCount, 2);
      final row = (await repo.watchAll().first).single;
      expect(row.name, 'Test Dictionary');
      expect(row.targetLang, 'ru');
      expect(row.wordCount, 2);
      expect(row.format, 'stardict');
      expect(p.isWithin(storeRoot.path, row.path), isTrue);
      expect(File(p.join(row.path, 'testdict.ifo')).existsSync(), isTrue);
      expect(File(p.join(row.path, 'testdict.idx')).existsSync(), isTrue);
      expect(File(p.join(row.path, 'testdict.dict')).existsSync(), isTrue);
      expect(File(p.join(row.path, 'index.sqlite')).existsSync(), isTrue);
      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
    });

    test(
      'two imports at the same time get distinct directories (T-11)',
      () async {
        final List<String> first = await makeStarFiles(
          entries: {'cow': 'корова'},
          bookName: 'First',
        );
        final List<String> second = await makeStarFiles(
          entries: {'bank': 'банк'},
          bookName: 'Second',
        );

        await importer.importFiles(first, targetLang: 'ru');
        await importer.importFiles(second, targetLang: 'ru');

        final rows = await repo.watchAll().first;
        expect(rows, hasLength(2));
        final String stamp = clock.now().millisecondsSinceEpoch.toString();
        expect(rows.map((row) => p.basename(row.path)), [stamp, '${stamp}_1']);
        // Both metadata rows point at their own usable copy.
        expect(
          (await repo.lookup('cow', targetLang: 'ru'))!.translation,
          'корова',
        );
        expect(
          (await repo.lookup('bank', targetLang: 'ru'))!.translation,
          'банк',
        );
      },
    );

    test('accepts a dictzip body', () async {
      final List<String> paths = await makeStarFiles(dictZip: true);

      final DictionaryImportSummary summary = await importer.importFiles(
        paths,
        targetLang: 'ru',
      );

      expect(summary.wordCount, 2);
      expect(
        (await repo.lookup('bank', targetLang: 'ru'))!.translation,
        'банк',
      );
    });

    test('accepts uppercase extensions end to end (A-39)', () async {
      final List<String> paths = await makeStarFiles();
      final String base = p.basenameWithoutExtension(paths.first);
      final Directory src = File(paths.first).parent;
      final String ifo = p.join(src.path, '$base.IFO');
      final String idx = p.join(src.path, '$base.IDX');
      final String dict = p.join(src.path, '$base.DICT');
      await File(paths[0]).rename(ifo);
      await File(paths[1]).rename(idx);
      await File(paths[2]).rename(dict);

      final DictionaryImportSummary summary = await importer.importFiles([
        ifo,
        idx,
        dict,
      ], targetLang: 'ru');

      expect(summary.wordCount, 2);
      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
    });

    test('accepts an uppercase .DICT.DZ body (A-39)', () async {
      final List<String> paths = await makeStarFiles(dictZip: true);
      final String base = p.basenameWithoutExtension(paths.first);
      final Directory src = File(paths.first).parent;
      final String ifo = p.join(src.path, '$base.IFO');
      final String idx = p.join(src.path, '$base.IDX');
      final String dz = p.join(src.path, '$base.DICT.DZ');
      await File(paths[0]).rename(ifo);
      await File(paths[1]).rename(idx);
      await File(paths[2]).rename(dz);

      final DictionaryImportSummary summary = await importer.importFiles([
        ifo,
        idx,
        dz,
      ], targetLang: 'ru');

      expect(summary.wordCount, 2);
      expect(
        (await repo.lookup('bank', targetLang: 'ru'))!.translation,
        'банк',
      );
    });

    test('imports a DSL dictionary with its transcription', () async {
      final String dslPath = await makeDslFile(
        entries: {'cow': 'корова'},
        transcriptions: {'cow': 'kaʊ'},
      );

      final DictionaryImportSummary summary = await importer.importFiles([
        dslPath,
      ], targetLang: 'ru');

      expect(summary.name, 'testdict');
      expect(summary.wordCount, 1);
      final row = (await repo.watchAll().first).single;
      expect(row.format, 'dsl');
      expect(File(p.join(row.path, 'testdict.dsl')).existsSync(), isTrue);
      final entry = await repo.lookup('cow', targetLang: 'ru');
      expect(entry!.translation, 'корова');
      expect(entry.transcription, 'kaʊ');
    });

    test('imports a StarDict dictionary from a zip archive', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'dict.zip',
        paths: paths,
      );

      final DictionaryImportSummary summary = await importer.importFiles([
        zipPath,
      ], targetLang: 'ru');

      expect(summary.name, 'Test Dictionary');
      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
      // The extraction directory is cleaned up.
      final row = (await repo.watchAll().first).single;
      expect(await Directory('${row.path}.extract').exists(), isFalse);
    });

    test('imports a DSL dictionary from a zip archive', () async {
      final String dslPath = await makeDslFile();
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'dsl.zip',
        paths: [dslPath],
      );

      final DictionaryImportSummary summary = await importer.importFiles([
        zipPath,
      ], targetLang: 'ru');

      expect(summary.wordCount, 2);
      expect(
        (await repo.lookup('bank', targetLang: 'ru'))!.translation,
        'банк',
      );
    });

    test('skips AppleDouble files in a zip (A-41)', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      final Directory forks = await makeDir();
      final File fork = File(p.join(forks.path, '._testdict.ifo'));
      await fork.writeAsString('resource fork');
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'dict.zip',
        paths: [...paths, fork.path],
      );

      final DictionaryImportSummary summary = await importer.importFiles([
        zipPath,
      ], targetLang: 'ru');

      expect(summary.name, 'Test Dictionary');
      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
    });

    test('rejects duplicate names in a zip (A-41)', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      // Two entries with different paths but the same basename extract to
      // the same file name.
      final String zipPath = await zipFilesAs(
        dir: zipDir,
        name: 'dict.zip',
        names: [
          'a/testdict.ifo',
          'testdict.idx',
          'testdict.dict',
          'b/testdict.ifo',
        ],
        paths: [...paths, paths.first],
      );

      expect(
        () => importer.importFiles([zipPath], targetLang: 'ru'),
        throwsA(
          isA<DictionaryImportException>().having(
            (DictionaryImportException e) => e.message,
            'message',
            'The .zip archive contains duplicate file names.',
          ),
        ),
      );
    });

    test('flattens traversal names into the destination (T-12)', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFilesAs(
        dir: zipDir,
        name: 'dict.zip',
        names: ['../testdict.ifo', 'testdict.idx', 'sub/../testdict.dict'],
        paths: paths,
      );

      final DictionaryImportSummary summary = await importer.importFiles([
        zipPath,
      ], targetLang: 'ru');

      expect(summary.wordCount, 2);
      final row = (await repo.watchAll().first).single;
      // Extraction keeps the basename, so nothing lands next to the
      // destination directory.
      expect(
        File(p.join(storeRoot.path, 'testdict.ifo')).existsSync(),
        isFalse,
      );
      expect(File(p.join(row.path, 'testdict.ifo')).existsSync(), isTrue);
      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
    });

    test('rejects a zip with a second escaping .ifo (T-12)', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFilesAs(
        dir: zipDir,
        name: 'dict.zip',
        names: ['testdict.ifo', 'testdict.idx', 'testdict.dict', '../evil.ifo'],
        paths: [...paths, paths.first],
      );

      expect(
        () => importer.importFiles([zipPath], targetLang: 'ru'),
        throwsA(
          isA<DictionaryImportException>().having(
            (DictionaryImportException e) => e.message,
            'message',
            'The selection contains more than one dictionary.',
          ),
        ),
      );
      expect(File(p.join(storeRoot.path, 'evil.ifo')).existsSync(), isFalse);
      expect(await storeDirs(), isEmpty);
    });

    test('rejects an empty zip archive (T-12)', () async {
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'empty.zip',
        paths: [],
      );

      expect(
        () => importer.importFiles([zipPath], targetLang: 'ru'),
        throwsA(
          isA<DictionaryImportException>().having(
            (DictionaryImportException e) => e.message,
            'message',
            'Select a StarDict .ifo file or a .dsl file '
                '(optionally inside a single .zip archive).',
          ),
        ),
      );
      expect(await storeDirs(), isEmpty);
    });

    test('accepts an uppercase .ZIP with uppercase entries (T-12)', () async {
      final List<String> paths = await makeStarFiles();
      final String base = p.basenameWithoutExtension(paths.first).toUpperCase();
      final Directory src = File(paths.first).parent;
      final String ifo = p.join(src.path, '$base.IFO');
      final String idx = p.join(src.path, '$base.IDX');
      final String dict = p.join(src.path, '$base.DICT');
      await File(paths[0]).rename(ifo);
      await File(paths[1]).rename(idx);
      await File(paths[2]).rename(dict);
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'DICT.ZIP',
        paths: [ifo, idx, dict],
      );

      final DictionaryImportSummary summary = await importer.importFiles([
        zipPath,
      ], targetLang: 'ru');

      expect(summary.wordCount, 2);
      expect(
        (await repo.lookup('cow', targetLang: 'ru'))!.translation,
        'корова',
      );
    });

    test('enforces the zip entry limit (A-41)', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'dict.zip',
        paths: paths,
      );
      final Directory destination = await makeDir();

      final ImportOutcome outcome = await runDictionaryImport(
        ImportRequest(paths: [zipPath], destinationDir: destination.path),
        maxArchiveEntries: 2,
      );

      expect(outcome.kind, ImportOutcomeKind.failure);
      expect(outcome.message, 'The .zip archive contains too many files.');
    });

    test('enforces the zip extraction size limit (A-41)', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'dict.zip',
        paths: paths,
      );
      final Directory destination = await makeDir();

      final ImportOutcome outcome = await runDictionaryImport(
        ImportRequest(paths: [zipPath], destinationDir: destination.path),
        maxExtractedBytes: 10,
      );

      expect(outcome.kind, ImportOutcomeKind.failure);
      expect(outcome.message, 'The .zip archive is too large to extract.');
    });

    test('falls back to the file name when the ifo has no bookname', () async {
      final List<String> paths = await makeStarFiles(bookName: '');

      final DictionaryImportSummary summary = await importer.importFiles(
        paths,
        targetLang: 'ru',
      );

      expect(summary.name, 'testdict');
    });

    test('reports the import phases with progress', () async {
      final List<String> paths = await makeStarFiles();
      final Directory zipDir = await makeDir();
      final String zipPath = await zipFiles(
        dir: zipDir,
        name: 'dict.zip',
        paths: paths,
      );
      final List<DictionaryImportProgress> progress = [];

      await importer.importFiles(
        [zipPath],
        targetLang: 'ru',
        onProgress: progress.add,
      );

      expect(
        progress.map((p) => p.phase).toSet(),
        containsAll([
          ImportPhase.extracting,
          ImportPhase.copying,
          ImportPhase.indexing,
        ]),
      );
      expect(progress.last.fraction, 1);
    });

    test('rejects an empty language', () async {
      final List<String> paths = await makeStarFiles();

      expect(
        () => importer.importFiles(paths, targetLang: '  '),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('rejects a selection without a dictionary', () async {
      final List<String> paths = await makeStarFiles();

      expect(
        () => importer.importFiles([paths[1]], targetLang: 'ru'),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('rejects two dictionaries at once', () async {
      final List<String> first = await makeStarFiles();
      final List<String> second = await makeStarFiles();

      expect(
        () => importer.importFiles([...first, ...second], targetLang: 'ru'),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('rejects a missing .idx or body file', () async {
      final List<String> paths = await makeStarFiles();

      expect(
        () => importer.importFiles([paths[0], paths[2]], targetLang: 'ru'),
        throwsA(isA<DictionaryImportException>()),
      );
      expect(
        () => importer.importFiles([paths[0], paths[1]], targetLang: 'ru'),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('rejects an .idx that does not match the .ifo size', () async {
      final List<String> paths = await makeStarFiles(idxFileSize: 1);

      expect(
        () => importer.importFiles(paths, targetLang: 'ru'),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('a non-UTF8 .ifo fails with a clear message (A-46)', () async {
      final List<String> paths = await makeStarFiles();
      await File(paths.first).writeAsBytes([0xFF, 0xFE, 0x00, 0x01]);

      expect(
        () => importer.importFiles(paths, targetLang: 'ru'),
        throwsA(
          isA<DictionaryImportException>().having(
            (DictionaryImportException e) => e.message,
            'message',
            'The dictionary file is not valid UTF-8 text.',
          ),
        ),
      );
    });

    test('rejects a .dict.dz that is not a dictzip archive', () async {
      final List<String> paths = await makeStarFiles();
      final String dictPath = paths[2];
      await File(dictPath).rename('$dictPath.dz');

      expect(
        () => importer.importFiles([
          paths[0],
          paths[1],
          '$dictPath.dz',
        ], targetLang: 'ru'),
        throwsA(isA<DictionaryImportException>()),
      );
    });

    test('a failed import leaves no metadata and no files behind', () async {
      final List<String> paths = await makeStarFiles(idxFileSize: 1);

      try {
        await importer.importFiles(paths, targetLang: 'ru');
      } on DictionaryImportException {
        // Expected.
      }

      expect(await repo.watchAll().first, isEmpty);
      expect(await storeDirs(), isEmpty);
    });

    test('a cancelled import cleans up and stores nothing', () async {
      final List<String> paths = await makeStarFiles();
      final FileDictionaryImporter cancelling = FileDictionaryImporter(
        dictionaries: repo,
        files: TempDictionaryFileStore(storeRoot),
        clock: clock,
        runner: CancellingRunner(),
      );

      expect(
        () => cancelling.importFiles(paths, targetLang: 'ru'),
        throwsA(isA<DictionaryImportCancelledException>()),
      );
      expect(await repo.watchAll().first, isEmpty);
      expect(await storeDirs(), isEmpty);
    });
  });

  group('IsolateImportRunner', () {
    test('imports a dictionary in a background isolate', () async {
      final List<String> paths = await makeStarFiles();
      final Directory destination = await Directory(
        '${storeRoot.path}/iso',
      ).create(recursive: true);
      final List<DictionaryImportProgress> progress = [];

      final ImportOutcome outcome = await IsolateImportRunner().run(
        ImportRequest(paths: paths, destinationDir: destination.path),
        onProgress: progress.add,
      );

      expect(outcome.kind, ImportOutcomeKind.success);
      expect(outcome.name, 'Test Dictionary');
      expect(outcome.wordCount, 2);
      expect(progress, isNotEmpty);
      expect(
        File(p.join(destination.path, 'index.sqlite')).existsSync(),
        isTrue,
      );
    });

    test('a second concurrent run is rejected, the first finishes', () async {
      final List<String> paths = await makeStarFiles();
      final Directory destination = await Directory(
        '${storeRoot.path}/iso_parallel',
      ).create(recursive: true);
      final IsolateImportRunner runner = IsolateImportRunner();
      final ImportRequest request = ImportRequest(
        paths: paths,
        destinationDir: destination.path,
      );

      final Future<ImportOutcome> first = runner.run(request);
      final ImportOutcome second = await runner.run(request);

      expect(second.kind, ImportOutcomeKind.failure);
      expect(second.message, 'Import already running.');
      final ImportOutcome firstOutcome = await first;
      expect(firstOutcome.kind, ImportOutcomeKind.success);
    });

    test('cancel stops a running isolate import', () async {
      final List<String> paths = await makeStarFiles();
      final Directory destination = await Directory(
        '${storeRoot.path}/iso_cancel',
      ).create(recursive: true);
      final IsolateImportRunner runner = IsolateImportRunner();
      final Completer<void> started = Completer<void>();

      final Future<ImportOutcome> future = runner.run(
        ImportRequest(paths: paths, destinationDir: destination.path),
        onProgress: (_) {
          if (!started.isCompleted) {
            started.complete();
          }
        },
      );
      await started.future;
      runner.cancel();

      final ImportOutcome outcome = await future;
      expect(outcome.kind, ImportOutcomeKind.cancelled);
    });

    test('cancel before the isolate starts never writes (A-40)', () async {
      final List<String> paths = await makeStarFiles();
      final Directory first = Directory('${storeRoot.path}/iso_pre_a');
      final Directory second = Directory('${storeRoot.path}/iso_pre_b');
      final IsolateImportRunner runner = IsolateImportRunner();

      final Future<ImportOutcome> cancelled = runner.run(
        ImportRequest(paths: paths, destinationDir: first.path),
      );
      runner.cancel();
      // A new import starts before the cancelled spawn settles; the old
      // spawn callback must not adopt (and leak) the first isolate.
      final Future<ImportOutcome> started = runner.run(
        ImportRequest(paths: paths, destinationDir: second.path),
      );

      expect((await cancelled).kind, ImportOutcomeKind.cancelled);
      expect((await started).kind, ImportOutcomeKind.success);
      // The cancelled job's isolate must never create its directory.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(first.existsSync(), isFalse);
    });
  });
}
