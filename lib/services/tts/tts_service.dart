import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/settings/settings_repository.dart';

/// Language used for all speech (SPEC 5.8).
const String ttsLanguage = 'en-US';

/// Removes `[[` `]]` markers, keeping the inner word (SPEC 5.8).
///
/// `'Say [[heifer]] please'` becomes `'Say heifer please'`.
String cleanTtsText(String text) {
  return text.replaceAll('[[', '').replaceAll(']]', '');
}

/// Maps the app speech-speed setting (0.5-1.5) to the engine rate.
///
/// SPEC 5.8: engine rate = 0.5 x speed setting.
double ttsEngineRate(double speechSpeed) {
  final double speed = speechSpeed.isNaN
      ? SharedPreferencesSettingsRepository.defaultSpeechSpeed
      : speechSpeed.clamp(0.5, 1.5).toDouble();
  return speed * 0.5;
}

/// Text-to-speech (SPEC 5.8, PLAN 8.1).
abstract class TtsService {
  /// Speaks [text] aloud, stopping any current playback first.
  Future<void> speak(String text);

  /// Stops playback.
  Future<void> stop();

  /// True while speaking.
  Stream<bool> get isSpeaking;
}

/// No-op fake used in tests.
///
/// Records spoken texts so widget tests can verify Speak was wired.
class FakeTtsService implements TtsService {
  final List<String> spokenTexts = [];
  final StreamController<bool> _speaking = StreamController<bool>.broadcast();

  @override
  Future<void> speak(String text) async {
    spokenTexts.add(text);
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<bool> get isSpeaking => _speaking.stream;

  /// Emits a raw speaking-state event, as the engine handlers would.
  ///
  /// Tests use this to simulate playback finishing on its own.
  void emitSpeaking(bool speaking) {
    _speaking.add(speaking);
  }

  /// Closes the underlying stream controller.
  Future<void> dispose() => _speaking.close();
}

/// Minimal engine surface used by [FlutterTtsService].
///
/// Exists so unit tests can use a fake without touching a MethodChannel.
abstract class TtsEngine {
  Future<void> setLanguage(String language);

  Future<void> setSpeechRate(double rate);

  Future<void> speak(String text);

  Future<void> stop();

  void setStartHandler(void Function() handler);

  void setCompletionHandler(void Function() handler);

  void setCancelHandler(void Function() handler);

  void setErrorHandler(void Function() handler);
}

/// [TtsEngine] backed by `flutter_tts`.
class FlutterTtsEngine implements TtsEngine {
  FlutterTtsEngine([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  Future<void> setLanguage(String language) async {
    await _tts.setLanguage(language);
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    await _tts.setSpeechRate(rate);
  }

  @override
  Future<void> speak(String text) async {
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }

  @override
  void setStartHandler(void Function() handler) {
    _tts.setStartHandler(handler);
  }

  @override
  void setCompletionHandler(void Function() handler) {
    _tts.setCompletionHandler(handler);
  }

  @override
  void setCancelHandler(void Function() handler) {
    _tts.setCancelHandler(handler);
  }

  @override
  void setErrorHandler(void Function() handler) {
    _tts.setErrorHandler((dynamic _) => handler());
  }
}

/// [TtsService] backed by `flutter_tts` (SPEC 5.8, PLAN 8.1).
///
/// Language is always `en-US`; the engine rate follows the speech-speed
/// setting; `[[` `]]` markers are stripped before speaking. Starting a new
/// utterance stops the current one first.
class FlutterTtsService implements TtsService {
  FlutterTtsService({required SettingsRepository settings, TtsEngine? engine})
    : _settings = settings,
      _engine = engine ?? FlutterTtsEngine() {
    _engine.setStartHandler(() => _emit(true));
    _engine.setCompletionHandler(() => _emit(false));
    _engine.setCancelHandler(() => _emit(false));
    _engine.setErrorHandler(() => _emit(false));
  }

  final SettingsRepository _settings;
  final TtsEngine _engine;
  final StreamController<bool> _speaking = StreamController<bool>.broadcast();

  @override
  Stream<bool> get isSpeaking => _speaking.stream;

  @override
  Future<void> speak(String text) async {
    await _engine.stop();
    final String cleaned = cleanTtsText(text);
    if (cleaned.isEmpty) {
      _emit(false);
      return;
    }
    await _engine.setLanguage(ttsLanguage);
    await _engine.setSpeechRate(ttsEngineRate(_settings.speechSpeed));
    await _engine.speak(cleaned);
    _emit(true);
  }

  @override
  Future<void> stop() async {
    await _engine.stop();
    _emit(false);
  }

  void _emit(bool value) {
    if (!_speaking.isClosed) {
      _speaking.add(value);
    }
  }

  /// Closes the underlying stream controller.
  Future<void> dispose() => _speaking.close();
}

/// TTS provider.
///
/// Production default is [FlutterTtsService]; tests override with
/// [FakeTtsService].
final ttsServiceProvider = Provider<TtsService>((ref) {
  final FlutterTtsService service = FlutterTtsService(
    settings: ref.watch(settingsRepositoryProvider),
  );
  ref.onDispose(() async {
    await service.dispose();
  });
  return service;
});
