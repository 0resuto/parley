import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'stt_engine.dart';
import 'stt_model.dart';

/// Lifecycle of one offline model.
enum SttModelPhase {
  notDownloaded,
  downloading,
  verifying,
  extracting,
  ready,
  failed,
}

/// Current state of one offline model.
class SttModelStatus {
  const SttModelStatus({
    this.phase = SttModelPhase.notDownloaded,
    this.progress = 0,
    this.error,
  });

  final SttModelPhase phase;

  /// Download progress in the range 0..1.
  final double progress;

  /// User-visible failure text for [SttModelPhase.failed].
  final String? error;

  bool get isReady => phase == SttModelPhase.ready;

  bool get isBusy =>
      phase == SttModelPhase.downloading ||
      phase == SttModelPhase.verifying ||
      phase == SttModelPhase.extracting;
}

/// A model operation failed with a user-visible message.
class SttModelException implements Exception {
  const SttModelException(this.userMessage);

  final String userMessage;

  @override
  String toString() => 'SttModelException: $userMessage';
}

/// The user canceled an in-flight download.
class SttModelCanceledException implements Exception {
  const SttModelCanceledException();
}

/// Downloads a model archive behind an interface, so tests avoid the network.
abstract class SttFileDownloader {
  Future<void> download(
    String url,
    File destination, {
    required void Function(int received, int total) onProgress,
  });

  Future<void> cancel();
}

/// [SttFileDownloader] backed by Dio.
class DioFileDownloader implements SttFileDownloader {
  DioFileDownloader([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;
  CancelToken? _cancelToken;

  @override
  Future<void> download(
    String url,
    File destination, {
    required void Function(int received, int total) onProgress,
  }) async {
    final CancelToken token = _cancelToken = CancelToken();
    try {
      await _dio.download(
        url,
        destination.path,
        cancelToken: token,
        onReceiveProgress: onProgress,
        options: Options(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 10),
          headers: <String, String>{'User-Agent': 'Parley'},
        ),
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw const SttModelCanceledException();
      }
      rethrow;
    } finally {
      if (identical(_cancelToken, token)) {
        _cancelToken = null;
      }
    }
  }

  @override
  Future<void> cancel() async {
    _cancelToken?.cancel();
  }
}

/// Unpacks a model archive behind an interface, so tests can fake the IO.
abstract class SttArchiveExtractor {
  Future<void> extract(SttModel model, File archive, Directory destination);
}

/// Extracts only the required files from the sherpa-onnx `.tar.bz2` archive.
class ArchiveModelExtractor implements SttArchiveExtractor {
  @override
  Future<void> extract(
    SttModel model,
    File archive,
    Directory destination,
  ) async {
    final String archivePath = archive.path;
    final String destinationPath = destination.path;
    final String root = model.archiveRoot;
    final List<String> files = List<String>.of(model.files);
    try {
      await Isolate.run(
        () => _extractModelArchive(archivePath, destinationPath, root, files),
      );
    } catch (_) {
      throw const SttModelException(
        'The model archive could not be unpacked. Try downloading it again.',
      );
    }
  }
}

void _extractModelArchive(
  String archivePath,
  String destinationPath,
  String root,
  List<String> files,
) {
  final String prefix = '$root/';
  final Set<String> wanted = files.toSet();
  final Directory destination = Directory(destinationPath);
  final InputFileStream input = InputFileStream(archivePath);
  try {
    final InputStream decompressed = BZip2Decoder().decodeLazy(
      input,
      verify: true,
    );
    TarDecoder().decodeStream(
      decompressed,
      verify: true,
      storeData: true,
      keepEntries: false,
      callback: (ArchiveFile entry) {
        if (!entry.isFile || !entry.name.startsWith(prefix)) {
          return;
        }
        final String relative = p.posix.normalize(
          entry.name.substring(prefix.length),
        );
        if (relative.isEmpty ||
            relative == '.' ||
            relative.startsWith('..') ||
            p.posix.isAbsolute(relative) ||
            !wanted.contains(relative)) {
          return;
        }
        final File output = File(
          p.joinAll(<String>[destination.path, ...p.posix.split(relative)]),
        );
        if (!p.isWithin(destination.path, output.path)) {
          throw const SttModelException(
            'The model archive is not safe to unpack.',
          );
        }
        output.parent.createSync(recursive: true);
        final OutputFileStream out = OutputFileStream(output.path);
        try {
          entry.writeContent(out);
        } finally {
          out.closeSync();
        }
      },
    );
  } finally {
    input.closeSync();
  }
  for (final String file in files) {
    if (!File(p.join(destination.path, file)).existsSync()) {
      throw const SttModelException('The model archive is incomplete.');
    }
  }
}

/// Downloads, verifies and unpacks offline models (SPEC 5.10).
///
/// Only one download runs at a time. Archives are downloaded to
/// `<support>/stt/<engine>.tar.bz2`, verified against the manifest SHA-256,
/// unpacked to `<support>/stt/<engine>.tmp`, then renamed into place.
class SttModelManager {
  SttModelManager({
    required this.supportDirectory,
    SttFileDownloader? downloader,
    SttArchiveExtractor? extractor,
    List<SttModel> models = sttModels,
  }) : _downloader = downloader ?? DioFileDownloader(),
       _extractor = extractor ?? ArchiveModelExtractor(),
       _models = <SttEngineKind, SttModel>{
         for (final SttModel model in models) model.engine: model,
       } {
    _statuses = <SttEngineKind, SttModelStatus>{
      for (final SttEngineKind engine in _models.keys)
        engine: const SttModelStatus(),
    };
  }

