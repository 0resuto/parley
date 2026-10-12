import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:parley/services/dictionary/stardict/stardict_index.dart';

/// Writes a small StarDict dictionary into [dir] and builds its index cache.
///
/// Returns the `.ifo` path. [sametypesequence] null stores every entry with
/// a leading `m` type byte; otherwise only the types `t` and `m` are
/// supported ([transcriptions] supplies the `t` values). [dictZip] stores
/// the body as a dictzip file with [chunkLength]-byte chunks.
Future<String> writeStarDict({
  required Directory dir,
  required Map<String, String> entries,
  String base = 'testdict',
  String bookName = 'Test Dictionary',
  String? sametypesequence,
  Map<String, String> transcriptions = const {},
  Map<String, List<String>> examples = const {},
  Map<String, int> synonyms = const {},
  bool dictZip = false,
  int chunkLength = 32,
  int? idxFileSize,
}) async {
  final BytesBuilder body = BytesBuilder();
  final BytesBuilder index = BytesBuilder();
  for (final MapEntry<String, String> entry in entries.entries) {
    final int offset = body.length;
    if (sametypesequence == null) {
      body.addByte(0x6d); // 'm'
      body.add(utf8.encode(entry.value));
      body.addByte(0);
    } else {
      final List<String> types = sametypesequence.split('');
      for (int i = 0; i < types.length; i++) {
        final bool isLast = i == types.length - 1;
        switch (types[i]) {
          case 't':
            body.add(utf8.encode(transcriptions[entry.key] ?? ''));
          case 'x':
            final StringBuffer xdxf = StringBuffer()
              ..write('<k>${entry.key}</k><def><tr>${entry.value}</tr>');
            for (final String example in examples[entry.key] ?? const []) {
              xdxf.write('<ex>$example</ex>');
            }
            xdxf.write('</def>');
            body.add(utf8.encode(xdxf.toString()));
          default:
            body.add(utf8.encode(entry.value));
        }
        if (!isLast) {
          body.addByte(0);
        }
      }
    }
    final int size = body.length - offset;
    index.add(utf8.encode(entry.key));
    index.addByte(0);
    index.add(_be32(offset));
    index.add(_be32(size));
  }

  final String ifoPath = p.join(dir.path, '$base.ifo');
  final File idxFile = File(p.join(dir.path, '$base.idx'));
  await idxFile.writeAsBytes(index.takeBytes(), flush: true);
  final File? synFile = synonyms.isEmpty
      ? null
      : File(p.join(dir.path, '$base.syn'));
  if (synFile != null) {
    final BytesBuilder syn = BytesBuilder();
    for (final MapEntry<String, int> entry in synonyms.entries) {
      syn.add(utf8.encode(entry.key));
      syn.addByte(0);
      syn.add(_be32(entry.value));
    }
    await synFile.writeAsBytes(syn.takeBytes(), flush: true);
  }
  final Uint8List bodyBytes = body.takeBytes();
  if (dictZip) {
    await File(
      p.join(dir.path, '$base.dict.dz'),
    ).writeAsBytes(_dictZip(bodyBytes, chunkLength), flush: true);
  } else {
    await File(
      p.join(dir.path, '$base.dict'),
    ).writeAsBytes(bodyBytes, flush: true);
  }

  final StringBuffer ifo = StringBuffer()
    ..writeln("StarDict's dict ifo file")
    ..writeln('version=2.4.2')
    ..writeln('bookname=$bookName')
    ..writeln('wordcount=${entries.length}')
    ..writeln('idxfilesize=${idxFileSize ?? await idxFile.length()}');
  if (sametypesequence != null) {
    ifo.writeln('sametypesequence=$sametypesequence');
  }
  if (synFile != null) {
    ifo.writeln('synwordcount=${synonyms.length}');
  }
  await File(ifoPath).writeAsString(ifo.toString(), flush: true);

  await buildStarDictIndexCache(
    idxFile: idxFile,
    synFile: synFile,
    cacheFile: File(p.join(dir.path, 'index.sqlite')),
  );
  return ifoPath;
}

Uint8List _be32(int value) {
  return Uint8List(4)
    ..[0] = (value >> 24) & 0xff
    ..[1] = (value >> 16) & 0xff
    ..[2] = (value >> 8) & 0xff
    ..[3] = value & 0xff;
}

