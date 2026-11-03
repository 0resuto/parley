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
    expect(settings.engine, SttEngineKind.whisper);
    expect(settings.autoSend, isFalse);
    expect(settings.autoStop, isTrue);
  });

  test('writes are persisted', () async {
    await settings.setEngine(SttEngineKind.moonshine);
    await settings.setAutoSend(true);
    await settings.setAutoStop(false);

    expect(settings.engine, SttEngineKind.moonshine);
    expect(settings.autoSend, isTrue);
    expect(settings.autoStop, isFalse);
    expect(prefs.getString('stt_engine'), 'moonshine');
    expect(prefs.getBool('stt_auto_send'), isTrue);
    expect(prefs.getBool('stt_auto_stop'), isFalse);
  });

  test('an unknown or removed stored engine falls back to Whisper', () async {
    await prefs.setString('stt_engine', 'system');

    expect(settings.engine, SttEngineKind.whisper);
  });

  test('memory settings round-trip', () async {
    final MemorySttSettings memory = MemorySttSettings();
    expect(memory.engine, SttEngineKind.whisper);
    expect(memory.autoSend, isFalse);
    expect(memory.autoStop, isTrue);

    await memory.setEngine(SttEngineKind.moonshine);
    await memory.setAutoSend(true);
    await memory.setAutoStop(false);

    expect(memory.engine, SttEngineKind.moonshine);
    expect(memory.autoSend, isTrue);
    expect(memory.autoStop, isFalse);
  });
}