  final Future<Directory> Function() supportDirectory;
  final SttFileDownloader _downloader;
  final SttArchiveExtractor _extractor;
  final Map<SttEngineKind, SttModel> _models;
  final StreamController<Map<SttEngineKind, SttModelStatus>> _states =
      StreamController<Map<SttEngineKind, SttModelStatus>>.broadcast();

  late Map<SttEngineKind, SttModelStatus> _statuses;
  SttEngineKind? _active;
  bool _canceled = false;
  bool _disposed = false;

  Stream<Map<SttEngineKind, SttModelStatus>> get states => _states.stream;

  Map<SttEngineKind, SttModelStatus> get snapshot =>
      Map<SttEngineKind, SttModelStatus>.unmodifiable(_statuses);

  SttModel? modelFor(SttEngineKind engine) => _models[engine];

  SttModelStatus statusOf(SttEngineKind engine) =>
      _statuses[engine] ?? const SttModelStatus();

  /// Checks the disk instead of the cached status.
  Future<bool> isReady(SttEngineKind engine) async {
    return await readyDirectory(engine) != null;
  }

  /// Directory with all required model files, or null when not installed.
  Future<Directory?> readyDirectory(SttEngineKind engine) async {
    final SttModel? model = _models[engine];
    if (model == null) {
      return null;
    }
    try {
      final Directory support = await supportDirectory();
      if (!_isReady(support, model)) {
        return null;
      }
      return Directory(p.join(support.path, 'stt', model.engine.id));
    } catch (_) {
      return null;
    }
  }

  /// True while any model is downloading, verifying or unpacking.
  bool get isBusy => _active != null;

  /// Re-reads the disk and marks models whose files are present as ready.
  Future<void> refresh() async {
    try {
      final Directory support = await supportDirectory();
      for (final SttModel model in _models.values) {
        if (_statuses[model.engine]?.isBusy ?? false) {
          continue;
        }
        _setStatus(
          model.engine,
          _isReady(support, model)
              ? const SttModelStatus(phase: SttModelPhase.ready, progress: 1)
              : const SttModelStatus(),
        );
      }
    } catch (_) {
      // The platform directory is unavailable (for example in widget tests).
    }
  }

