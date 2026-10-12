import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/dsl/dsl_index.dart';
import 'package:parley/services/dictionary/dsl/dsl_parser.dart';
import 'package:parley/services/dictionary/dsl/index_dictionary_source.dart';

import '../../helpers/stardict_fixture.dart';

void main() {
  late Directory tempDir;
  int counter = 0;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('parley_dsl');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<Directory> makeDir() async {
    counter++;
    final Directory dir = Directory('${tempDir.path}/d$counter');
    await dir.create(recursive: true);
    return dir;
  }

  // Writes the LF fixture again with [eol] as the only line ending (T-10).
  Future<List<DslEntry>> parseVariant(
    Directory dir,
    String lfPath,
    String name,
    String eol,
  ) async {
    final String text = await File(lfPath).readAsString();
    final File file = File(p.join(dir.path, name));
    await file.writeAsBytes(
      utf8.encode(text.replaceAll('\n', eol)),
      flush: true,
    );
    return parseDsl(file).toList();
  }

  void expectSameDslEntries(List<DslEntry> entries, List<DslEntry> expected) {
    expect(entries, hasLength(expected.length));
    for (int i = 0; i < expected.length; i++) {
      expect(entries[i].word, expected[i].word);
      expect(entries[i].transcription, expected[i].transcription);
      expect(entries[i].translation, expected[i].translation);
      expect(
        '${entries[i].word}${entries[i].transcription}${entries[i].translation}',
        isNot(contains('\r')),
      );
    }
  }

  group('parseDsl', () {
    test('reads a card with its transcription and strips markup', () async {
      final Directory dir = await makeDir();
      final String path = await writeDsl(
        dir: dir,
        entries: {'cow': 'корова [m]животное[/m] {n}'},
        transcriptions: {'cow': 'kaʊ'},
      );

      final List<DslEntry> entries = await parseDsl(File(path)).toList();

      expect(entries, hasLength(1));
      expect(entries.single.word, 'cow');
      expect(entries.single.transcription, 'kaʊ');
      expect(entries.single.translation, 'корова животное');
    });

    test('reads UTF-16LE files', () async {
      final Directory dir = await makeDir();
      final String path = await writeDsl(
        dir: dir,
        entries: {'cow': 'корова'},
        encoding: 'utf16le',
      );

      final List<DslEntry> entries = await parseDsl(File(path)).toList();

      expect(entries.single.word, 'cow');
      expect(entries.single.translation, 'корова');
    });

    test('reads definitions indented with spaces (A-42)', () async {
      final Directory dir = await makeDir();
      final String path = await writeDsl(
        dir: dir,
        entries: {'cow': 'корова', 'bank': 'банк'},
        indent: '  ',
      );

      final List<DslEntry> entries = await parseDsl(File(path)).toList();

      expect(entries, hasLength(2));
      expect(entries[0].word, 'cow');
      expect(entries[0].translation, 'корова');
      expect(entries[1].word, 'bank');
      expect(entries[1].translation, 'банк');
    });

    test('reads CRLF line endings like LF (T-10)', () async {
      final Directory dir = await makeDir();
      final String lfPath = await writeDsl(
        dir: dir,
        entries: {'cow': 'корова [m]животное[/m]', 'bank': 'банк'},
        transcriptions: {'cow': 'kaʊ', 'bank': 'bæŋk'},
        indent: '  ',
      );
      final List<DslEntry> expected = await parseDsl(File(lfPath)).toList();
      expect(expected, hasLength(2));

      final List<DslEntry> entries = await parseVariant(
        dir,
        lfPath,
        'crlf.dsl',
        '\r\n',
      );

      expectSameDslEntries(entries, expected);
    });

    test('reads lone-CR line endings like LF (T-10)', () async {
      final Directory dir = await makeDir();
      final String lfPath = await writeDsl(
        dir: dir,
        entries: {'cow': 'корова [m]животное[/m]', 'bank': 'банк'},
        transcriptions: {'cow': 'kaʊ', 'bank': 'bæŋk'},
        indent: '  ',
      );
      final List<DslEntry> expected = await parseDsl(File(lfPath)).toList();
      expect(expected, hasLength(2));

      final List<DslEntry> entries = await parseVariant(
        dir,
        lfPath,
        'cr.dsl',
        '\r',
      );

      expectSameDslEntries(entries, expected);
    });

    test('streams every card and skips comments', () async {
      final Directory dir = await makeDir();
      final File file = File(p.join(dir.path, 'cards.dsl'));
      await file.writeAsString(
        '#NAME "Cards"\n'
        '# comment\n'
        'cow\n'
        '\tкорова\n'
        '\n'
        'cow\n'
        '\tбык\n'
        '\n',
      );

      final List<DslEntry> entries = await parseDsl(file).toList();

      expect(entries, hasLength(2));
      expect(entries[0].translation, 'корова');
      expect(entries[1].translation, 'бык');
    });
  });

  group('cleanDslText', () {
    test('drops comments and markers, keeps example text', () {
      expect(cleanDslText('корова [m] {n} [com]note[/com]'), 'корова');
      expect(cleanDslText('[ex]a cow[/ex] [trn]kaʊ[/trn]'), 'a cow');
      expect(cleanDslText(r'\[test\]'), '[test]');
      expect(cleanDslText('<<cow>>'), 'cow');
    });
  });

  group('buildDslIndexCache + IndexDictionarySource', () {
    test('builds the cache and resolves normalized lookups', () async {
      final Directory dir = await makeDir();
      final String path = await writeDsl(
        dir: dir,
        entries: {'cow': 'корова', 'bank': 'банк'},
        transcriptions: {'cow': 'kaʊ'},
      );
      final File cache = File(p.join(dir.path, 'index.sqlite'));

      final int count = await buildDslIndexCache(
        dslFile: File(path),
        cacheFile: cache,
      );

      expect(count, 2);
      final IndexDictionarySource source = IndexDictionarySource(cache);
      final DictionaryEntry? entry = await source.lookup('  COW ');
      expect(entry, isNotNull);
      expect(entry!.textKey, 'cow');
      expect(entry.translation, 'корова');
      expect(entry.transcription, 'kaʊ');
      expect(await source.lookup('heifer'), isNull);
      await source.dispose();
    });

    test('the first card wins for a duplicate headword', () async {
      final Directory dir = await makeDir();
      final File file = File(p.join(dir.path, 'dupe.dsl'));
      await file.writeAsString('cow\n\tкорова\n\ncow\n\tбык\n\n');
      final File cache = File(p.join(dir.path, 'index.sqlite'));

      final int count = await buildDslIndexCache(
        dslFile: file,
        cacheFile: cache,
      );

      expect(count, 1);
      final IndexDictionarySource source = IndexDictionarySource(cache);
      expect((await source.lookup('cow'))!.translation, 'корова');
      await source.dispose();
    });

    test('a missing cache fails loudly', () async {
      final IndexDictionarySource source = IndexDictionarySource(
        File(p.join(tempDir.path, 'none.sqlite')),
      );

      expect(
        () => source.lookup('cow'),
        throwsA(isA<DictionarySourceException>()),
      );
      await source.dispose();
    });

    test('a failed open is retried on the next lookup (A-45)', () async {
      final Directory dir = await makeDir();
      final File cache = File(p.join(dir.path, 'index.sqlite'));
      final IndexDictionarySource source = IndexDictionarySource(cache);

      // The cache does not exist yet: the first open fails.
      await expectLater(
        source.lookup('cow'),
        throwsA(isA<DictionarySourceException>()),
      );

      // The cache appears (a retried transfer); lookup must recover.
      final String path = await writeDsl(dir: dir, entries: {'cow': 'корова'});
      expect(
        await buildDslIndexCache(dslFile: File(path), cacheFile: cache),
        1,
      );

      expect((await source.lookup('cow'))!.translation, 'корова');
      await source.dispose();
    });
  });
}
