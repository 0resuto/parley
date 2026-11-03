import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'stt_engine.dart';

/// A loaded offline recognizer.
abstract class SttRecognizer {
  Future<void> initialize();

  /// Transcribes 16 kHz mono float samples in the range -1..1.
  Future<String> transcribe(Float32List samples);

  Future<void> dispose();
}

/// Creates the recognizer for a downloaded model.
abstract class SttRecognizerFactory {
  Future<SttRecognizer> create(SttEngineKind engine, Directory modelDirectory);
}

/// Factory backed by sherpa-onnx.
class DefaultSttRecognizerFactory implements SttRecognizerFactory {
  @override
  Future<SttRecognizer> create(
    SttEngineKind engine,
    Directory modelDirectory,
  ) async {
    return SherpaSttRecognizer(engine, modelDirectory);
  }
}

/// Builds the sherpa-onnx model configuration for a downloaded engine.
OfflineModelConfig buildOfflineModelConfig(
  SttEngineKind engine,
  Directory modelDirectory,
) {
  return switch (engine) {
    SttEngineKind.moonshine => OfflineModelConfig(
      moonshine: OfflineMoonshineModelConfig(
        encoder: p.join(modelDirectory.path, 'encoder_model.ort'),
        mergedDecoder: p.join(modelDirectory.path, 'decoder_model_merged.ort'),
      ),
      tokens: p.join(modelDirectory.path, 'tokens.txt'),
      numThreads: 2,
      debug: false,
    ),
    SttEngineKind.whisper => OfflineModelConfig(
      whisper: OfflineWhisperModelConfig(
        encoder: p.join(modelDirectory.path, 'tiny.en-encoder.int8.onnx'),
        decoder: p.join(modelDirectory.path, 'tiny.en-decoder.int8.onnx'),
        language: 'en',
        task: 'transcribe',
      ),
      tokens: p.join(modelDirectory.path, 'tiny.en-tokens.txt'),
      modelType: 'whisper',
      numThreads: 2,
      debug: false,
    ),
  };
}

/// sherpa-onnx offline recognizer for Moonshine and Whisper models.
class SherpaSttRecognizer implements SttRecognizer {
  SherpaSttRecognizer(this.engine, this.modelDirectory);

  final SttEngineKind engine;
  final Directory modelDirectory;

  OfflineRecognizer? _recognizer;

  @override
  Future<void> initialize() async {
    await _ensureBindings();
    _recognizer = await OfflineRecognizer.createAsync(
      OfflineRecognizerConfig(
        model: buildOfflineModelConfig(engine, modelDirectory),
      ),
    );
  }

  @override
  Future<String> transcribe(Float32List samples) async {
    final OfflineRecognizer? recognizer = _recognizer;
    if (recognizer == null) {
      throw StateError('The recognizer is not initialized.');
    }
    final OfflineStream stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  @override
  Future<void> dispose() async {
    _recognizer?.free();
    _recognizer = null;
  }
}

Future<void>? _bindings;

/// Loads the native sherpa-onnx bindings once per isolate.
Future<void> _ensureBindings() async {
  final Future<void>? existing = _bindings;
  if (existing != null) {
    return existing;
  }
  final Future<void> future = initBindingsAsync();
  _bindings = future;
  try {
    await future;
  } catch (_) {
    _bindings = null;
    rethrow;
  }
}
