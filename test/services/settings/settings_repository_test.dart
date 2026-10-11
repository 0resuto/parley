import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSecureKeyStore implements SecureKeyStore {
  String? apiKey;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<void> writeApiKey(String key) async {
    apiKey = key;
  }

  @override
  Future<void> deleteApiKey() async {
    apiKey = null;
  }
}

void main() {
  late FakeSecureKeyStore keyStore;
  late SharedPreferences prefs;
  late SharedPreferencesSettingsRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    keyStore = FakeSecureKeyStore();
    repo = SharedPreferencesSettingsRepository(prefs, keyStore);
  });

  test('defaults match the spec', () async {
    expect(repo.baseUrl, SharedPreferencesSettingsRepository.defaultBaseUrl);
    expect(repo.baseUrl, 'https://api.openai.com/v1');
    expect(repo.model, '');
    expect(repo.newWordPercent, 10);
    expect(repo.autoPlay, isFalse);
    expect(repo.speechSpeed, 1.0);
    expect(repo.contextTranslation, isTrue);
    expect(repo.meaningLanguage, 'ru');
    expect(await repo.isLlmConfigured(), isFalse);
  });

  test('writes are persisted and readable', () async {
    await repo.setBaseUrl('https://example.com/v1');
    await repo.setModel('my-model');
    await repo.setNewWordPercent(20);
    await repo.setAutoPlay(true);
    await repo.setSpeechSpeed(1.2);
    await repo.setContextTranslation(false);
    await keyStore.writeApiKey('secret');

    expect(repo.baseUrl, 'https://example.com/v1');
    expect(repo.model, 'my-model');
    expect(repo.newWordPercent, 20);
    expect(repo.autoPlay, isTrue);
    expect(repo.speechSpeed, 1.2);
    expect(repo.contextTranslation, isFalse);
    expect(await keyStore.readApiKey(), 'secret');
    expect(await repo.isLlmConfigured(), isTrue);
  });

  test('contextTranslation round-trips through prefs', () async {
    await repo.setContextTranslation(false);
    expect(repo.contextTranslation, isFalse);
    expect(prefs.getBool('context_translation'), isFalse);

    await repo.setContextTranslation(true);
    expect(repo.contextTranslation, isTrue);
    expect(prefs.getBool('context_translation'), isTrue);
  });

  test('meaningLanguage round-trips and is normalized', () async {
    await repo.setMeaningLanguage('DE');
    expect(repo.meaningLanguage, 'de');
    expect(prefs.getString('meaning_language'), 'de');

    await repo.setMeaningLanguage('  es  ');
    expect(repo.meaningLanguage, 'es');

    // An empty value falls back to the default.
    await repo.setMeaningLanguage('   ');
    expect(repo.meaningLanguage, 'ru');
  });

  test('baseUrl and model are trimmed', () async {
    await repo.setBaseUrl('  https://example.com  ');
    await repo.setModel('  m  ');
    expect(repo.baseUrl, 'https://example.com');
    expect(repo.model, 'm');
  });

  test('newWordPercent is clamped to 0..30 and snapped to step 5', () async {
    await repo.setNewWordPercent(33);
    expect(repo.newWordPercent, 30);

    await repo.setNewWordPercent(-5);
    expect(repo.newWordPercent, 0);

    await repo.setNewWordPercent(7);
    expect(repo.newWordPercent, 5);

    await repo.setNewWordPercent(8);
    expect(repo.newWordPercent, 10);

    await repo.setNewWordPercent(0);
    expect(repo.newWordPercent, 0);

    await repo.setNewWordPercent(30);
    expect(repo.newWordPercent, 30);
  });

  test('newWordPercent getter normalizes legacy stored values', () async {
    await prefs.setInt('new_word_percent', 28);
    expect(repo.newWordPercent, 30);

    await prefs.setInt('new_word_percent', 100);
    expect(repo.newWordPercent, 30);
  });

  test('speechSpeed is clamped to 0.5..1.5', () async {
    await repo.setSpeechSpeed(2.0);
    expect(repo.speechSpeed, 1.5);

    await repo.setSpeechSpeed(0.0);
    expect(repo.speechSpeed, 0.5);

    await repo.setSpeechSpeed(1.2);
    expect(repo.speechSpeed, 1.2);

    await prefs.setDouble('speech_speed', 99.0);
    expect(repo.speechSpeed, 1.5);
  });

  test('isLlmConfigured needs url, model and key', () async {
    expect(await repo.isLlmConfigured(), isFalse);

    await repo.setModel('m');
    await keyStore.writeApiKey('k');
    expect(await repo.isLlmConfigured(), isTrue);

    await repo.setBaseUrl('');
    expect(await repo.isLlmConfigured(), isFalse);

    await repo.setBaseUrl('https://example.com');
    await repo.setModel('');
    expect(await repo.isLlmConfigured(), isFalse);

    await repo.setModel('m');
    await keyStore.deleteApiKey();
    expect(await repo.isLlmConfigured(), isFalse);

    await keyStore.writeApiKey('   ');
    expect(await repo.isLlmConfigured(), isFalse);
  });

  test('secure key store fake writes and deletes', () async {
    expect(await keyStore.readApiKey(), isNull);
    await keyStore.writeApiKey('k1');
    expect(await keyStore.readApiKey(), 'k1');
    await keyStore.deleteApiKey();
    expect(await keyStore.readApiKey(), isNull);
  });
}
