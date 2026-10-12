import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:parley/services/dictionary/dsl/dsl_index.dart';
import 'package:parley/services/dictionary/stardict/dict_reader.dart';
import 'package:parley/services/dictionary/stardict/stardict_index.dart';
import 'package:parley/services/dictionary/stardict/stardict_metadata.dart';

/// Phase of a running import (SPEC 5.12).
enum ImportPhase { extracting, copying, indexing }

/// Progress of a running import; [fraction] is null while indeterminate.
class DictionaryImportProgress {
  const DictionaryImportProgress({required this.phase, this.fraction});

  final ImportPhase phase;
  final double? fraction;
}

/// One import job: the picked paths and the prepared destination directory.
class ImportRequest {
  const ImportRequest({required this.paths, required this.destinationDir});

  final List<String> paths;
  final String destinationDir;
}

enum ImportOutcomeKind { success, cancelled, failure }

/// Result of one import job (isolate-friendly plain data).
class ImportOutcome {
  const ImportOutcome._(
    this.kind, {
    this.name,
    this.wordCount,
    this.format,
    this.message,
  });

  const ImportOutcome.success({
    required String name,
    required int wordCount,
    required String format,
  }) : this._(
         ImportOutcomeKind.success,
         name: name,
         wordCount: wordCount,
         format: format,
       );

  const ImportOutcome.cancelled() : this._(ImportOutcomeKind.cancelled);

  const ImportOutcome.failure(String message)
    : this._(ImportOutcomeKind.failure, message: message);

  final ImportOutcomeKind kind;
  final String? name;
  final int? wordCount;
  final String? format;
  final String? message;
}

/// Runs one dictionary import (SPEC 5.12).
///
/// Pure file work: extracts an optional single `.zip` archive, detects one
/// StarDict or DSL dictionary, copies its files into
/// [ImportRequest.destinationDir] unchanged and builds the lookup cache.
/// Returns a failure outcome instead of throwing so it can run in an
/// isolate; the caller cleans the destination directory up.
///
/// [maxArchiveEntries] and [maxExtractedBytes] cap `.zip` extraction (A-41)
/// so a hostile archive cannot fill the disk or the file table; tests pass
/// small values.
Future<ImportOutcome> runDictionaryImport(
  ImportRequest request, {
  void Function(DictionaryImportProgress)? onProgress,
  int maxArchiveEntries = 100,
  int maxExtractedBytes = 512 * 1024 * 1024,
}) async {
  final Directory destination = Directory(request.destinationDir);
  Directory? extractDir;
  try {
    await destination.create(recursive: true);
    List<String> effective = request.paths;
    final List<String> zips = [
      for (final String path in request.paths)
        if (p.extension(path).toLowerCase() == '.zip') path,
    ];
    if (zips.isNotEmpty) {
      if (zips.length > 1 || request.paths.length != zips.length) {
        throw const _ImportFailure(
          'Select one .zip archive or the dictionary files.',
        );
      }
      extractDir = Directory('${destination.path}.extract');
      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      await extractDir.create(recursive: true);
      effective = await _extractZip(
        File(zips.single),
        extractDir,
        onProgress,
        maxEntries: maxArchiveEntries,
        maxBytes: maxExtractedBytes,
      );
    }
    final List<String> ifos = [
      for (final String path in effective)
        if (p.extension(path).toLowerCase() == '.ifo') path,
    ];
    final List<String> dsls = [
      for (final String path in effective)
        if (p.extension(path).toLowerCase() == '.dsl') path,
    ];
    if (ifos.isEmpty && dsls.isEmpty) {
      throw const _ImportFailure(
        'Select a StarDict .ifo file or a .dsl file '
        '(optionally inside a single .zip archive).',
      );
    }
    if (ifos.length + dsls.length != 1) {
      throw const _ImportFailure(
        'The selection contains more than one dictionary.',
      );
    }
    if (ifos.isNotEmpty) {
      return await _importStarDict(
        ifos.single,
        effective,
        destination,
        onProgress,
      );
    }
    return await _importDsl(dsls.single, destination, onProgress);
  } on _ImportFailure catch (e) {
    return ImportOutcome.failure(e.message);
  } on StarDictFormatException catch (e) {
    return ImportOutcome.failure(e.message);
  } on ArchiveException {
    return ImportOutcome.failure('The .zip archive could not be read.');
  } on FormatException {
    // A non-UTF-8 `.ifo` or `.dsl` is a user-fixable file problem, not
    // an internal failure (A-46).
    return ImportOutcome.failure(
      'The dictionary file is not valid UTF-8 text.',
    );
  } catch (_) {
    return ImportOutcome.failure('Import failed.');
  } finally {
    try {
      if (extractDir != null && await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort cleanup of the extraction directory.
    }
  }
}

Future<List<String>> _extractZip(
  File zip,
  Directory target,
  void Function(DictionaryImportProgress)? onProgress, {
  required int maxEntries,
  required int maxBytes,
}) async {
  final int total = await zip.length();
  final InputFileStream input = InputFileStream(zip.path);
  final List<String> paths = [];
  final Set<String> names = <String>{};
  int extracted = 0;
  try {
    final Archive archive = ZipDecoder().decodeStream(input);
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) {
        continue;
      }
      final String name = p.basename(file.name);
      // Skip empty names, macOS metadata folders and AppleDouble forks:
      // `._x.ifo` would otherwise count as a second dictionary.
      if (name.isEmpty ||
          name.startsWith('._') ||
          file.name.startsWith('__MACOSX')) {
        continue;
      }
      if (!names.add(name)) {
        throw const _ImportFailure(
          'The .zip archive contains duplicate file names.',
        );
      }
      if (names.length > maxEntries) {
        throw const _ImportFailure('The .zip archive contains too many files.');
      }
      if (extracted + file.size > maxBytes) {
        throw const _ImportFailure('The .zip archive is too large to extract.');
      }
      final String out = p.join(target.path, name);
      final OutputFileStream output = OutputFileStream(out);
      file.writeContent(output);
      output.close();
      paths.add(out);
      extracted += file.size;
      onProgress?.call(
        DictionaryImportProgress(
          phase: ImportPhase.extracting,
          fraction: total == 0 ? null : (extracted / total).clamp(0.0, 1.0),
        ),
      );
    }
  } finally {
    input.close();
  }
  return paths;
}

