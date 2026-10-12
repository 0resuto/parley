import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'stardict_metadata.dart';

/// Random-access reads into the body of a StarDict dictionary.
abstract class DictReader {
  /// Reads [size] bytes starting at [offset] of the uncompressed body.
  ///
  /// Throws [StarDictFormatException] when the body is truncated and fewer
  /// than [size] bytes are available (A-48).
  Future<Uint8List> read(int offset, int size);

  Future<void> close();
}

/// Uncompressed `.dict` reader.
class PlainDictReader implements DictReader {
  PlainDictReader(this._file);

  final File _file;
  RandomAccessFile? _handle;

  Future<RandomAccessFile> _open() async => _handle ??= await _file.open();

  @override
  Future<Uint8List> read(int offset, int size) async {
    final RandomAccessFile handle = await _open();
    await handle.setPosition(offset);
    final Uint8List data = await handle.read(size);
    if (data.length != size) {
      // A short read means the body is truncated; parsing the partial
      // bytes would surface a cut-off translation (A-48).
      throw const StarDictFormatException('The .dict file is truncated.');
    }
    return data;
  }

  @override
  Future<void> close() async {
    await _handle?.close();
    _handle = null;
  }
}

/// Dictzip (`.dict.dz`) reader.
///
/// A dictzip file is one gzip member whose deflate data is a sequence of
/// independently compressed chunks; the `RA` extra field lists the
/// compressed size of every chunk, which makes random access possible
/// without decompressing the whole file.
class DictZipReader implements DictReader {
  DictZipReader(this._file);

  final File _file;
  RandomAccessFile? _handle;
  bool _headerParsed = false;
  int _chunkLength = 0;
  List<int> _chunkOffsets = const [];
  int _cachedIndex = -1;
  Uint8List _cachedChunk = Uint8List(0);

  Future<RandomAccessFile> _open() async => _handle ??= await _file.open();

  /// Parses the header; throws [StarDictFormatException] when the file is
  /// not a dictzip archive.
  Future<void> open() async {
    if (_headerParsed) {
      return;
    }
    final RandomAccessFile handle = await _open();
    final Uint8List header = await handle.read(10);
    if (header.length < 10 ||
        header[0] != 0x1f ||
        header[1] != 0x8b ||
        header[2] != 8) {
      throw const StarDictFormatException(
        'The .dict.dz file is not a gzip file.',
      );
    }
    final int flags = header[3];
    int position = 10;
    List<int>? raField;
    if (flags & 0x04 != 0) {
      await handle.setPosition(position);
      final Uint8List lengthBytes = await handle.read(2);
      final int extraLength = lengthBytes[0] | (lengthBytes[1] << 8);
      position += 2;
      final Uint8List extra = await handle.read(extraLength);
      int index = 0;
      while (index + 4 <= extra.length) {
        final int length = extra[index + 2] | (extra[index + 3] << 8);
        if (extra[index] == 0x52 && extra[index + 1] == 0x41) {
          final int end = math.min(index + 4 + length, extra.length);
          raField = extra.sublist(index + 4, end);
        }
        index += 4 + length;
      }
      position += extraLength;
    }
    if (flags & 0x08 != 0) {
      position += await _skipZeroTerminated(handle, position);
    }
    if (flags & 0x10 != 0) {
      position += await _skipZeroTerminated(handle, position);
    }
    if (flags & 0x02 != 0) {
      position += 2;
    }
    if (raField == null || raField.length < 6) {
      throw const StarDictFormatException(
        'The .dict.dz file is not in dictzip format; '
        'provide an uncompressed .dict file instead.',
      );
    }
    _chunkLength = raField[2] | (raField[3] << 8);
    final int chunkCount = raField[4] | (raField[5] << 8);
    if (_chunkLength <= 0 || raField.length < 6 + 2 * chunkCount) {
      throw const StarDictFormatException(
        'The .dict.dz chunk table is malformed.',
      );
    }
    final List<int> sizes = [
      for (int i = 0; i < chunkCount; i++)
        raField[6 + 2 * i] | (raField[7 + 2 * i] << 8),
    ];
    final List<int> offsets = [];
    int accumulated = position;
    for (final int size in sizes) {
      offsets.add(accumulated);
      accumulated += size;
    }
    _chunkOffsets = offsets;
    _headerParsed = true;
  }

  Future<int> _skipZeroTerminated(RandomAccessFile handle, int position) async {
    await handle.setPosition(position);
    int skipped = 0;
    while (true) {
      final Uint8List byte = await handle.read(1);
      if (byte.isEmpty || byte[0] == 0) {
        return skipped + 1;
      }
      skipped++;
    }
  }

  Future<Uint8List> _chunk(int index) async {
    if (index == _cachedIndex) {
      return _cachedChunk;
    }
    final RandomAccessFile handle = await _open();
    final int start = _chunkOffsets[index];
    final int end = index + 1 < _chunkOffsets.length
        ? _chunkOffsets[index + 1]
        : (await handle.length()) - 8;
    await handle.setPosition(start);
    final Uint8List compressed = await handle.read(end - start);
    final Uint8List data = Uint8List.fromList(
      ZLibCodec(raw: true).decode(compressed),
    );
    _cachedIndex = index;
    _cachedChunk = data;
    return data;
  }

  @override
  Future<Uint8List> read(int offset, int size) async {
    await open();
    final BytesBuilder output = BytesBuilder();
    int position = offset;
    int remaining = size;
    while (remaining > 0) {
      final int index = position ~/ _chunkLength;
      if (index >= _chunkOffsets.length) {
        throw const StarDictFormatException('The .dict.dz file is truncated.');
      }
      final Uint8List chunk = await _chunk(index);
      final int inChunk = position - index * _chunkLength;
      final int take = math.min(remaining, chunk.length - inChunk);
      if (take <= 0) {
        // The decompressed chunk is shorter than the chunk table promises
        // (A-48): a short read must not parse as a valid entry.
        throw const StarDictFormatException('The .dict.dz file is truncated.');
      }
      output.add(chunk.sublist(inChunk, inChunk + take));
      position += take;
      remaining -= take;
    }
    return output.takeBytes();
  }

  @override
  Future<void> close() async {
    await _handle?.close();
    _handle = null;
  }
}
