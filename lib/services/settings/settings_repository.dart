import 'package:shared_preferences/shared_preferences.dart';

import 'secure_key_store.dart';

/// App settings (SPEC 5.10).
///
/// Api key lives in [SecureKeyStore], everything else in SharedPreferences.
abstract class SettingsRepository {
  String get baseUrl;

  String get model;

  int get newWordPercent;

  bool get autoPlay;

  double get speechSpeed;

  Future<void> setBaseUrl(String value);

  Future<void> setModel(String value);

  Future<void> setNewWordPercent(int value);

  Future<void> setAutoPlay(bool value);

  Future<void> setSpeechSpeed(double value);

  /// True when url, model and api key are all non-empty.
  Future<bool> isLlmConfigured();
}

/// SharedPreferences implementation of [SettingsRepository].
class SharedPreferencesSettingsRepository implements SettingsRepository {
  SharedPreferencesSettingsRepository(this._prefs, this._keyStore);

  final SharedPreferences _prefs;
  final SecureKeyStore _keyStore;

  static const defaultBaseUrl = 'https://api.openai.com/v1';
  static const defaultModel = '';
  static const defaultNewWordPercent = 10;
  static const defaultAutoPlay = false;
  static const defaultSpeechSpeed = 1.0;

  static const _kBaseUrl = 'base_url';
  static const _kModel = 'model';
  static const _kNewWordPercent = 'new_word_percent';
  static const _kAutoPlay = 'auto_play';
  static const _kSpeechSpeed = 'speech_speed';

  static int normalizePercent(int value) {
    final int clamped = value.clamp(0, 30);
    return (clamped / 5).round() * 5;
  }

  static double normalizeSpeed(double value) {
    if (value.isNaN) {
      return defaultSpeechSpeed;
    }
    return value.clamp(0.5, 1.5).toDouble();
  }

  @override
  String get baseUrl => _prefs.getString(_kBaseUrl) ?? defaultBaseUrl;

  @override
  String get model => _prefs.getString(_kModel) ?? defaultModel;

  @override
  int get newWordPercent => normalizePercent(
    _prefs.getInt(_kNewWordPercent) ?? defaultNewWordPercent,
  );

  @override
  bool get autoPlay => _prefs.getBool(_kAutoPlay) ?? defaultAutoPlay;

  @override
  double get speechSpeed =>
      normalizeSpeed(_prefs.getDouble(_kSpeechSpeed) ?? defaultSpeechSpeed);

  @override
  Future<void> setBaseUrl(String value) =>
      _prefs.setString(_kBaseUrl, value.trim());

  @override
  Future<void> setModel(String value) =>
      _prefs.setString(_kModel, value.trim());

  @override
  Future<void> setNewWordPercent(int value) =>
      _prefs.setInt(_kNewWordPercent, normalizePercent(value));

  @override
  Future<void> setAutoPlay(bool value) => _prefs.setBool(_kAutoPlay, value);

  @override
  Future<void> setSpeechSpeed(double value) =>
      _prefs.setDouble(_kSpeechSpeed, normalizeSpeed(value));

  @override
  Future<bool> isLlmConfigured() async {
    final String? apiKey = await _keyStore.readApiKey();
    return baseUrl.trim().isNotEmpty &&
        model.trim().isNotEmpty &&
        (apiKey?.trim().isNotEmpty ?? false);
  }
}

/// In-memory settings.
///
/// Default for the settings providers so widget tests work without
/// `SharedPreferences`; `main()` overrides with
/// [SharedPreferencesSettingsRepository]. Never touches the device.
class MemorySettingsRepository implements SettingsRepository {
  MemorySettingsRepository(
    this._keyStore, {
    String baseUrl = SharedPreferencesSettingsRepository.defaultBaseUrl,
    String model = SharedPreferencesSettingsRepository.defaultModel,
    int newWordPercent =
        SharedPreferencesSettingsRepository.defaultNewWordPercent,
    bool autoPlay = SharedPreferencesSettingsRepository.defaultAutoPlay,
    double speechSpeed = SharedPreferencesSettingsRepository.defaultSpeechSpeed,
  }) : _baseUrl = baseUrl,
       _model = model,
       _newWordPercent = newWordPercent,
       _autoPlay = autoPlay,
       _speechSpeed = speechSpeed;

  final SecureKeyStore _keyStore;
  String _baseUrl;
  String _model;
  int _newWordPercent;
  bool _autoPlay;
  double _speechSpeed;

  @override
  String get baseUrl => _baseUrl;

  @override
  String get model => _model;

  @override
  int get newWordPercent =>
      SharedPreferencesSettingsRepository.normalizePercent(_newWordPercent);

  @override
  bool get autoPlay => _autoPlay;

  @override
  double get speechSpeed =>
      SharedPreferencesSettingsRepository.normalizeSpeed(_speechSpeed);

  @override
  Future<void> setBaseUrl(String value) async {
    _baseUrl = value.trim();
  }

  @override
  Future<void> setModel(String value) async {
    _model = value.trim();
  }

  @override
  Future<void> setNewWordPercent(int value) async {
    _newWordPercent = SharedPreferencesSettingsRepository.normalizePercent(
      value,
    );
  }

  @override
  Future<void> setAutoPlay(bool value) async {
    _autoPlay = value;
  }

  @override
  Future<void> setSpeechSpeed(double value) async {
    _speechSpeed = SharedPreferencesSettingsRepository.normalizeSpeed(value);
  }

  @override
  Future<bool> isLlmConfigured() async {
    final String? apiKey = await _keyStore.readApiKey();
    return _baseUrl.trim().isNotEmpty &&
        _model.trim().isNotEmpty &&
        (apiKey?.trim().isNotEmpty ?? false);
  }
}
