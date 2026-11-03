import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/settings/stt_settings.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_service.dart';
import 'package:parley/services/stt/switchable_stt_service.dart';

class RecordingSttService implements SttService {
  final List<String> calls = [];
  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();

  @override
  Future<bool> initialize() async {
    calls.add('initialize');
    return true;
  }

  @override
  Future<void> start() async {
    calls.add('start');
    _events.add(const SttStarted());
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
  }

  @override
  Stream<SttEvent> get events => _events.stream;

  void emitFinal(String text) => _events.add(SttFinalResult(text));

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _events.close();
  }
}

void main() {
  late Directory directory;
  late MemorySttSettings settings;
  late RecordingSttService local;
  late SwitchableSttService? service;
  late List<SttEvent> events;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('parley_switch_');
    settings = MemorySttSettings();
    local = RecordingSttService();
    service = null;
    events = [];
  });

  tearDown(() async {
    await service?.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  SwitchableSttService build({
    Future<Directory?> Function(SttEngineKind)? modelDirectory,
    Future<SttService> Function(SttEngineKind, Directory)? localFactory,
  }) {
    final SwitchableSttService created = SwitchableSttService(
      settings: settings,
      modelDirectory: modelDirectory ?? (SttEngineKind _) async => directory,
      localFactory:
          localFactory ?? (SttEngineKind _, Directory _) async => local,
    );
    created.events.listen(events.add);
    service = created;
    return created;
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('initialize preloads the selected engine without recording', () async {
    final SwitchableSttService router = build();

    expect(await router.initialize(), isTrue);
    await flush();
    expect(local.calls, ['initialize']);
    expect(events, isEmpty);

    await router.start();
    await flush();
    expect(local.calls, ['initialize', 'start']);
    expect(events.whereType<SttStarted>(), hasLength(1));
  });

  test('initialize is idempotent while the model is loading', () async {
    final SwitchableSttService router = build();

    await Future.wait(<Future<bool>>[router.initialize(), router.initialize()]);
    await flush();

    expect(
      local.calls.where((String call) => call == 'initialize'),
      hasLength(1),
    );
  });

  test('initialize skips a missing offline model', () async {
    await settings.setEngine(SttEngineKind.moonshine);
    final SwitchableSttService router = build(
      modelDirectory: (SttEngineKind _) async => null,
    );

    expect(await router.initialize(), isTrue);
    await flush();
    expect(local.calls, isEmpty);
  });

  test('uses the selected local engine', () async {
    await build().start();
    await flush();

    expect(local.calls, ['start']);
    expect(events.whereType<SttStarted>(), hasLength(1));
  });

  test('a missing offline model reports a model failure', () async {
    await settings.setEngine(SttEngineKind.moonshine);
    await build(modelDirectory: (SttEngineKind _) async => null).start();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttModelMissingFailure>(),
    );
    expect(local.calls, isEmpty);
  });

  test('a ready offline model uses the local engine', () async {
    await settings.setEngine(SttEngineKind.moonshine);
    await build().start();
    await flush();

    expect(local.calls, ['start']);
    expect(events.whereType<SttStarted>(), hasLength(1));
  });

  test('switching local engines disposes the previous recognizer', () async {
    final Map<SttEngineKind, RecordingSttService> locals =
        <SttEngineKind, RecordingSttService>{
          SttEngineKind.moonshine: RecordingSttService(),
          SttEngineKind.whisper: RecordingSttService(),
        };
    await settings.setEngine(SttEngineKind.moonshine);
    final SwitchableSttService router = build(
      localFactory: (SttEngineKind engine, Directory _) async =>
          locals[engine]!,
    );
    await router.start();
    await flush();

    await settings.setEngine(SttEngineKind.whisper);
    await router.start();
    await flush();

    expect(locals[SttEngineKind.moonshine]!.calls, contains('dispose'));
    expect(locals[SttEngineKind.whisper]!.calls, isNot(contains('dispose')));
  });

  test('switching back reloads a released local engine', () async {
    final Map<SttEngineKind, int> created = <SttEngineKind, int>{};
    await settings.setEngine(SttEngineKind.moonshine);
    final SwitchableSttService router = build(
      localFactory: (SttEngineKind engine, Directory _) async {
        created[engine] = (created[engine] ?? 0) + 1;
        return RecordingSttService();
      },
    );
    await router.start();
    await flush();
    await settings.setEngine(SttEngineKind.whisper);
    await router.start();
    await flush();
    await settings.setEngine(SttEngineKind.moonshine);
    await router.start();
    await flush();

    expect(created[SttEngineKind.moonshine], 2);
    expect(created[SttEngineKind.whisper], 1);
  });

  test('a local factory failure reports a load failure', () async {
    await settings.setEngine(SttEngineKind.moonshine);
    await build(
      localFactory: (SttEngineKind _, Directory _) async {
        throw StateError('load failed');
      },
    ).start();
    await flush();

    expect(
      events.whereType<SttFailed>().single.failure,
      isA<SttModelLoadFailure>(),
    );
  });

  test('events from the active engine are forwarded', () async {
    await build().start();
    await flush();

    local.emitFinal('hello');
    await flush();

    expect(events.whereType<SttFinalResult>().single.text, 'hello');
  });

  test('dispose disposes the used services', () async {
    final SwitchableSttService created = build();
    await created.start();
    await flush();
    await created.dispose();

    expect(local.calls, contains('dispose'));
  });
}
