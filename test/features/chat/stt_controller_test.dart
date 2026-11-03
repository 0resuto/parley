import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/chat/stt_controller.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/settings/stt_settings.dart';
import 'package:parley/services/stt/stt_providers.dart';
import 'package:parley/services/stt/stt_service.dart';
import 'package:parley/services/tts/tts_service.dart';

import '../../helpers/fake_stt_service.dart';

class FakeStopTts implements TtsService {
  int stopCalls = 0;
  final StreamController<bool> _speaking = StreamController<bool>.broadcast();

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Stream<bool> get isSpeaking => _speaking.stream;
}

void main() {
  late FakeSttService stt;
  late FakeStopTts tts;
  late MemorySttSettings settings;
  late ProviderContainer container;

  setUp(() {
    stt = FakeSttService();
    tts = FakeStopTts();
    settings = MemorySttSettings();
    container = ProviderContainer(
      overrides: [
        sttServiceProvider.overrideWithValue(stt),
        sttSettingsProvider.overrideWithValue(settings),
        ttsServiceProvider.overrideWithValue(tts),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await stt.dispose();
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  SttController controller() => container.read(sttControllerProvider.notifier);

  SttState state() => container.read(sttControllerProvider);

  test('starts listening and stops TTS', () async {
    await controller().start();
    await flush();

    expect(state().phase, SttPhase.listening);
    expect(tts.stopCalls, 1);
    expect(stt.calls, ['initialize', 'start']);
  });

  test('stays busy until the engine reports that it started', () async {
    stt.startEmitsStarted = false;

    await controller().start();
    await flush();
    expect(state().phase, SttPhase.processing);

    stt.emitStarted();
    await flush();
    expect(state().phase, SttPhase.listening);
  });

  test('forwards partials and finals', () async {
    await controller().start();
    await flush();

    stt.emitPartial('hello');
    await flush();
    expect(state().partial, 'hello');
    expect(state().phase, SttPhase.listening);

    stt.emitFinal('hello world');
    await flush();
    expect(state().finalText, 'hello world');
    expect(state().resultSequence, 1);
    expect(state().phase, SttPhase.processing);

    stt.emitStopped();
    await flush();
    expect(state().phase, SttPhase.idle);
  });

  test('stop waits for the final result', () async {
    await controller().start();
    await flush();

    await controller().stop();

    expect(state().phase, SttPhase.processing);
    expect(stt.calls, contains('stop'));
  });

  test('cancel returns to idle', () async {
    await controller().start();
    await flush();

    await controller().cancel();

    expect(state().phase, SttPhase.idle);
    expect(stt.calls, contains('cancel'));
  });

  test('unavailable recognizer becomes a typed failure', () async {
    stt.available = false;

    await controller().start();
    await flush();

    expect(state().phase, SttPhase.idle);
    expect(state().failure, isA<SttUnavailableFailure>());
    expect(state().failureSequence, 1);
  });

  test('toggle starts and stops', () async {
    await controller().toggle();
    await flush();
    expect(state().phase, SttPhase.listening);

    await controller().toggle();
    expect(state().phase, SttPhase.processing);
  });
}