Future<ImportOutcome> _importStarDict(
  String ifoPath,
  List<String> effective,
  Directory destination,
  void Function(DictionaryImportProgress)? onProgress,
) async {
  final File ifo = File(ifoPath);
  final String base = p.basenameWithoutExtension(ifo.path);
  final File? idx = _pick(effective, base, '.idx');
  File? dictZip = _pick(effective, base, '.dict.dz');
  final File? dict = dictZip != null ? null : _pick(effective, base, '.dict');
  final File? syn = _pick(effective, base, '.syn');
  if (idx == null) {
    throw const _ImportFailure(
      'Select the .idx file together with the .ifo file.',
    );
  }
  if (dictZip == null && dict == null) {
    throw const _ImportFailure(
      'Select the .dict or .dict.dz file together with the .ifo file.',
    );
  }
  // Decode explicitly: `readAsString` wraps a decode failure in a
  // `FileSystemException`, which would surface as "Import failed." (A-46).
  final StarDictMetadata metadata = parseStarDictIfo(
    utf8.decode(await ifo.readAsBytes()),
  );
  final int idxLength = await idx.length();
  if (metadata.idxFileSize != null && idxLength != metadata.idxFileSize) {
    throw const _ImportFailure(
      'The .idx file does not match the .ifo file (size mismatch).',
    );
  }
  if (dictZip != null) {
    final DictZipReader probe = DictZipReader(dictZip);
    try {
      await probe.open();
    } finally {
      await probe.close();
    }
  }

  final List<File> copies = [ifo, idx, ?dict, ?dictZip, ?syn];
  await _copyFiles(copies, destination, onProgress);
  await buildStarDictIndexCache(
    idxFile: File(p.join(destination.path, p.basename(idx.path))),
    synFile: syn == null
        ? null
        : File(p.join(destination.path, p.basename(syn.path))),
    cacheFile: File(p.join(destination.path, 'index.sqlite')),
    expectedWords: metadata.wordCount,
    onProgress: (double fraction) => onProgress?.call(
      DictionaryImportProgress(phase: ImportPhase.indexing, fraction: fraction),
    ),
  );
  final String name = metadata.bookName.isEmpty ? base : metadata.bookName;
  return ImportOutcome.success(
    name: name,
    wordCount: metadata.wordCount,
    format: 'stardict',
  );
}

Future<ImportOutcome> _importDsl(
  String dslPath,
  Directory destination,
  void Function(DictionaryImportProgress)? onProgress,
) async {
  final File dsl = File(dslPath);
  await _copyFiles([dsl], destination, onProgress);
  final int wordCount = await buildDslIndexCache(
    dslFile: File(p.join(destination.path, p.basename(dsl.path))),
    cacheFile: File(p.join(destination.path, 'index.sqlite')),
    onProgress: (double fraction) => onProgress?.call(
      DictionaryImportProgress(phase: ImportPhase.indexing, fraction: fraction),
    ),
  );
  if (wordCount <= 0) {
    throw const _ImportFailure('The .dsl file has no entries.');
  }
  return ImportOutcome.success(
    name: p.basenameWithoutExtension(dsl.path),
    wordCount: wordCount,
    format: 'dsl',
  );
}

File? _pick(List<String> paths, String base, String extension) {
  // StarDict archives often carry uppercase extensions (`NAME.IDX`);
  // match names case-insensitively.
  final String lowerBase = base.toLowerCase();
  for (final String path in paths) {
    final String name = p.basename(path).toLowerCase();
    if (!name.startsWith('$lowerBase.')) {
      continue;
    }
    if (extension == '.dict.dz' && name.endsWith('.dict.dz')) {
      return File(path);
    }
    if (extension == '.dict' &&
        name.endsWith('.dict') &&
        !name.endsWith('.dict.dz')) {
      return File(path);
    }
    if (extension == '.idx' && name.endsWith('.idx')) {
      return File(path);
    }
    if (extension == '.syn' && name.endsWith('.syn')) {
      return File(path);
    }
  }
  return null;
}

Future<void> _copyFiles(
  List<File> files,
  Directory destination,
  void Function(DictionaryImportProgress)? onProgress,
) async {
  int total = 0;
  for (final File file in files) {
    total += await file.length();
  }
  int copied = 0;
  for (final File file in files) {
    final RandomAccessFile input = await file.open();
    final IOSink output = File(
      p.join(destination.path, p.basename(file.path)),
    ).openWrite();
    try {
      while (true) {
        final Uint8List chunk = await input.read(1 << 16);
        if (chunk.isEmpty) {
          break;
        }
        output.add(chunk);
        copied += chunk.length;
        onProgress?.call(
          DictionaryImportProgress(
            phase: ImportPhase.copying,
            fraction: total == 0 ? null : (copied / total).clamp(0.0, 1.0),
          ),
        );
      }
      await output.flush();
    } finally {
      await output.close();
      await input.close();
    }
  }
}

class _ImportFailure implements Exception {
  const _ImportFailure(this.message);

  final String message;
}
