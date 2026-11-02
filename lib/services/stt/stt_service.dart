import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Language used for voice input, matching TTS (SPEC 5.8).
const String sttLanguage = 'en-US';

/// Locale id expected by the Android speech recognizer.
const String sttLocaleId = 'en_US';

/// Maximum length of one dictation session.
const Duration sttListenFor = Duration(minutes: 2);

/// Silence that ends the current phrase.
const Duration sttPauseFor = Duration(seconds: 3);

/// Events emitted by an [SttService].
sealed class SttEvent {
  const SttEvent();
}

/// Recognition started and the microphone is live.
final class SttStarted extends SttEvent {
  const SttStarted();
}

/// Partial text, updated while the user speaks.
final class SttPartial extends SttEvent {
  const SttPartial(this.text);

  final String text;
}

/// Normalized microphone level (0..1) for the listening meter.
final class SttLevel extends SttEvent {
  const SttLevel(this.level);

  final double level;
}

/// Coarse frequency bands (0..1) for the live spectrum.
final class SttAudioSpectrum extends SttEvent {
  const SttAudioSpectrum(this.bands);

  final List<double> bands;
}

/// Final text for the current phrase.
final class SttFinalResult extends SttEvent {
  const SttFinalResult(this.text);

  final String text;
}

/// The recognizer stopped (final result already delivered, if any).
final class SttStopped extends SttEvent {
  const SttStopped();
}

/// Recognition failed; the message is user-visible.
final class SttFailed extends SttEvent {
  const SttFailed(this.failure);

  final SttFailure failure;
}

/// A voiced failure with a user-visible message.
sealed class SttFailure implements Exception {
  const SttFailure();

  /// Exact English text shown to the user.
  String get userMessage;
}

/// The microphone permission was denied.
final class SttPermissionFailure extends SttFailure {
  const SttPermissionFailure();

  @override
  String get userMessage =>
      'Microphone permission is required for voice input.';
}

/// No system recognizer is installed or it cannot start.
final class SttUnavailableFailure extends SttFailure {
  const SttUnavailableFailure();

  @override
  String get userMessage =>
      'Speech recognition isn\'t available. Check the microphone permission.';
}

/// Nothing was recognized.
final class SttNoSpeechFailure extends SttFailure {
  const SttNoSpeechFailure();

  @override
  String get userMessage => 'No speech detected. Try again.';
}

/// The recognizer needs a connection for this language.
final class SttNetworkFailure extends SttFailure {
  const SttNetworkFailure();

  @override
  String get userMessage =>
      'Speech recognition needs a connection for this language.';
}

/// Another app is using the recognizer.
final class SttBusyFailure extends SttFailure {
  const SttBusyFailure();

  @override
  String get userMessage => 'Speech recognition is busy. Try again.';
}

/// The selected offline model has not been downloaded yet.
final class SttModelMissingFailure extends SttFailure {
  const SttModelMissingFailure(this.modelName);

  final String modelName;

  @override
  String get userMessage =>
      'Download the $modelName model in Settings > Voice.';
}

/// The selected offline model could not be loaded.
final class SttModelLoadFailure extends SttFailure {
  const SttModelLoadFailure(this.modelName);

  final String modelName;

  @override
  String get userMessage =>
      'Could not load the $modelName model. Download it again in Settings.';
}

/// Any other recognizer failure.
final class SttUnknownFailure extends SttFailure {
  const SttUnknownFailure();

  @override
  String get userMessage => 'Voice input failed. Try again.';
}

/// Maps a platform error code to a typed failure.
SttFailure mapSttError(String code) {
  return switch (code) {
    'error_permission' => const SttPermissionFailure(),
    'error_no_match' || 'error_speech_timeout' => const SttNoSpeechFailure(),
    'error_network' ||
    'error_network_timeout' ||
    'error_server' ||
    'error_server_disconnected' ||
    'error_too_many_requests' => const SttNetworkFailure(),
    'error_busy' => const SttBusyFailure(),
    'error_language_not_supported' ||
    'error_language_unavailable' => const SttUnavailableFailure(),
    _ => const SttUnknownFailure(),
  };
}

/// Maps Android's RMS dB value to a 0..1 meter level.
double normalizeDbLevel(double db) {
  return ((db + 60) / 60).clamp(0.0, 1.0).toDouble();
}

/// Approximate spectrum for the system recognizer, which only reports level.
List<double> levelSpectrum(double level) {
  final double safe = level.clamp(0.0, 1.0).toDouble();
  const int bands = 32;
  return <double>[
    for (int i = 0; i < bands; i++)
      (safe *
              (0.2 +
                  0.8 *
                      (1 -
                          (i - bands / 2) *
                              (i - bands / 2) /
                              (bands * bands) *
                              3)))
          .clamp(0.0, 1.0)
          .toDouble(),
  ];
}

/// True when the error means the on-device recognizer is not usable.
bool isOnDeviceUnavailable(String code) {
  return code == 'error_language_unavailable' ||
      code == 'error_language_not_supported' ||
      code == 'error_server_disconnected' ||
      code == 'error_network';
}

/// Voice-input service (SPEC 5.8).
abstract class SttService {
  /// Prepares the recognizer. Safe to call more than once.
  Future<bool> initialize();

