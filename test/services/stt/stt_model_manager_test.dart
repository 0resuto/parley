import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model.dart';
import 'package:parley/services/stt/stt_model_manager.dart';
import 'package:path/path.dart' as p;

class FakeDownloader implements SttFileDownloader {
  FakeDownloader(this.bytes, {this.gate, this.started});

  final List<int> bytes;
  final Completer<void>? gate;
  final Completer<void>? started;
  int calls = 0;
  bool canceled = false;

  @override
  Future<void> download(
    String url,
    File destination, {
    required void Function(int received, int total) onProgress,
  }) async {
    calls++;
    await destination.parent.create(recursive: true);
    onProgress(0, bytes.length);
    started?.complete();
    final Completer<void>? blocker = gate;
    if (blocker != null) {
      await blocker.future;
    }
    if (canceled) {
      throw const SttModelCanceledException();
    }
    await destination.writeAsBytes(bytes);
    onProgress(bytes.length, bytes.length);
  }

  @override
  Future<void> cancel() async {
    canceled = true;
    if (gate != null && !gate!.isCompleted) {
      gate!.complete();
    }
  }
}

class FakeExtractor implements SttArchiveExtractor {
  bool fail = false;
  int calls = 0;

  @override
  Future<void> extract(
    SttModel model,
    File archive,
    Directory destination,
  ) async {
    calls++;
    if (fail) {
      throw const SttModelException('Unpack failed.');
    }
    for (final String file in model.files) {
      final File output = File(p.join(destination.path, file));
      await output.parent.create(recursive: true);
      await output.writeAsString('model data');
    }
  }
}

