import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/settings/secure_key_store.dart';
import 'package:parley/services/settings/settings_repository.dart';
import 'package:parley/services/tts/tts_service.dart';

class FakeTtsEngine implements TtsEngine {
  final List<String> calls = [];
  String? language;
  double? rate;
  String? spoken;
  int stopCount = 0;

  void Function()? _onStart;
  void Function()? _onComplete;
  void Function()? _onCancel;
  void Function()? _onError;

  @override
  Future<void> setLanguage(String value) async {
    language = value;
    calls.add('language:$value');
  }

  @override
  Future<void> setSpeechRate(double value) async {
    rate = value;
    calls.add('rate:$value');
  }

  @override
  Future<void> speak(String text) async {
    spoken = text;
    calls.add('speak:$text');
  }

  @override
  Future<void> stop() async {
    stopCount++;
    calls.add('stop');
  }

  @override
  void setStartHandler(void Function() handler) {
    _onStart = handler;
  }

  @override
  void setCompletionHandler(void Function() handler) {
    _onComplete = handler;
  }

  @override
  void setCancelHandler(void Function() handler) {
    _onCancel = handler;
  }

  @override
  void setErrorHandler(void Function() handler) {
    _onError = handler;
  }

  void emitStart() => _onStart?.call();

  void emitComplete() => _onComplete?.call();

  void emitCancel() => _onCancel?.call();

  void emitError() => _onError?.call();
}

MemorySettingsRepository settingsWithSpeed(double speed) {
  return MemorySettingsRepository(MemorySecureKeyStore(), speechSpeed: speed);
}

void main() {
  group('cleanTtsText', () {
    test('leaves plain text unchanged', () {
      expect(cleanTtsText('Hello world'), 'Hello world');
    });

    test('removes markers but keeps the inner word', () {
      expect(cleanTtsText('Say [[heifer]] please'), 'Say heifer please');
    });

    test('removes several markers', () {
      expect(cleanTtsText('[[cow]] and [[heifer]]'), 'cow and heifer');
    });

    test('empty and marker-only inputs', () {
      expect(cleanTtsText(''), isEmpty);
      expect(cleanTtsText('[[]]'), isEmpty);
    });
  });

  group('ttsEngineRate', () {
    test('is half the speed setting', () {
      expect(ttsEngineRate(0.5), 0.25);
      expect(ttsEngineRate(1.0), 0.5);
      expect(ttsEngineRate(1.5), 0.75);
    });

    test('clamps out-of-range speeds', () {
      expect(ttsEngineRate(0.0), 0.25);
      expect(ttsEngineRate(2.0), 0.75);
    });

    test('NaN falls back to the default speed', () {
      expect(ttsEngineRate(double.nan), 0.5);
    });
  });

  group('FlutterTtsService', () {
    test('language is en-US', () {
      expect(ttsLanguage, 'en-US');
    });

    test('speak cleans text and sets language and rate', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final FlutterTtsService service = FlutterTtsService(
        settings: settingsWithSpeed(1.0),
        engine: engine,
      );
      await service.speak('Say [[heifer]] please');

      expect(engine.language, 'en-US');
      expect(engine.rate, 0.5);
      expect(engine.spoken, 'Say heifer please');
      await service.dispose();
    });

    test('rate follows the speed setting', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final FlutterTtsService service = FlutterTtsService(
        settings: settingsWithSpeed(1.5),
        engine: engine,
      );
      await service.speak('hello');

      expect(engine.rate, 0.75);
      await service.dispose();
    });

    test('speak stops the current playback first', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final FlutterTtsService service = FlutterTtsService(
        settings: settingsWithSpeed(1.0),
        engine: engine,
      );
      await service.speak('hello');

      expect(engine.calls.first, 'stop');
      expect(engine.calls.last, startsWith('speak:'));
      await service.dispose();
    });

    test('empty text after cleaning never reaches the engine', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final FlutterTtsService service = FlutterTtsService(
        settings: settingsWithSpeed(1.0),
        engine: engine,
      );
      await service.speak('[[]]');

      expect(engine.spoken, isNull);
      expect(engine.language, isNull);
      await service.dispose();
    });

    test('isSpeaking follows handlers and stop', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final FlutterTtsService service = FlutterTtsService(
        settings: settingsWithSpeed(1.0),
        engine: engine,
      );
      final List<bool> events = [];
      final sub = service.isSpeaking.listen(events.add);

      engine.emitStart();
      engine.emitComplete();
      await service.speak('hello');
      await service.stop();

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, [true, false, true, false]);
      await service.dispose();
    });
  });

  group('FakeTtsService', () {
    test('records spoken texts', () async {
      final FakeTtsService tts = FakeTtsService();
      await tts.speak('cow');
      expect(tts.spokenTexts, ['cow']);
      await tts.dispose();
    });
  });
}
