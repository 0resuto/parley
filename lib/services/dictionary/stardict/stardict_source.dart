import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'package:parley/data/models/unit.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';
import 'package:parley/services/dictionary/stardict/dict_reader.dart';
import 'package:parley/services/dictionary/stardict/stardict_entry.dart';
import 'package:parley/services/dictionary/stardict/stardict_metadata.dart';

/// Reads one dictionary kept as StarDict files (SPEC 5.12).
///
/// Lookups go through the per-dictionary `index.sqlite` cache and read a
/// single entry from the body (`.dict` or dictzip `.dict.dz`), so the
/// original files are never rewritten.
class StarDictSource implements DictionaryService {
  StarDictSource(this.directory);

  final Directory directory;
  StarDictMetadata? _metadata;
  QueryExecutor? _index;
  DictReader? _dict;
  Future<void>? _opening;

  @override
  Future<DictionaryEntry?> lookup(String wordKey) async {
    final String key = normalizeKey(wordKey);
    if (key.isEmpty) {
      return null;
    }
    await _open();
    final List<Map<String, Object?>> rows = await _index!.runSelect(
      'SELECT offset, size FROM entries WHERE text_key = ? LIMIT 1',
      [key],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Object? offset = rows.first['offset'];
    final Object? size = rows.first['size'];
    if (offset is! int || size is! int || offset < 0 || size <= 0) {
      return null;
    }
    final Uint8List data = await _dict!.read(offset, size);
    final StarDictEntryContent? content = parseStarDictEntry(
      data,
      _metadata!.sametypesequence,
    );
    if (content == null || content.text.isEmpty) {
      return null;
    }
    return DictionaryEntry(
      textKey: key,
      translation: content.text,
      transcription: content.transcription,
      examples: content.examples,
    );
  }

  Future<void> _open() {
    return _opening ??= _doOpen().onError<Object>((
      Object error,
      StackTrace stack,
    ) {
      // Do not cache a failed open (A-45): a transient problem (a file
      // still being transferred, a lock) must not kill the dictionary
      // until dispose.
      _opening = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _doOpen() async {
    final File? ifo = await _find((String name) => name.endsWith('.ifo'));
    final File cache = File(p.join(directory.path, 'index.sqlite'));
    final File? dictZip = await _find(
      (String name) => name.endsWith('.dict.dz'),
    );
    final File? dict = dictZip != null
        ? null
        : await _find((String name) => name.endsWith('.dict'));
    if (ifo == null ||
        !await cache.exists() ||
        (dictZip == null && dict == null)) {
      throw const StarDictFormatException('The dictionary files are missing.');
    }
    final StarDictMetadata metadata = parseStarDictIfo(
      await ifo.readAsString(),
    );
    final QueryExecutor index = NativeDatabase(cache);
    await index.ensureOpen(const DictionaryExecutorUser());
    final DictReader reader = dictZip != null
        ? DictZipReader(dictZip)
        : PlainDictReader(dict!);
    _metadata = metadata;
    _index = index;
    _dict = reader;
  }

  Future<File?> _find(bool Function(String name) matches) async {
    if (!await directory.exists()) {
      return null;
    }
    await for (final FileSystemEntity entity in directory.list()) {
      // Extensions are matched case-insensitively: archives may store
      // `NAME.IFO` or `NAME.DICT.DZ`.
      if (entity is File && matches(p.basename(entity.path).toLowerCase())) {
        return entity;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    await _dict?.close();
    _dict = null;
    await _index?.close();
    _index = null;
    _metadata = null;
    _opening = null;
  }
}
