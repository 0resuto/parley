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

  /// Ask the system recognizer to stay on the device when possible.
  bool get preferOnDevice;

  Future<void> setEngine(SttEngineKind value);

  Future<void> setAutoSend(bool value);

  Future<void> setPreferOnDevice(bool value);
}

/// SharedPreferences implementation of [SttSettings].
class SharedPreferencesSttSettings implements SttSettings {
  SharedPreferencesSttSettings(this._prefs);

  final SharedPreferences _prefs;

  static const SttEngineKind defaultEngine = SttEngineKind.system;
  static const bool defaultAutoSend = false;
  static const bool defaultPreferOnDevice = true;

  static const _kEngine = 'stt_engine';
  static const _kAutoSend = 'stt_auto_send';
  static const _kPreferOnDevice = 'stt_prefer_on_device';

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
  bool get preferOnDevice =>
      _prefs.getBool(_kPreferOnDevice) ?? defaultPreferOnDevice;

  @override
  Future<void> setEngine(SttEngineKind value) =>
      _prefs.setString(_kEngine, value.name);

  @override
  Future<void> setAutoSend(bool value) => _prefs.setBool(_kAutoSend, value);

  @override
  Future<void> setPreferOnDevice(bool value) =>
      _prefs.setBool(_kPreferOnDevice, value);
}

/// In-memory settings used by widget tests.
class MemorySttSettings implements SttSettings {
  MemorySttSettings({
    SttEngineKind engine = SharedPreferencesSttSettings.defaultEngine,
    bool autoSend = SharedPreferencesSttSettings.defaultAutoSend,
    bool preferOnDevice = SharedPreferencesSttSettings.defaultPreferOnDevice,
  }) : _engine = engine,
       _autoSend = autoSend,
       _preferOnDevice = preferOnDevice;

  SttEngineKind _engine;
  bool _autoSend;
  bool _preferOnDevice;

  @override
  SttEngineKind get engine => _engine;

  @override
  bool get autoSend => _autoSend;

  @override
  bool get preferOnDevice => _preferOnDevice;

  @override
  Future<void> setEngine(SttEngineKind value) async {
    _engine = value;
  }

  @override
  Future<void> setAutoSend(bool value) async {
    _autoSend = value;
  }

  @override
  Future<void> setPreferOnDevice(bool value) async {
    _preferOnDevice = value;
  }
}