void main() {
  late Directory temp;
  late List<int> bytes;
  late SttModel model;
  late SttModel second;
  late FakeDownloader downloader;
  late FakeExtractor extractor;
  late SttModelManager manager;

  Future<Directory> support() async => temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('parley_stt_model_');
    bytes = utf8.encode('model archive bytes');
    model = SttModel(
      engine: SttEngineKind.moonshine,
      name: 'Test model',
      description: 'Test',
      url: 'https://example.com/model.tar.bz2',
      downloadBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      archiveRoot: 'root',
      files: const ['model.onnx', 'tokens.txt'],
      license: 'MIT',
    );
    second = SttModel(
      engine: SttEngineKind.whisper,
      name: 'Second model',
      description: 'Test',
      url: 'https://example.com/second.tar.bz2',
      downloadBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      archiveRoot: 'second',
      files: const ['model.onnx'],
      license: 'MIT',
    );
    downloader = FakeDownloader(bytes);
    extractor = FakeExtractor();
    manager = SttModelManager(
      supportDirectory: support,
      downloader: downloader,
      extractor: extractor,
      models: [model, second],
    );
  });

  tearDown(() async {
    await manager.dispose();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('download verifies, extracts and disposes of the archive', () async {
    await manager.refresh();
    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.notDownloaded,
    );

    expect(await manager.download(SttEngineKind.moonshine), isTrue);

    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.ready,
    );
    for (final String file in model.files) {
      expect(
        File(p.join(temp.path, 'stt', 'moonshine', file)).existsSync(),
        isTrue,
      );
    }
    expect(
      File(p.join(temp.path, 'stt', 'moonshine.tar.bz2')).existsSync(),
      isFalse,
    );
    expect(extractor.calls, 1);

    // A second download is a no-op.
    expect(await manager.download(SttEngineKind.moonshine), isTrue);
    expect(downloader.calls, 1);
  });

  test('refresh finds a previously downloaded model', () async {
    await manager.download(SttEngineKind.moonshine);
    final SttModelManager reopened = SttModelManager(
      supportDirectory: support,
      downloader: FakeDownloader(bytes),
      extractor: FakeExtractor(),
      models: [model, second],
    );
    addTearDown(reopened.dispose);

    await reopened.refresh();

    expect(
      reopened.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.ready,
    );
  });

  test('a corrupt download fails and leaves no model directory', () async {
    final List<int> corrupt = List<int>.filled(bytes.length, 0);
    final FakeDownloader bad = FakeDownloader(corrupt);
    manager = SttModelManager(
      supportDirectory: support,
      downloader: bad,
      extractor: extractor,
      models: [model, second],
    );

    await expectLater(
      manager.download(SttEngineKind.moonshine),
      throwsA(
        isA<SttModelException>().having(
          (SttModelException value) => value.userMessage,
          'message',
          contains('corrupted'),
        ),
      ),
    );

    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.failed,
    );
    expect(
      Directory(p.join(temp.path, 'stt', 'moonshine')).existsSync(),
      isFalse,
    );
  });

  test('an incomplete download fails cleanly', () async {
    final FakeDownloader short = FakeDownloader(bytes.sublist(0, 3));
    manager = SttModelManager(
      supportDirectory: support,
      downloader: short,
      extractor: extractor,
      models: [model, second],
    );

    await expectLater(
      manager.download(SttEngineKind.moonshine),
      throwsA(isA<SttModelException>()),
    );
    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.failed,
    );
  });

  test('cancel stops the download and returns to not downloaded', () async {
    final Completer<void> gate = Completer<void>();
    final Completer<void> started = Completer<void>();
    final FakeDownloader gated = FakeDownloader(
      bytes,
      gate: gate,
      started: started,
    );
    manager = SttModelManager(
      supportDirectory: support,
      downloader: gated,
      extractor: extractor,
      models: [model, second],
    );

    final Future<bool> pending = manager.download(SttEngineKind.moonshine);
    await started.future;
    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.downloading,
    );

    await manager.cancel();

    expect(await pending, isFalse);
    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.notDownloaded,
    );
    expect(
      File(p.join(temp.path, 'stt', 'moonshine.tar.bz2')).existsSync(),
      isFalse,
    );
  });

  test('a second download while busy is rejected', () async {
    final Completer<void> gate = Completer<void>();
    final Completer<void> started = Completer<void>();
    final FakeDownloader gated = FakeDownloader(
      bytes,
      gate: gate,
      started: started,
    );
    manager = SttModelManager(
      supportDirectory: support,
      downloader: gated,
      extractor: extractor,
      models: [model, second],
    );

    final Future<bool> pending = manager.download(SttEngineKind.moonshine);
    await started.future;

    await expectLater(
      manager.download(SttEngineKind.whisper),
      throwsA(isA<SttModelException>()),
    );

    await manager.cancel();
    await pending;
  });

  test('delete removes the model and its files', () async {
    await manager.download(SttEngineKind.moonshine);

    await manager.delete(SttEngineKind.moonshine);

    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.notDownloaded,
    );
    expect(
      Directory(p.join(temp.path, 'stt', 'moonshine')).existsSync(),
      isFalse,
    );
  });

  test('an extraction failure is reported as a model failure', () async {
    extractor.fail = true;

    await expectLater(
      manager.download(SttEngineKind.moonshine),
      throwsA(isA<SttModelException>()),
    );

    expect(
      manager.statusOf(SttEngineKind.moonshine).phase,
      SttModelPhase.failed,
    );
    expect(
      manager.statusOf(SttEngineKind.moonshine).error,
      contains('Unpack failed'),
    );
  });

  group('ArchiveModelExtractor', () {
    test('keeps only required files and refuses traversal', () async {
      final Directory destination = await Directory.systemTemp.createTemp(
        'parley_stt_extract_',
      );
      addTearDown(() async {
        if (await destination.exists()) {
          await destination.delete(recursive: true);
        }
      });

      final Archive archive = Archive();
      void add(String name, String content) {
        final List<int> contentBytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, contentBytes.length, contentBytes));
      }

      add('root/model.onnx', 'model');
      add('root/tokens.txt', 'tokens');
      add('root/extra.onnx', 'skip');
      add('root/../evil.txt', 'evil');

      final List<int> tar = TarEncoder().encode(archive);
      final File file = File(p.join(temp.path, 'model.tar.bz2'));
      await file.writeAsBytes(BZip2Encoder().encode(tar));

      final SttModel archiveModel = SttModel(
        engine: SttEngineKind.moonshine,
        name: 'Archive model',
        description: 'Test',
        url: 'https://example.com/model.tar.bz2',
        downloadBytes: 0,
        sha256: '',
        archiveRoot: 'root',
        files: const ['model.onnx', 'tokens.txt'],
        license: 'MIT',
      );

      await ArchiveModelExtractor().extract(archiveModel, file, destination);

      expect(
        File(p.join(destination.path, 'model.onnx')).readAsStringSync(),
        'model',
      );
      expect(
        File(p.join(destination.path, 'tokens.txt')).readAsStringSync(),
        'tokens',
      );
      expect(
        File(p.join(destination.path, 'extra.onnx')).existsSync(),
        isFalse,
      );
      expect(File(p.join(destination.path, 'evil.txt')).existsSync(), isFalse);
    });
  });
}
