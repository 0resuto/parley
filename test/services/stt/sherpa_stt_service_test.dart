import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/stt/sherpa_stt_service.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_recognizer.dart';
import 'package:parley/services/stt/stt_recorder.dart';
import 'package:parley/services/stt/stt_service.dart';

class FakeRecorder implements SttRecorder {
  FakeRecorder({this.permission = true});

  bool permission;
  bool started = false;
  bool stopped = false;
  bool canceled = false;
  bool disposed = false;
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast();

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Stream<Uint8List> get chunks => _chunks.stream;

  void emit(List<int> bytes) => _chunks.add(Uint8List.fromList(bytes));

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> cancel() async {
    canceled = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _chunks.close();
  }
}

class FakeRecognizer implements SttRecognizer {
  FakeRecognizer({this.text = 'hello world', this.fail = false});

  String text;
  bool fail;
  bool initialized = false;
  bool disposed = false;
  final List<Float32List> calls = [];

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<String> transcribe(Float32List samples) async {
    calls.add(samples);
    if (fail) {
      throw StateError('decode failed');
    }
    return text;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class FakeRecognizerFactory implements SttRecognizerFactory {
  FakeRecognizerFactory(this.recognizer);

  final SttRecognizer recognizer;
  bool fail = false;

  @override
  Future<SttRecognizer> create(
    SttEngineKind engine,
    Directory modelDirectory,
  ) async {
    if (fail) {
      throw StateError('model missing');
    }
    return recognizer;
  }
}

void main() {
  late Directory directory;
  late FakeRecorder recorder;
  late FakeRecognizer recognizer;
  late FakeRecognizerFactory factory;
  late SherpaSttService service;
  late List<SttEvent> events;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('parley_sherpa_');
    recorder = FakeRecorder();
    recognizer = FakeRecognizer();
    factory = FakeRecognizerFactory(recognizer);
    service = SherpaSttService(
      engine: SttEngineKind.moonshine,
      modelDirectory: directory,
      recorderFactory: () => recorder,
      recognizerFactory: factory,
    );
    events = [];
    service.events.listen(events.add);
  });

  tearDown(() async {
    await service.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('converts PCM16 little-endian to float samples', () {
    final Float32List samples = pcm16ToFloat32(
      Uint8List.fromList(<int>[0, 0, 0, 64, 0, 128]),
    );

    expect(samples, hasLength(3));
    expect(samples[0], 0);
    expect(samples[1], closeTo(0.5, 0.0001));
    expect(samples[2], -1);
  });

  test('filters Whisper non-speech tags', () {
    expect(cleanOfflineTranscript('[SOUND] [SOUND] [BLANK_AUDIO]'), isEmpty);
    expect(cleanOfflineTranscript('[SOUND] Hello world'), 'Hello world');
    expect(cleanOfflineTranscript('  [MUSIC]  '), isEmpty);
    expect(cleanOfflineTranscript('[ Silence ]'), isEmpty);
    expect(cleanOfflineTranscript('[ Blank Audio ]'), isEmpty);
  });

  test('computes a dB-scaled level from PCM16', () {
    expect(pcm16Level(Uint8List.fromList(<int>[0, 0, 0, 0])), 0);
    expect(
      pcm16Level(Uint8List.fromList(<int>[0xFF, 0x7F])),
      closeTo(1, 0.001),
    );
    expect(
      pcm16Level(Uint8List.fromList(<int>[0xCD, 0x0C])),
      closeTo(0.6, 0.01),
    );
    expect(pcm16Level(Uint8List.fromList(<int>[0, 0, 0, 16])), greaterThan(0));
  });

  test('finds a tone near 600 Hz in the expected band', () {
    int closest = 0;
    double distance = double.infinity;
    for (int i = 0; i < sttSpectrumFrequencies.length; i++) {
      final double next = (sttSpectrumFrequencies[i] - 600).abs();
      if (next < distance) {
        distance = next;
        closest = i;
      }
    }
    final double tone = sttSpectrumFrequencies[closest];
    final Uint8List bytes = Uint8List(1024);
    final ByteData data = ByteData.sublistView(bytes);
    for (int i = 0; i < 512; i++) {
      final double value = math.sin(2 * math.pi * tone * i / 16000) * 0.5;
      data.setInt16(i * 2, (value * 32767).round(), Endian.little);
    }

    final List<double> bands = pcm16Spectrum(bytes);

    expect(bands, hasLength(sttSpectrumFrequencies.length));
    expect(bands[closest], greaterThan(0.5));
    expect(bands[closest], greaterThan(bands.first));
    expect(bands[closest], greaterThan(bands.last));
  });

  test('permission denial produces a permission failure', () async {
    recorder.permission = false;

    await service.start();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttPermissionFailure>(),
    );
    expect(recorder.started, isFalse);
  });

  test('initialize loads the model without opening the microphone', () async {
    expect(await service.initialize(), isTrue);
    await flush();

    expect(recognizer.initialized, isTrue);
    expect(recorder.started, isFalse);

    await service.start();
    await flush();
    expect(events.whereType<SttStarted>(), hasLength(1));
    expect(recognizer.initialized, isTrue);
  });

  test('initialize reports a model load failure', () async {
    factory.fail = true;

    expect(await service.initialize(), isFalse);
    expect(recorder.started, isFalse);
  });

  test('records PCM and transcribes on stop', () async {
    await service.start();
    await flush();
    expect(events.whereType<SttStarted>(), hasLength(1));
    expect(recorder.started, isTrue);

    recorder.emit(<int>[0, 0, 0, 64]);
    await flush();
    await service.stop();
    await flush();

    expect(recognizer.initialized, isTrue);
    expect(recognizer.calls.single, hasLength(2));
    expect(events.whereType<SttLevel>(), isNotEmpty);
    expect(events.whereType<SttAudioSpectrum>(), isNotEmpty);
    expect(events.whereType<SttFinalResult>().single.text, 'hello world');
    expect(events.whereType<SttStopped>(), hasLength(1));
  });

  test('empty audio reports no speech', () async {
    await service.start();
    await service.stop();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttNoSpeechFailure>(),
    );
    expect(recognizer.calls, isEmpty);
  });

  test('an empty transcription reports no speech', () async {
    recognizer.text = '   ';
    await service.start();
    recorder.emit(<int>[0, 0]);
    await flush();
    await service.stop();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttNoSpeechFailure>(),
    );
  });

  test('Whisper noise tags are ignored', () async {
    recognizer.text = '[SOUND] [BLANK_AUDIO] [MUSIC]';
    await service.start();
    recorder.emit(<int>[0, 0]);
    await flush();
    await service.stop();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttNoSpeechFailure>(),
    );
    expect(events.whereType<SttFinalResult>(), isEmpty);
  });

  test('a recognizer failure reports a generic failure', () async {
    recognizer.fail = true;
    await service.start();
    recorder.emit(<int>[0, 0]);
    await flush();
    await service.stop();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttUnknownFailure>(),
    );
  });

  test('a model load failure is reported', () async {
    factory.fail = true;

    await service.start();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttModelLoadFailure>(),
    );
    expect(recorder.started, isFalse);
  });

  test('cancel discards the buffer', () async {
    await service.start();
    recorder.emit(<int>[0, 0]);
    await flush();

    await service.cancel();
    await flush();

    expect(events.whereType<SttFinalResult>(), isEmpty);
    expect(recorder.canceled, isTrue);
  });
}
