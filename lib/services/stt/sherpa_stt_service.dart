import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'stt_engine.dart';
import 'stt_model.dart';
import 'stt_recognizer.dart';
import 'stt_recorder.dart';
import 'stt_service.dart';

/// Sample rate expected by the bundled sherpa-onnx models.
const int sttSampleRate = 16000;

final RegExp _nonSpeechTag = RegExp(
  r'\[(?:sound|blank_audio|music|noise|silence|inaudible|laughter|applause)\]',
  caseSensitive: false,
);

/// Removes Whisper's non-speech tags such as `[SOUND]` and `[BLANK_AUDIO]`.
///
/// Returns an empty string when nothing but tags/punctuation remains, so the
/// service can report "no speech" instead of inserting noise tokens.
String cleanOfflineTranscript(String text) {
  final String cleaned = text
      .replaceAll(_nonSpeechTag, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty || !cleaned.contains(RegExp(r'[A-Za-z0-9]'))) {
    return '';
  }
  return cleaned;
}

/// Normalized RMS level of a PCM16 chunk, for the listening waveform.
double pcm16Level(Uint8List bytes) {
  if (bytes.length < 2) {
    return 0;
  }
  final ByteData data = ByteData.sublistView(bytes);
  double sum = 0;
  int count = 0;
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    final double sample = data.getInt16(i, Endian.little) / 32768.0;
    sum += sample * sample;
    count++;
  }
  if (count == 0) {
    return 0;
  }
  final double rms = math.sqrt(sum / count);
  return (rms / 0.2).clamp(0.0, 1.0).toDouble();
}

/// Log-spaced frequencies for the live spectrum, limited to the speech range.
final List<double> sttSpectrumFrequencies = List<double>.unmodifiable(<double>[
  for (int i = 0; i < 32; i++) 80 * math.pow(4500 / 80, i / 31).toDouble(),
]);

/// Coarse real-time spectrum of a PCM16 chunk using Goertzel filters.
List<double> pcm16Spectrum(Uint8List bytes) {
  final Float32List samples = pcm16ToFloat32(bytes);
  if (samples.isEmpty) {
    return List<double>.filled(sttSpectrumFrequencies.length, 0);
  }
  // Pre-emphasis lifts consonants and high vowels; without it most of the
  // visual energy sits in the left half of the spectrum.
  final Float32List emphasized = Float32List(samples.length);
  double previous = 0;
  double energy = 0;
  for (int i = 0; i < samples.length; i++) {
    emphasized[i] = samples[i] - 0.95 * previous;
    previous = samples[i];
    energy += samples[i] * samples[i];
  }
  final double level = (math.sqrt(energy / samples.length) / 0.2)
      .clamp(0.0, 1.0)
      .toDouble();
  return <double>[
    for (int i = 0; i < sttSpectrumFrequencies.length; i++)
      (math
                  .pow(
                    _goertzel(emphasized, sttSpectrumFrequencies[i]) *
                        90 *
                        (1 + 0.4 * i / (sttSpectrumFrequencies.length - 1)),
                    1.2,
                  )
                  .toDouble() +
              level * 0.2)
          .clamp(0.0, 4.0)
          .toDouble(),
  ];
}

