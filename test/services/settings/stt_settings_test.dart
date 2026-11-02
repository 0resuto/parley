import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/settings/stt_settings.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late SharedPreferencesSttSettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    settings = SharedPreferencesSttSettings(prefs);
  });

  test('defaults match the spec', () {
    expect(settings.engine, SttEngineKind.system);
    expect(settings.autoSend, isFalse);
    expect(settings.preferOnDevice, isTrue);
  });

  test('writes are persisted', () async {
    await settings.setEngine(SttEngineKind.whisper);
    await settings.setAutoSend(true);
    await settings.setPreferOnDevice(false);

    expect(settings.engine, SttEngineKind.whisper);
    expect(settings.autoSend, isTrue);
    expect(settings.preferOnDevice, isFalse);
    expect(prefs.getString('stt_engine'), 'whisper');
    expect(prefs.getBool('stt_auto_send'), isTrue);
    expect(prefs.getBool('stt_prefer_on_device'), isFalse);
  });

  test('an unknown stored engine falls back to system', () async {
    await prefs.setString('stt_engine', 'unknown');

    expect(settings.engine, SttEngineKind.system);
  });

  test('memory settings round-trip', () async {
    final MemorySttSettings memory = MemorySttSettings();
    expect(memory.engine, SttEngineKind.system);
    expect(memory.autoSend, isFalse);
    expect(memory.preferOnDevice, isTrue);

    await memory.setEngine(SttEngineKind.moonshine);
    await memory.setAutoSend(true);
    await memory.setPreferOnDevice(false);

    expect(memory.engine, SttEngineKind.moonshine);
    expect(memory.autoSend, isTrue);
    expect(memory.preferOnDevice, isFalse);
  });
}
