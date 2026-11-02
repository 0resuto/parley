import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/stt/stt_service.dart';

class FakeSttEngine implements SttEngine {
  FakeSttEngine({this.available = true});

  bool available;
  bool listening = false;
  final List<String> calls = [];
  bool? lastOnDevice;
  void Function(String status)? _onStatus;
  void Function(String code)? _onError;
  void Function(String text, bool isFinal)? _onResult;
  void Function(double level)? _onLevel;

  @override
  bool get isListening => listening;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String code) onError,
  }) async {
    calls.add('initialize');
    _onStatus = onStatus;
    _onError = onError;
    return available;
  }

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required bool onDevice,
    void Function(double level)? onLevel,
  }) async {
    calls.add('listen:$onDevice');
    lastOnDevice = onDevice;
    _onResult = onResult;
    _onLevel = onLevel;
    listening = true;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    listening = false;
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    listening = false;
  }

  void emitStatus(String status) => _onStatus?.call(status);

  void emitError(String code) => _onError?.call(code);

  void emitResult(String text, {bool isFinal = false}) =>
      _onResult?.call(text, isFinal);

  void emitLevel(double level) => _onLevel?.call(level);
}

void main() {
  test('voice input uses English (US)', () {
    expect(sttLanguage, 'en-US');
    expect(sttLocaleId, 'en_US');
  });

  test('normalizes Android RMS dB levels', () {
    expect(normalizeDbLevel(0), 1);
    expect(normalizeDbLevel(-60), 0);
    expect(normalizeDbLevel(-30), closeTo(0.5, 0.001));
  });

  test('builds an approximate spectrum from a level', () {
    expect(levelSpectrum(0), everyElement(0));
    expect(levelSpectrum(1).reduce((a, b) => a > b ? a : b), 1);
  });

  group('mapSttError', () {
    test('maps permission, speech, network, busy and unknown errors', () {
      expect(mapSttError('error_permission'), isA<SttPermissionFailure>());
      expect(mapSttError('error_no_match'), isA<SttNoSpeechFailure>());
      expect(mapSttError('error_network'), isA<SttNetworkFailure>());
      expect(mapSttError('error_busy'), isA<SttBusyFailure>());
      expect(mapSttError('error_unknown'), isA<SttUnknownFailure>());
    });
  });

  group('SystemSttService', () {
    late FakeSttEngine engine;
    late SystemSttService service;
    late List<SttEvent> events;
    late List<SttEvent> failures;

    setUp(() {
      engine = FakeSttEngine();
      service = SystemSttService(engine: engine);
      events = [];
      failures = [];
      service.events.listen((SttEvent event) {
        events.add(event);
        if (event is SttFailed) {
          failures.add(event);
        }
      });
    });

    tearDown(() async {
      await service.dispose();
    });

    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('unavailable recognizer emits a typed failure', () async {
      engine.available = false;

      await service.start();
      await flush();

      expect(engine.calls, ['initialize']);
      expect(failures, hasLength(1));
      expect(
        (failures.single as SttFailed).failure,
        isA<SttUnavailableFailure>(),
      );
    });

    test('start prefers on-device recognition and forwards events', () async {
      await service.start(preferOnDevice: true);
      engine.emitStatus('listening');
      engine.emitResult('hello', isFinal: false);
      engine.emitResult('hello world', isFinal: true);
      engine.emitStatus('done');
      await flush();

      expect(engine.lastOnDevice, isTrue);
      expect(events.whereType<SttStarted>(), hasLength(1));
      expect(events.whereType<SttPartial>().single.text, 'hello');
      expect(events.whereType<SttFinalResult>().single.text, 'hello world');
      expect(events.whereType<SttStopped>(), hasLength(1));
    });

    test('the device default is used when on-device is off', () async {
      await service.start(preferOnDevice: false);
      expect(engine.lastOnDevice, isFalse);
    });

    test('a synchronous on-device failure retries without on-device', () async {
      final ThrowingEngine throwing = ThrowingEngine();
      final SystemSttService retrying = SystemSttService(engine: throwing);
      addTearDown(retrying.dispose);

      await retrying.start(preferOnDevice: true);

      expect(throwing.listenCalls, 2);
      expect(throwing.lastOnDevice, isFalse);
    });

    test('an on-device platform error retries silently once', () async {
      await service.start(preferOnDevice: true);
      engine.emitError('error_language_unavailable');
      await flush();

      expect(engine.calls.where((String call) => call.startsWith('listen')), [
        'listen:true',
        'listen:false',
      ]);
      expect(failures, isEmpty);
    });

    test('a second on-device error surfaces a failure', () async {
      await service.start(preferOnDevice: true);
      engine.emitError('error_language_unavailable');
      await flush();
      engine.emitError('error_language_unavailable');
      await flush();

      expect(failures, hasLength(1));
    });

    test('duplicate and empty final results are ignored', () async {
      await service.start();
      engine.emitResult('  ', isFinal: false);
      engine.emitResult('hello', isFinal: true);
      engine.emitResult('hello', isFinal: true);
      await flush();

      expect(events.whereType<SttFinalResult>(), hasLength(1));
      expect(events.whereType<SttPartial>(), isEmpty);
    });

    test('microphone levels are forwarded as normalized events', () async {
      await service.start();
      engine.emitLevel(-30);
      await flush();

      expect(events.whereType<SttLevel>().single.level, closeTo(0.5, 0.001));
      expect(events.whereType<SttAudioSpectrum>(), isNotEmpty);
    });

    test('stop and cancel reach the engine', () async {
      await service.start();
      await service.stop();
      await service.cancel();

      expect(engine.calls, containsAllInOrder(['stop', 'cancel']));
    });
  });
}

class ThrowingEngine extends FakeSttEngine {
  int listenCalls = 0;

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required bool onDevice,
    void Function(double level)? onLevel,
  }) async {
    listenCalls++;
    lastOnDevice = onDevice;
    if (onDevice) {
      throw StateError('on-device unavailable');
    }
  }
}
