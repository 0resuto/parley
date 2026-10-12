import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:parley/core/clock.dart';
import 'package:parley/data/repositories/user_dictionary_repository.dart';
import 'package:parley/services/dictionary/dictionary_file_store.dart';
import 'package:parley/services/dictionary/import/import_runner.dart';
import 'package:parley/services/dictionary/import/import_worker.dart';

/// Raised when the picked files are not a usable dictionary.
class DictionaryImportException implements Exception {
  const DictionaryImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Raised when the user cancelled a running import.
class DictionaryImportCancelledException implements Exception {
  const DictionaryImportCancelledException();
}

/// Result of importing one dictionary.
class DictionaryImportSummary {
  const DictionaryImportSummary({required this.name, required this.wordCount});

  final String name;
  final int wordCount;
}

/// Import seam (SPEC 5.12); widget tests fake this.
abstract class DictionaryImporter {
  /// Validates and stores the dictionary described by [paths].
  ///
  /// [onProgress] reports the phases of the background job. Throws
  /// [DictionaryImportException] for unusable selections and
  /// [DictionaryImportCancelledException] after [cancelImport].
  Future<DictionaryImportSummary> importFiles(
    List<String> paths, {
    required String targetLang,
    void Function(DictionaryImportProgress)? onProgress,
  });

  /// Aborts the running import; the pending [importFiles] throws
  /// [DictionaryImportCancelledException].
  void cancelImport();
}

/// Orchestrates dictionary imports (SPEC 5.12).
///
/// The file work runs in a background isolate (via [DictionaryImportRunner]);
/// this class prepares the destination directory, stores the metadata and
/// cleans up after failures and cancellations.
class FileDictionaryImporter implements DictionaryImporter {
  FileDictionaryImporter({
    required UserDictionaryRepository dictionaries,
    required DictionaryFileStore files,
    required Clock clock,
    required DictionaryImportRunner runner,
  }) : _dictionaries = dictionaries,
       _files = files,
       _clock = clock,
       _runner = runner;

  final UserDictionaryRepository _dictionaries;
  final DictionaryFileStore _files;
  final Clock _clock;
  final DictionaryImportRunner _runner;

  @override
  Future<DictionaryImportSummary> importFiles(
    List<String> paths, {
    required String targetLang,
    void Function(DictionaryImportProgress)? onProgress,
  }) async {
    final String language = targetLang.trim().toLowerCase();
    if (language.isEmpty) {
      throw const DictionaryImportException(
        'Set the meaning language for the dictionary.',
      );
    }
    if (paths.isEmpty) {
      throw const DictionaryImportException('No files were selected.');
    }
    final Directory root = await _files.root();
    await root.create(recursive: true);
    final Directory destination = await _newDirectory(root);
    final ImportOutcome outcome = await _runner.run(
      ImportRequest(paths: paths, destinationDir: destination.path),
      onProgress: onProgress,
    );
    if (outcome.kind == ImportOutcomeKind.cancelled) {
      await _cleanup(destination);
      throw const DictionaryImportCancelledException();
    }
    if (outcome.kind == ImportOutcomeKind.failure) {
      await _cleanup(destination);
      throw DictionaryImportException(outcome.message ?? 'Import failed.');
    }
    try {
      await _dictionaries.add(
        name: outcome.name!,
        path: destination.path,
        targetLang: language,
        wordCount: outcome.wordCount!,
        format: outcome.format!,
      );
    } catch (_) {
      await _cleanup(destination);
      rethrow;
    }
    return DictionaryImportSummary(
      name: outcome.name!,
      wordCount: outcome.wordCount!,
    );
  }

  @override
  void cancelImport() => _runner.cancel();

  Future<Directory> _newDirectory(Directory root) async {
    final int stamp = _clock.now().millisecondsSinceEpoch;
    Directory destination = Directory(p.join(root.path, '$stamp'));
    int suffix = 1;
    while (await destination.exists()) {
      destination = Directory(p.join(root.path, '${stamp}_$suffix'));
      suffix++;
    }
    await destination.create(recursive: true);
    return destination;
  }

  Future<void> _cleanup(Directory destination) async {
    for (final String path in [
      destination.path,
      '${destination.path}.extract',
    ]) {
      try {
        final Directory directory = Directory(path);
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } catch (_) {
        // Best-effort cleanup; the import error is what matters.
      }
    }
  }
}