/// Writes a small DSL dictionary into [dir] and returns the `.dsl` path.
///
/// [encoding] is `utf8` or `utf16le`; [transcriptions] adds `[..]` after
/// the headword. [indent] prefixes definition lines (tab by default).
Future<String> writeDsl({
  required Directory dir,
  required Map<String, String> entries,
  String base = 'testdict',
  String? header,
  Map<String, String> transcriptions = const {},
  String encoding = 'utf8',
  String indent = '\t',
}) async {
  final StringBuffer text = StringBuffer()
    ..writeln(header ?? '#NAME "Test Dictionary"');
  for (final MapEntry<String, String> entry in entries.entries) {
    final String transcription = transcriptions[entry.key] ?? '';
    text.writeln(
      '${entry.key}${transcription.isEmpty ? '' : ' [$transcription]'}',
    );
    text.writeln('$indent${entry.value}');
    text.writeln();
  }
  final String path = p.join(dir.path, '$base.dsl');
  if (encoding == 'utf16le') {
    final List<int> bytes = [0xFF, 0xFE];
    for (final int unit in text.toString().codeUnits) {
      bytes
        ..add(unit & 0xff)
        ..add((unit >> 8) & 0xff);
    }
    await File(path).writeAsBytes(bytes, flush: true);
  } else {
    await File(path).writeAsString(text.toString(), flush: true);
  }
  return path;
}

/// Packs [paths] into a zip archive and returns the archive path.
Future<String> zipFiles({
  required Directory dir,
  required String name,
  required List<String> paths,
}) async {
  final Archive archive = Archive();
  for (final String path in paths) {
    final List<int> bytes = await File(path).readAsBytes();
    archive.addFile(ArchiveFile(p.basename(path), bytes.length, bytes));
  }
  final List<int> encoded = ZipEncoder().encode(archive);
  final String zipPath = p.join(dir.path, name);
  await File(zipPath).writeAsBytes(encoded, flush: true);
  return zipPath;
}

/// Packs [paths] into a zip archive using [names] as the entry names.
///
/// Unlike [zipFiles], the entry names are kept verbatim (they may contain
/// directories or share a basename), which is what hostile archives look
/// like. `Archive.add` deduplicates by the full entry name, so distinct
/// names like `a/x.ifo` and `b/x.ifo` both survive.
Future<String> zipFilesAs({
  required Directory dir,
  required String name,
  required List<String> names,
  required List<String> paths,
}) async {
  final Archive archive = Archive();
  for (int i = 0; i < paths.length; i++) {
    final List<int> bytes = await File(paths[i]).readAsBytes();
    archive.addFile(ArchiveFile(names[i], bytes.length, bytes));
  }
  final List<int> encoded = ZipEncoder().encode(archive);
  final String zipPath = p.join(dir.path, name);
  await File(zipPath).writeAsBytes(encoded, flush: true);
  return zipPath;
}

Uint8List _dictZip(Uint8List body, int chunkLength) {
  final List<Uint8List> chunks = [];
  for (int start = 0; start < body.length; start += chunkLength) {
    final int end = start + chunkLength > body.length
        ? body.length
        : start + chunkLength;
    chunks.add(
      Uint8List.fromList(ZLibCodec(raw: true).encode(body.sublist(start, end))),
    );
  }
  final int raLength = 6 + 2 * chunks.length;
  final int extraLength = 4 + raLength;
  final BytesBuilder file = BytesBuilder();
  file.add([0x1f, 0x8b, 8, 0x04, 0, 0, 0, 0, 0, 3]);
  file.add([extraLength & 0xff, (extraLength >> 8) & 0xff]);
  file.add(utf8.encode('RA'));
  file.add([raLength & 0xff, (raLength >> 8) & 0xff]);
  file.add([1, 0]); // version
  file.add([chunkLength & 0xff, (chunkLength >> 8) & 0xff]);
  file.add([chunks.length & 0xff, (chunks.length >> 8) & 0xff]);
  for (final Uint8List chunk in chunks) {
    file.add([chunk.length & 0xff, (chunk.length >> 8) & 0xff]);
  }
  for (final Uint8List chunk in chunks) {
    file.add(chunk);
  }
  file.add([0, 0, 0, 0, 0, 0, 0, 0]); // CRC32 + ISIZE (not validated)
  return file.takeBytes();
}