  /// Starts dictating. [preferOnDevice] asks for local recognition first.
  Future<void> start({bool preferOnDevice = true});

  /// Stops listening; the final result is still delivered as an event.
  Future<void> stop();

  /// Stops listening without returning a final result.
  Future<void> cancel();

  /// Recognition events.
  Stream<SttEvent> get events;

  Future<void> dispose();
}

/// Minimal recognizer surface used by [SystemSttService].
///
/// Exists so unit tests can drive the service without the platform plugin.
abstract class SttEngine {
  bool get isListening;

  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String code) onError,
  });

  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required bool onDevice,
    void Function(double level)? onLevel,
  });

  Future<void> stop();

  Future<void> cancel();
}

/// [SttEngine] backed by `speech_to_text`.
class SpeechToTextEngine implements SttEngine {
  SpeechToTextEngine([SpeechToText? speech]) : _speech = speech;

  SpeechToText? _speech;

  SpeechToText get _instance => _speech ??= SpeechToText();

  @override
  bool get isListening => _instance.isListening;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String code) onError,
  }) {
    return _instance.initialize(
      onStatus: onStatus,
      onError: (SpeechRecognitionError error) => onError(error.errorMsg),
      options: <SpeechConfigOption>[SpeechToText.androidNoBluetooth],
    );
  }

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required bool onDevice,
    void Function(double level)? onLevel,
  }) {
    return _instance.listen(
      onResult: (SpeechRecognitionResult result) =>
          onResult(result.recognizedWords, result.finalResult),
      onSoundLevelChange: onLevel,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        onDevice: onDevice,
        listenMode: ListenMode.dictation,
        cancelOnError: true,
        listenFor: sttListenFor,
        pauseFor: sttPauseFor,
        localeId: sttLocaleId,
      ),
    );
  }

  @override
  Future<void> stop() => _instance.stop();

  @override
  Future<void> cancel() => _instance.cancel();
}

/// [SttService] backed by the Android system recognizer (SPEC 5.8).
///
/// Uses `en-US`. A start first asks for on-device recognition when
/// [preferOnDevice] is set; if the device or language pack cannot do that,
/// the service retries once with the device default (which may be online).
class SystemSttService implements SttService {
  SystemSttService({SttEngine? engine})
    : _engine = engine ?? SpeechToTextEngine();

  final SttEngine _engine;
  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();

  bool _initialized = false;
  bool _available = false;
  bool _preferOnDevice = true;
  bool _onDeviceFailed = false;
  String _lastFinal = '';

  @override
  Stream<SttEvent> get events => _events.stream;

  @override
  Future<bool> initialize() async {
    if (_initialized) {
      return _available;
    }
    _available = await _engine.initialize(
      onStatus: _onStatus,
      onError: _onError,
    );
    _initialized = _available;
    return _available;
  }

  @override
  Future<void> start({bool preferOnDevice = true}) async {
    _preferOnDevice = preferOnDevice;
    _onDeviceFailed = false;
    _lastFinal = '';
    if (!await initialize()) {
      _emit(const SttFailed(SttUnavailableFailure()));
      return;
    }
    try {
      await _engine.listen(
        onResult: _onResult,
        onDevice: preferOnDevice,
        onLevel: _onLevel,
      );
    } catch (_) {
      if (preferOnDevice) {
        _onDeviceFailed = true;
        try {
          await _engine.listen(
            onResult: _onResult,
            onDevice: false,
            onLevel: _onLevel,
          );
          return;
        } catch (_) {
          // Fall through to the typed failure below.
        }
      }
      _emit(const SttFailed(SttUnavailableFailure()));
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _engine.stop();
    } catch (_) {
      _emit(const SttFailed(SttUnknownFailure()));
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _engine.cancel();
    } catch (_) {
      // Cancelling is best-effort.
    }
  }

  void _onStatus(String status) {
    if (status == 'listening') {
      _emit(const SttStarted());
    } else if (status == 'done' || status == 'notListening') {
      _emit(const SttStopped());
    }
  }

  void _onError(String code) {
    if (_preferOnDevice && !_onDeviceFailed && isOnDeviceUnavailable(code)) {
      _onDeviceFailed = true;
      unawaited(_retryWithoutOnDevice());
      return;
    }
    _emit(SttFailed(mapSttError(code)));
  }

  Future<void> _retryWithoutOnDevice() async {
    try {
      await _engine.listen(
        onResult: _onResult,
        onDevice: false,
        onLevel: _onLevel,
      );
    } catch (_) {
      _emit(const SttFailed(SttUnavailableFailure()));
    }
  }

  void _onLevel(double db) {
    final double level = normalizeDbLevel(db);
    _emit(SttLevel(level));
    _emit(SttAudioSpectrum(levelSpectrum(level)));
  }

  void _onResult(String text, bool isFinal) {
    if (text.trim().isEmpty) {
      return;
    }
    if (!isFinal) {
      _emit(SttPartial(text));
      return;
    }
    if (text == _lastFinal) {
      return;
    }
    _lastFinal = text;
    _emit(SttFinalResult(text));
  }

  void _emit(SttEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _events.close();
  }
}
