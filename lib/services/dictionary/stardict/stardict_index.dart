import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';

import 'package:parley/data/models/unit.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/stardict/stardict_metadata.dart';

/// One `.idx` record: the word and its entry location in the body.
class StarDictIdxRecord {
  const StarDictIdxRecord({
    required this.word,
    required this.offset,
    required this.size,
  });

  final String word;
  final int offset;
  final int size;
}

/// One `.syn` record: an alternative spelling pointing at an `.idx` record.
class StarDictSynRecord {
  const StarDictSynRecord({required this.word, required this.index});

  final String word;
  final int index;
}

/// Streams the records of a `.idx` file (word, 4-byte offset, 4-byte size).
Stream<StarDictIdxRecord> parseStarDictIdx(File file) {
  return parseStarDictIdxChunks(file.openRead());
}

/// Streams `.idx` records from an arbitrary byte-chunk stream.
///
/// Tests use it to control where chunk boundaries fall; production code
/// reads files through [parseStarDictIdx].
Stream<StarDictIdxRecord> parseStarDictIdxChunks(Stream<List<int>> chunks) {
  return _parseRecords(chunks, 8, (String word, List<int> tail) {
    final int offset = _readUint32(tail, 0);
    final int size = _readUint32(tail, 4);
    return StarDictIdxRecord(word: word, offset: offset, size: size);
  });
}

/// Streams the records of a `.syn` file (word, 4-byte `.idx` index).
Stream<StarDictSynRecord> parseStarDictSyn(File file) {
  return parseStarDictSynChunks(file.openRead());
}

/// Streams `.syn` records from an arbitrary byte-chunk stream.
///
/// Tests use it to control where chunk boundaries fall; production code
/// reads files through [parseStarDictSyn].
Stream<StarDictSynRecord> parseStarDictSynChunks(Stream<List<int>> chunks) {
  return _parseRecords(chunks, 4, (String word, List<int> tail) {
    return StarDictSynRecord(word: word, index: _readUint32(tail, 0));
  });
}

int _readUint32(List<int> bytes, int position) {
  return (bytes[position] << 24) |
      (bytes[position + 1] << 16) |
      (bytes[position + 2] << 8) |
      bytes[position + 3];
}

/// Parses null-terminated word records followed by a fixed-size tail.
///
/// Works on a stream of byte chunks, so even multi-million-entry indexes
/// need no more memory than one record plus a small buffer.
Stream<T> _parseRecords<T>(
  Stream<List<int>> chunks,
  int tailLength,
  T Function(String word, List<int> tail) build,
) async* {
  final List<int> pending = [];
  int start = 0;
  int scan = 0;
  await for (final List<int> chunk in chunks) {
    pending.addAll(chunk);
    while (true) {
      int zero = -1;
      for (int i = scan; i < pending.length; i++) {
        if (pending[i] == 0) {
          zero = i;
          break;
        }
      }
      if (zero < 0) {
        scan = pending.length;
        if (scan - start > 1 << 16) {
          throw const StarDictFormatException(
            'The index file has an unterminated word.',
          );
        }
        break;
      }
      if (pending.length - zero - 1 < tailLength) {
        scan = zero;
        break;
      }
      final String word = utf8.decode(
        pending.sublist(start, zero),
        allowMalformed: true,
      );
      final List<int> tail = pending.sublist(zero + 1, zero + 1 + tailLength);
      yield build(word, tail);
      start = scan = zero + 1 + tailLength;
    }
    if (start > 1 << 16) {
      pending.removeRange(0, start);
      scan -= start;
      start = 0;
    }
  }
  if (pending.length > start) {
    throw const StarDictFormatException('The index file is truncated.');
  }
}

/// Number of rows per multi-row INSERT while building the cache.
const int _rowsPerInsert = 400;

/// Builds the per-dictionary lookup cache (`index.sqlite`) from `.idx`
/// (and `.syn`) files (SPEC 5.12).
///
/// The cache maps the normalized word to the entry location in the body;
/// the original files stay untouched. Duplicate keys keep the first
/// occurrence (`.idx` words win over `.syn` spellings). [onProgress]
/// receives the fraction of [expectedWords] processed, when provided.
Future<void> buildStarDictIndexCache({
  required File idxFile,
  File? synFile,
  required File cacheFile,
  int? expectedWords,
  void Function(double fraction)? onProgress,
}) async {
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  final NativeDatabase executor = NativeDatabase(cacheFile);
  try {
    await executor.ensureOpen(const DictionaryExecutorUser());
    await executor.runCustom(
      'CREATE TABLE entries ('
      'text_key TEXT PRIMARY KEY, '
      'offset INTEGER NOT NULL, '
      'size INTEGER NOT NULL)',
    );
    final List<int> offsets = [];
    final List<int> sizes = [];
    final List<Object?> buffer = [];

    Future<void> flush() async {
      if (buffer.isEmpty) {
        return;
      }
      final int rows = buffer.length ~/ 3;
      final String placeholders = List.filled(rows, '(?, ?, ?)').join(', ');
      await executor.runCustom(
        'INSERT OR IGNORE INTO entries (text_key, offset, size) '
        'VALUES $placeholders',
        List<Object?>.of(buffer),
      );
      buffer.clear();
    }

    Future<void> add(String word, int offset, int size) async {
      final String key = normalizeKey(word);
      if (key.isEmpty) {
        return;
      }
      buffer.addAll([key, offset, size]);
      if (buffer.length >= 3 * _rowsPerInsert) {
        await flush();
      }
    }

    int processed = 0;
    await for (final StarDictIdxRecord record in parseStarDictIdx(idxFile)) {
      offsets.add(record.offset);
      sizes.add(record.size);
      await add(record.word, record.offset, record.size);
      processed++;
      if (processed % 2000 == 0 && expectedWords != null) {
        onProgress?.call((processed / expectedWords).clamp(0.0, 1.0));
      }
    }
    await flush();
    if (synFile != null && await synFile.exists()) {
      await for (final StarDictSynRecord record in parseStarDictSyn(synFile)) {
        if (record.index < 0 || record.index >= offsets.length) {
          continue;
        }
        await add(record.word, offsets[record.index], sizes[record.index]);
      }
      await flush();
    }
    onProgress?.call(1);
  } finally {
    await executor.close();
  }
}