  /// Downloads [engine]'s model unless it is already present.
  ///
  /// Returns true when the model is ready, false when the user canceled.
  Future<bool> download(SttEngineKind engine) async {
    final SttModel? model = _models[engine];
    if (model == null) {
      return false;
    }
    if (_statuses[engine]?.isReady ?? false) {
      return true;
    }
    if (_active != null) {
      throw const SttModelException('Another model is downloading.');
    }
    _active = engine;
    _canceled = false;
    _setStatus(engine, const SttModelStatus(phase: SttModelPhase.downloading));
    File? archive;
    Directory? temporary;
    try {
      final Directory support = await supportDirectory();
      final Directory root = Directory(p.join(support.path, 'stt'));
      await root.create(recursive: true);
      archive = File(p.join(root.path, '${engine.id}.tar.bz2'));
      temporary = Directory(p.join(root.path, '${engine.id}.tmp'));
      final Directory finalDirectory = Directory(p.join(root.path, engine.id));
      await _deleteFile(archive);
      await _deleteDirectory(temporary);
      await _downloader.download(
        model.url,
        archive,
        onProgress: (int received, int total) {
          if (_active != engine || _canceled) {
            return;
          }
          final int expected = total > 0 ? total : model.downloadBytes;
          final double progress = expected <= 0
              ? 0
              : (received / expected).clamp(0.0, 0.98).toDouble();
          _setStatus(
            engine,
            SttModelStatus(
              phase: SttModelPhase.downloading,
              progress: progress,
            ),
          );
        },
      );
      if (_canceled) {
        throw const SttModelCanceledException();
      }
      _setStatus(engine, const SttModelStatus(phase: SttModelPhase.verifying));
      final int size = await archive.length();
      if (size != model.downloadBytes) {
        throw const SttModelException(
          'The model download is incomplete. Try again.',
        );
      }
      final String digest = (await sha256.bind(archive.openRead()).first)
          .toString();
      if (digest.toLowerCase() != model.sha256.toLowerCase()) {
        throw const SttModelException(
          'The model download is corrupted. Try again.',
        );
      }
      if (_canceled) {
        throw const SttModelCanceledException();
      }
      _setStatus(engine, const SttModelStatus(phase: SttModelPhase.extracting));
      await temporary.create(recursive: true);
      await _extractor.extract(model, archive, temporary);
      if (_canceled) {
        throw const SttModelCanceledException();
      }
      for (final String file in model.files) {
        if (!File(p.join(temporary.path, file)).existsSync()) {
          throw const SttModelException('The model archive is incomplete.');
        }
      }
      if (await finalDirectory.exists()) {
        await finalDirectory.delete(recursive: true);
      }
      await temporary.rename(finalDirectory.path);
      await _deleteFile(archive);
      _setStatus(
        engine,
        const SttModelStatus(phase: SttModelPhase.ready, progress: 1),
      );
      return true;
    } on SttModelCanceledException {
      await _cleanup(archive, temporary);
      _setStatus(engine, const SttModelStatus());
      return false;
    } on SttModelException catch (error) {
      await _cleanup(archive, temporary);
      _setStatus(
        engine,
        SttModelStatus(phase: SttModelPhase.failed, error: error.userMessage),
      );
      rethrow;
    } catch (_) {
      await _cleanup(archive, temporary);
      const SttModelException failure = SttModelException(
        'Could not download the model. Check the connection and try again.',
      );
      _setStatus(
        engine,
        SttModelStatus(phase: SttModelPhase.failed, error: failure.userMessage),
      );
      throw failure;
    } finally {
      _active = null;
      _canceled = false;
    }
  }

  /// Cancels the active download, if any.
  Future<void> cancel() async {
    if (_active == null) {
      return;
    }
    _canceled = true;
    await _downloader.cancel();
  }

  /// Removes a downloaded model and its temporary files.
  Future<void> delete(SttEngineKind engine) async {
    if (_active == engine) {
      await cancel();
    }
    try {
      final Directory support = await supportDirectory();
      final Directory root = Directory(p.join(support.path, 'stt'));
      await _deleteDirectory(Directory(p.join(root.path, engine.id)));
      await _deleteFile(File(p.join(root.path, '${engine.id}.tar.bz2')));
      await _deleteDirectory(Directory(p.join(root.path, '${engine.id}.tmp')));
    } catch (_) {
      // A missing platform directory means there is nothing to delete.
    }
    _setStatus(engine, const SttModelStatus());
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await cancel();
    await _states.close();
  }

  bool _isReady(Directory support, SttModel model) {
    final Directory directory = Directory(
      p.join(support.path, 'stt', model.engine.id),
    );
    for (final String file in model.files) {
      if (!File(p.join(directory.path, file)).existsSync()) {
        return false;
      }
    }
    return true;
  }

  void _setStatus(SttEngineKind engine, SttModelStatus status) {
    if (_disposed || _statuses[engine] == status) {
      return;
    }
    _statuses = Map<SttEngineKind, SttModelStatus>.of(_statuses)
      ..[engine] = status;
    _states.add(snapshot);
  }

  Future<void> _cleanup(File? archive, Directory? temporary) async {
    await _deleteFile(archive);
    await _deleteDirectory(temporary);
  }

  Future<void> _deleteFile(File? file) async {
    if (file != null && await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  Future<void> _deleteDirectory(Directory? directory) async {
    if (directory != null && await directory.exists()) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }
}
