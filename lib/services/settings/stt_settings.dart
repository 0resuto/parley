import 'package:shared_preferences/shared_preferences.dart';

import 'package:parley/services/stt/stt_engine.dart';

/// Voice-input settings (SPEC 5.8, 5.10).
///
/// Kept separate from [SettingsRepository] so the text-to-speech and tutor
/// settings do not grow with every speech-engine option.
abstract class SttSettings {
  /// Recognition engine used by the composer.
  SttEngineKind get engine;

  /// Send the final recognized text immediately instead of inserting it.
  bool get autoSend;

  Future<void> setEngine(SttEngineKind value);

  Future<void> setAutoSend(bool value);
}

/// SharedPreferences implementation of [SttSettings].
class SharedPreferencesSttSettings implements SttSettings {
  SharedPreferencesSttSettings(this._prefs);

  final SharedPreferences _prefs;

  static const SttEngineKind defaultEngine = SttEngineKind.whisper;
  static const bool defaultAutoSend = false;

  static const _kEngine = 'stt_engine';
  static const _kAutoSend = 'stt_auto_send';

  @override
  SttEngineKind get engine {
    final String? stored = _prefs.getString(_kEngine);
    return SttEngineKind.values.firstWhere(
      (SttEngineKind value) => value.name == stored,
      orElse: () => defaultEngine,
    );
  }

  @override
  bool get autoSend => _prefs.getBool(_kAutoSend) ?? defaultAutoSend;

  @override
  Future<void> setEngine(SttEngineKind value) =>
      _prefs.setString(_kEngine, value.name);

  @override
  Future<void> setAutoSend(bool value) => _prefs.setBool(_kAutoSend, value);
}

/// In-memory settings used by widget tests.
class MemorySttSettings implements SttSettings {
  MemorySttSettings({
    SttEngineKind engine = SharedPreferencesSttSettings.defaultEngine,
    bool autoSend = SharedPreferencesSttSettings.defaultAutoSend,
  }) : _engine = engine,
       _autoSend = autoSend;

  SttEngineKind _engine;
  bool _autoSend;

  @override
  SttEngineKind get engine => _engine;

  @override
  bool get autoSend => _autoSend;

  @override
  Future<void> setEngine(SttEngineKind value) async {
    _engine = value;
  }

  @override
  Future<void> setAutoSend(bool value) async {
    _autoSend = value;
  }
}
