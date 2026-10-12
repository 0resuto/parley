import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:parley/services/dictionary/stardict/stardict_entry.dart';
import 'package:parley/services/dictionary/stardict/stardict_index.dart';
import 'package:parley/services/dictionary/stardict/stardict_metadata.dart';
import 'package:parley/services/dictionary/stardict/stardict_source.dart';

import '../../helpers/stardict_fixture.dart';

void main() {
  late Directory tempDir;
  int counter = 0;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('parley_stardict');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<StarDictSource> makeSource({
    required Map<String, String> entries,
    String? sametypesequence,
    Map<String, String> transcriptions = const {},
    Map<String, List<String>> examples = const {},
    Map<String, int> synonyms = const {},
    bool dictZip = false,
    int chunkLength = 32,
  }) async {
    counter++;
    final Directory dir = Directory('${tempDir.path}/d$counter');
    await dir.create(recursive: true);
    await writeStarDict(
      dir: dir,
      entries: entries,
      sametypesequence: sametypesequence,
      transcriptions: transcriptions,
      examples: examples,
      synonyms: synonyms,
      dictZip: dictZip,
      chunkLength: chunkLength,
    );
    return StarDictSource(dir);
  }

  group('parseStarDictIfo', () {
    test('reads the metadata', () {
      final StarDictMetadata metadata = parseStarDictIfo(
        "StarDict's dict ifo file\n"
        'version=2.4.2\n'
        'bookname=My Book\n'
        'wordcount=12\n'
        'idxfilesize=345\n'
        'sametypesequence=tm\n'
        'synwordcount=3\n',
      );

      expect(metadata.bookName, 'My Book');
      expect(metadata.wordCount, 12);
      expect(metadata.idxFileSize, 345);
      expect(metadata.sametypesequence, 'tm');
      expect(metadata.synWordCount, 3);
    });

    test('rejects non-ifo content and missing word counts', () {
      expect(
        () => parseStarDictIfo('hello'),
        throwsA(isA<StarDictFormatException>()),
      );
      expect(
        () => parseStarDictIfo("StarDict's dict ifo file\nbookname=x\n"),
        throwsA(isA<StarDictFormatException>()),
      );
    });

    test('reads uppercase keys (A-43)', () {
      final StarDictMetadata metadata = parseStarDictIfo(
        "StarDict's dict ifo file\n"
        'BookName=My Book\n'
        'WordCount=12\n'
        'IdxFileSize=345\n'
        'SameTypeSequence=tm\n'
        'SynWordCount=3\n',
      );

      expect(metadata.bookName, 'My Book');
      expect(metadata.wordCount, 12);
      expect(metadata.idxFileSize, 345);
      expect(metadata.sametypesequence, 'tm');
      expect(metadata.synWordCount, 3);
    });
  });

  group('parseStarDictEntry', () {
    test('reads a type-byte entry', () {
      final Uint8List data = Uint8List.fromList([
        0x6d, // 'm'
        ...utf8.encode('корова'),
        0,
      ]);

      expect(parseStarDictEntry(data, null)!.text, 'корова');
    });

    test('reads an unknown type byte as a C-string (A-47)', () {
      final Uint8List data = Uint8List.fromList([
        0x6e, // 'n' — WordNet data, not a known text type
        ...utf8.encode('junk'),
        0,
        0x6d, // 'm'
        ...utf8.encode('корова'),
        0,
      ]);

      expect(parseStarDictEntry(data, null)!.text, 'корова');
    });

    test('skips a length-prefixed payload and keeps parsing (A-47)', () {
      final Uint8List data = Uint8List.fromList([
        0x50, // 'P'
        0, 0, 0, 3, // payload size
        0xff, 0xfe, 0xfd,
        0x6d, // 'm'
        ...utf8.encode('корова'),
        0,
      ]);

      expect(parseStarDictEntry(data, null)!.text, 'корова');
    });

    test('skips fields before the meaning in a sametypesequence', () {
      final BytesBuilder data = BytesBuilder()
        ..add(utf8.encode('kaʊ'))
        ..addByte(0)
        ..add(utf8.encode('корова'));

      final StarDictEntryContent content = parseStarDictEntry(
        data.takeBytes(),
        'tm',
      )!;
      expect(content.text, 'корова');
      expect(content.transcription, 'kaʊ');
      expect(content.examples, isEmpty);
    });

    test('strips markup and collapses whitespace', () {
      final Uint8List data = Uint8List.fromList(
        utf8.encode('<b>корова</b>&nbsp;<i>f</i>'),
      );

      expect(parseStarDictEntry(data, 'h')!.text, 'корова f');
    });

    test('reads xdxf translations and examples', () {
      final Uint8List data = Uint8List.fromList(
        utf8.encode(
          '<k>cow</k><def><tr>корова</tr>'
          '<ex>a cow in the field</ex><ex>cows are big</ex></def>',
        ),
      );

      final StarDictEntryContent content = parseStarDictEntry(data, 'x')!;
      expect(content.text, 'корова');
      expect(content.examples, ['a cow in the field', 'cows are big']);
    });

    test('returns null when there is no text field', () {
      final Uint8List data = Uint8List.fromList([0x50, 0, 0, 0, 0]);

      expect(parseStarDictEntry(data, null), isNull);
    });

    test('xdxf fallback drops the <k> headword (A-44)', () {
      final Uint8List data = Uint8List.fromList(
        utf8.encode('<k>cow</k><def>корова</def>'),
      );

      expect(parseStarDictEntry(data, 'x')!.text, 'корова');
    });

    test('xdxf translations do not swallow nested examples (A-44)', () {
      final Uint8List data = Uint8List.fromList(
        utf8.encode('<k>cow</k><def><tr>корова <ex>a cow</ex></tr></def>'),
      );

      final StarDictEntryContent content = parseStarDictEntry(data, 'x')!;
      expect(content.text, 'корова');
      expect(content.examples, ['a cow']);
    });
  });

  group('index streaming', () {
    test('reads .idx records that straddle the 64 KiB read block', () async {
      final BytesBuilder bytes = BytesBuilder();
      final List<String> expected = [];
      for (int i = 0; i < 2400; i++) {
        final String word = 'w${i.toString().padLeft(23, '0')}';
        final int offset = i * 1000;
        final int size = 7 + i;
        bytes
          ..add(utf8.encode(word))
          ..addByte(0)
          ..add(_be32(offset))
          ..add(_be32(size));
        expected.add('$word:$offset:$size');
      }
      final File file = File('${tempDir.path}/big.idx');
      await file.writeAsBytes(bytes.takeBytes(), flush: true);

      final List<StarDictIdxRecord> records = await parseStarDictIdx(
        file,
      ).toList();

      expect(
        records
            .map((StarDictIdxRecord r) => '${r.word}:${r.offset}:${r.size}')
            .toList(),
        expected,
      );
    });

    test('reads .syn records that straddle the 64 KiB read block', () async {
      final BytesBuilder bytes = BytesBuilder();
      final List<String> expected = [];
      for (int i = 0; i < 2400; i++) {
        final String word = 's${i.toString().padLeft(23, '0')}';
        bytes
          ..add(utf8.encode(word))
          ..addByte(0)
          ..add(_be32(i));
        expected.add('$word:$i');
      }
      final File file = File('${tempDir.path}/big.syn');
      await file.writeAsBytes(bytes.takeBytes(), flush: true);

      final List<StarDictSynRecord> records = await parseStarDictSyn(
        file,
      ).toList();

      expect(
        records.map((StarDictSynRecord r) => '${r.word}:${r.index}').toList(),
        expected,
      );
    });

    test('reads .idx records when a chunk boundary splits a tail', () async {
      List<int> record(String word, int offset, int size) => [
        ...utf8.encode(word),
        0,
        ..._be32(offset),
        ..._be32(size),
      ];
      final List<int> bytes = [
        ...record('alpha', 10, 5),
        ...record('beta', 15, 4),
        ...record('gamma', 19, 6),
      ];
      // The first chunk ends four bytes into the first record's tail.
      final Stream<List<int>> chunks = Stream.fromIterable([
        bytes.sublist(0, 10),
        bytes.sublist(10),
      ]);

      final List<StarDictIdxRecord> records = await parseStarDictIdxChunks(
        chunks,
      ).toList();

      expect(
        records
            .map((StarDictIdxRecord r) => '${r.word}:${r.offset}:${r.size}')
            .toList(),
        ['alpha:10:5', 'beta:15:4', 'gamma:19:6'],
      );
    });

    test('reads .syn records when a chunk ends at the terminator', () async {
      List<int> record(String word, int index) => [
        ...utf8.encode(word),
        0,
        ..._be32(index),
      ];
      final List<int> bytes = [
        ...record('alpha', 10),
        ...record('beta', 15),
        ...record('gamma', 19),
      ];
      // The first chunk ends right after the first record's terminator.
      final Stream<List<int>> chunks = Stream.fromIterable([
        bytes.sublist(0, 6),
        bytes.sublist(6),
      ]);

      final List<StarDictSynRecord> records = await parseStarDictSynChunks(
        chunks,
      ).toList();

      expect(
        records.map((StarDictSynRecord r) => '${r.word}:${r.index}').toList(),
        ['alpha:10', 'beta:15', 'gamma:19'],
      );
    });

    test('throws on a truncated tail at the end of the stream', () async {
      final List<int> bytes = [...utf8.encode('alpha'), 0, 1, 2, 3];

      await expectLater(
        parseStarDictIdxChunks(Stream.value(bytes)).toList(),
        throwsA(isA<StarDictFormatException>()),
      );
    });

    test('throws on an unterminated word', () async {
      final List<int> bytes = List<int>.filled(70000, 0x61);

      await expectLater(
        parseStarDictIdxChunks(Stream.value(bytes)).toList(),
        throwsA(isA<StarDictFormatException>()),
      );
    });

    test('an empty stream yields no records', () async {
      expect(
        await parseStarDictIdxChunks(const Stream<List<int>>.empty()).toList(),
        isEmpty,
      );
      expect(
        await parseStarDictSynChunks(const Stream<List<int>>.empty()).toList(),
        isEmpty,
      );
    });
  });

  group('StarDictSource', () {
    test('reads entries from an uncompressed .dict', () async {
      final StarDictSource source = await makeSource(
        entries: {'cow': 'корова', 'bank': 'банк, берег'},
      );

      final entry = await source.lookup('  COW ');
      expect(entry, isNotNull);
      expect(entry!.textKey, 'cow');
      expect(entry.translation, 'корова');
      expect(await source.lookup('heifer'), isNull);
      expect(await source.lookup('   '), isNull);
      await source.dispose();
    });
    test('uses the sametypesequence meaning, not the transcription', () async {
      final StarDictSource source = await makeSource(
        entries: {'cow': 'корова'},
        transcriptions: {'cow': 'kaʊ'},
        sametypesequence: 'tm',
      );

      final entry = await source.lookup('cow');
      expect(entry!.translation, 'корова');
      expect(entry.transcription, 'kaʊ');
      await source.dispose();
    });

    test('exposes xdxf examples', () async {
      final StarDictSource source = await makeSource(
        entries: {'cow': 'корова'},
        examples: {
          'cow': ['a cow in the field'],
        },
        sametypesequence: 'x',
      );

      final entry = await source.lookup('cow');
      expect(entry!.translation, 'корова');
      expect(entry.examples, ['a cow in the field']);
      await source.dispose();
    });

    test('strips markup from html entries', () async {
      final StarDictSource source = await makeSource(
        entries: {'cow': '<b>корова</b>'},
        sametypesequence: 'h',
      );

      expect((await source.lookup('cow'))!.translation, 'корова');
      await source.dispose();
    });

    test('reads entries spanning dictzip chunks', () async {
      final StarDictSource source = await makeSource(
        entries: {'cow': 'корова с большим описанием, телёнок, бык'},
        dictZip: true,
        chunkLength: 8,
      );

      expect(
        (await source.lookup('cow'))!.translation,
        'корова с большим описанием, телёнок, бык',
      );
      await source.dispose();
    });

    test('resolves synonyms to the referenced entry', () async {
      final StarDictSource source = await makeSource(
        entries: {'cow': 'корова'},
        synonyms: {'cows': 0},
      );

      expect((await source.lookup('cows'))!.translation, 'корова');
      expect((await source.lookup('cow'))!.translation, 'корова');
      await source.dispose();
    });

    test('finds files with uppercase extensions (A-39)', () async {
      counter++;
      final Directory dir = Directory('${tempDir.path}/d$counter');
      await dir.create(recursive: true);
      final String ifoPath = await writeStarDict(
        dir: dir,
        entries: {'cow': 'корова'},
      );
      await File(ifoPath).rename(p.join(dir.path, 'testdict.IFO'));
      await File(
        p.join(dir.path, 'testdict.dict'),
      ).rename(p.join(dir.path, 'testdict.DICT'));
      final StarDictSource source = StarDictSource(dir);

      expect((await source.lookup('cow'))!.translation, 'корова');
      await source.dispose();
    });

    test('a missing dictionary fails loudly', () async {
      final Directory empty = Directory('${tempDir.path}/empty');
      await empty.create(recursive: true);
      final StarDictSource source = StarDictSource(empty);

      expect(
        () => source.lookup('cow'),
        throwsA(isA<StarDictFormatException>()),
      );
      await source.dispose();
    });

    test('a failed open is retried after the files appear (A-45)', () async {
      counter++;
      final Directory dir = Directory('${tempDir.path}/d$counter');
      await dir.create(recursive: true);
      final StarDictSource source = StarDictSource(dir);

      // No files yet: the first open fails.
      await expectLater(
        source.lookup('cow'),
        throwsA(isA<StarDictFormatException>()),
      );

      // The files appear (a retried transfer); lookup must recover.
      await writeStarDict(dir: dir, entries: {'cow': 'корова'});

      expect((await source.lookup('cow'))!.translation, 'корова');
      await source.dispose();
    });

    test('a truncated .dict fails instead of a partial entry (A-48)', () async {
      counter++;
      final Directory dir = Directory('${tempDir.path}/d$counter');
      await dir.create(recursive: true);
      await writeStarDict(dir: dir, entries: {'cow': 'корова'});
      final File dict = File(p.join(dir.path, 'testdict.dict'));
      final Uint8List body = await dict.readAsBytes();
      await dict.writeAsBytes(body.sublist(0, body.length - 2), flush: true);

      final StarDictSource source = StarDictSource(dir);
      await expectLater(
        source.lookup('cow'),
        throwsA(isA<StarDictFormatException>()),
      );
      await source.dispose();
    });

    test('a dictzip body with a wrong chunk table fails (A-48)', () async {
      counter++;
      final Directory dir = Directory('${tempDir.path}/d$counter');
      await dir.create(recursive: true);
      await writeStarDict(
        dir: dir,
        entries: {'cow': 'корова'},
        dictZip: true,
        chunkLength: 8,
      );
      // The RA field claims 32-byte chunks while the real chunks hold 8
      // bytes, so the second read step starts past the decompressed chunk.
      final File dz = File(p.join(dir.path, 'testdict.dict.dz'));
      final Uint8List bytes = await dz.readAsBytes();
      bytes[18] = 32; // RA chunk length (low byte)
      bytes[19] = 0;
      await dz.writeAsBytes(bytes, flush: true);

      final StarDictSource source = StarDictSource(dir);
      await expectLater(
        source.lookup('cow'),
        throwsA(isA<StarDictFormatException>()),
      );
      await source.dispose();
    });
  });
}

Uint8List _be32(int value) {
  return Uint8List(4)
    ..[0] = (value >> 24) & 0xff
    ..[1] = (value >> 16) & 0xff
    ..[2] = (value >> 8) & 0xff
    ..[3] = value & 0xff;
}
