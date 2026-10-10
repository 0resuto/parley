import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage for the LLM API key.
///
/// The key lives in secure storage, never in [SettingsRepository].
abstract class SecureKeyStore {
  Future<String?> readApiKey();

  Future<void> writeApiKey(String apiKey);

  Future<void> deleteApiKey();
}

/// Real implementation backed by `flutter_secure_storage`.
class FlutterSecureKeyStore implements SecureKeyStore {
  FlutterSecureKeyStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _apiKeyKey = 'api_key';

  @override
  Future<String?> readApiKey() => _storage.read(key: _apiKeyKey);

  @override
  Future<void> writeApiKey(String apiKey) =>
      _storage.write(key: _apiKeyKey, value: apiKey);

  @override
  Future<void> deleteApiKey() => _storage.delete(key: _apiKeyKey);
}

/// In-memory API key store.
///
/// Default for widget tests and for the settings providers before `main()`
/// overrides them with [FlutterSecureKeyStore]. Never touches the device.
class MemorySecureKeyStore implements SecureKeyStore {
  MemorySecureKeyStore([String? apiKey]) : _apiKey = apiKey;

  String? _apiKey;

  @override
  Future<String?> readApiKey() async => _apiKey;

  @override
  Future<void> writeApiKey(String apiKey) async {
    _apiKey = apiKey;
  }

  @override
  Future<void> deleteApiKey() async {
    _apiKey = null;
  }
}
