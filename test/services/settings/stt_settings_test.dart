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
  });

  test('writes are persisted', () async {
    await settings.setEngine(SttEngineKind.moonshine);
    await settings.setAutoSend(true);

    expect(settings.engine, SttEngineKind.moonshine);
    expect(settings.autoSend, isTrue);
    expect(prefs.getString('stt_engine'), 'moonshine');
    expect(prefs.getBool('stt_auto_send'), isTrue);
  });

  test('an unknown or removed stored engine falls back to Whisper', () async {
    await prefs.setString('stt_engine', 'system');

    expect(settings.engine, SttEngineKind.whisper);
  });

  test('memory settings round-trip', () async {
    final MemorySttSettings memory = MemorySttSettings();
    expect(memory.engine, SttEngineKind.whisper);
    expect(memory.autoSend, isFalse);

    await memory.setEngine(SttEngineKind.moonshine);
    await memory.setAutoSend(true);

    expect(memory.engine, SttEngineKind.moonshine);
    expect(memory.autoSend, isTrue);
  });
}