double _goertzel(Float32List samples, double frequency) {
  final double omega = 2 * math.pi * frequency / sttSampleRate;
  final double coefficient = 2 * math.cos(omega);
  double s1 = 0;
  double s2 = 0;
  for (final double sample in samples) {
    final double s0 = sample + coefficient * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  final double power = s1 * s1 + s2 * s2 - coefficient * s1 * s2;
  return math.sqrt(power) / samples.length;
}

/// Converts 16-bit little-endian PCM bytes to float samples in -1..1.
Float32List pcm16ToFloat32(Uint8List bytes) {
  final int count = bytes.length ~/ 2;
  final Float32List samples = Float32List(count);
  final ByteData data = ByteData.sublistView(bytes);
  for (int i = 0; i < count; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

/// Offline recognition through sherpa-onnx (SPEC 5.8).
///
/// The model is loaded on the first start and kept in memory. Recording is
/// buffered in PCM16 and decoded once when the user stops, so the UI can show
/// a processing indicator instead of partial text.
class SherpaSttService implements SttService {
  SherpaSttService({
    required this.engine,
    required this.modelDirectory,
    SttRecorder Function()? recorderFactory,
    SttRecognizerFactory? recognizerFactory,
  }) : _recorderFactory = recorderFactory ?? (() => RecordSttRecorder()),
       _recognizerFactory = recognizerFactory ?? DefaultSttRecognizerFactory();

  final SttEngineKind engine;
  final Directory modelDirectory;
  final SttRecorder Function() _recorderFactory;
  final SttRecognizerFactory _recognizerFactory;
  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();
  final BytesBuilder _pcm = BytesBuilder(copy: false);

  SttRecorder? _recorder;
  SttRecognizer? _recognizer;
  StreamSubscription<Uint8List>? _chunks;
  bool _capturing = false;
  int _session = 0;
  bool _disposed = false;

  @override
  Stream<SttEvent> get events => _events.stream;

  @override
  Future<bool> initialize() async {
    // The model is loaded lazily on the first start; keep the controller
    // alive so it can show a model-loading failure instead of a generic one.
    return !_disposed;
  }

  @override
  Future<void> start({bool preferOnDevice = true}) async {
    if (_disposed) {
      return;
    }
    final int session = ++_session;
    _pcm.clear();
    try {
      final SttRecorder recorder = _recorder ??= _recorderFactory();
      if (!await recorder.hasPermission()) {
        _emit(const SttFailed(SttPermissionFailure()));
        return;
      }
      final bool ready = await _ensureRecognizer();
      if (session != _session) {
        _emit(const SttStopped());
        return;
      }
      if (!ready) {
        _emit(SttFailed(SttModelLoadFailure(_modelName)));
        return;
      }
      _chunks = recorder.chunks.listen(
        _onChunk,
        onError: (Object _) {
          _emit(const SttFailed(SttUnknownFailure()));
          unawaited(cancel());
        },
      );
      _capturing = true;
      await recorder.start();
      if (session != _session) {
        await _stopCapture();
        _emit(const SttStopped());
        return;
      }
      _emit(const SttStarted());
    } catch (_) {
      await _stopCapture();
      _emit(const SttFailed(SttUnknownFailure()));
    }
  }

  @override
  Future<void> stop() async {
    if (!_capturing) {
      _session++;
      _emit(const SttStopped());
      return;
    }
    final int session = ++_session;
    try {
      await _recorder?.stop();
    } catch (_) {
      // The buffer still holds whatever was captured.
    }
    _capturing = false;
    await _chunks?.cancel();
    _chunks = null;
    final Float32List samples = pcm16ToFloat32(_pcm.takeBytes());
    _pcm.clear();
    if (samples.isEmpty) {
      _emit(const SttFailed(SttNoSpeechFailure()));
      _emit(const SttStopped());
      return;
    }
    final SttRecognizer? recognizer = _recognizer;
    if (recognizer == null) {
      _emit(SttFailed(SttModelLoadFailure(_modelName)));
      _emit(const SttStopped());
      return;
    }
    try {
      final String text = cleanOfflineTranscript(
        await recognizer.transcribe(samples),
      );
      if (session != _session) {
        return;
      }
      if (text.isEmpty) {
        _emit(const SttFailed(SttNoSpeechFailure()));
      } else {
        _emit(SttFinalResult(text));
      }
    } catch (_) {
      if (session == _session) {
        _emit(const SttFailed(SttUnknownFailure()));
      }
    }
    if (session == _session) {
      _emit(const SttStopped());
    }
  }

  @override
  Future<void> cancel() async {
    _session++;
    await _stopCapture();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await cancel();
    await _recognizer?.dispose();
    _recognizer = null;
    await _recorder?.dispose();
    _recorder = null;
    await _events.close();
  }

  String get _modelName => sttModelFor(engine)?.name ?? 'offline';

  Future<bool> _ensureRecognizer() async {
    if (_recognizer != null) {
      return true;
    }
    try {
      final SttRecognizer recognizer = await _recognizerFactory.create(
        engine,
        modelDirectory,
      );
      await recognizer.initialize();
      _recognizer = recognizer;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onChunk(Uint8List chunk) {
    if (_capturing) {
      _pcm.add(chunk);
      _emit(SttLevel(pcm16Level(chunk)));
      _emit(SttAudioSpectrum(pcm16Spectrum(chunk)));
    }
  }

  Future<void> _stopCapture() async {
    _capturing = false;
    await _chunks?.cancel();
    _chunks = null;
    _pcm.clear();
    try {
      await _recorder?.cancel();
    } catch (_) {
      // The recorder may not be running.
    }
  }

  void _emit(SttEvent event) {
    if (!_disposed && !_events.isClosed) {
      _events.add(event);
    }
  }
}
