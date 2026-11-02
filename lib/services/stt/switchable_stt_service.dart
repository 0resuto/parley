import 'dart:async';
import 'dart:io';

import 'package:parley/services/settings/stt_settings.dart';
import 'stt_engine.dart';
import 'stt_model.dart';
import 'stt_service.dart';
import 'sherpa_stt_service.dart';

/// Routes voice input to the system recognizer or a downloaded offline model.
class SwitchableSttService implements SttService {
  SwitchableSttService({
    required SttSettings settings,
    required Future<Directory?> Function(SttEngineKind) modelDirectory,
    SttService? systemService,
    Future<SttService> Function(SttEngineKind, Directory)? localFactory,
  }) : _settings = settings,
       _modelDirectory = modelDirectory,
       _system = systemService ?? SystemSttService(),
       _localFactory =
           localFactory ??
           ((SttEngineKind engine, Directory directory) async {
             return SherpaSttService(engine: engine, modelDirectory: directory);
           });

  final SttSettings _settings;
  final Future<Directory?> Function(SttEngineKind) _modelDirectory;
  final SttService _system;
  final Future<SttService> Function(SttEngineKind, Directory) _localFactory;
  final Map<SttEngineKind, SttService> _local = {};
  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();

  SttService? _active;
  StreamSubscription<SttEvent>? _subscription;
  bool _disposed = false;

  @override
  Stream<SttEvent> get events => _events.stream;

  @override
  Future<bool> initialize() async => !_disposed;

  @override
  Future<void> start({bool preferOnDevice = true}) async {
    if (_disposed) {
      return;
    }
    final SttEngineKind engine = _settings.engine;
    if (engine == SttEngineKind.system) {
      await _activate(_system);
      await _system.start(preferOnDevice: preferOnDevice);
      return;
    }
    final SttModel? model = sttModelFor(engine);
    Directory? directory;
    try {
      directory = await _modelDirectory(engine);
    } catch (_) {
      directory = null;
    }
    if (directory == null) {
      _emit(SttFailed(SttModelMissingFailure(model?.name ?? 'offline')));
      return;
    }
    SttService? local = _local[engine];
    if (local == null) {
      try {
        local = await _localFactory(engine, directory);
        _local[engine] = local;
      } catch (_) {
        _emit(SttFailed(SttModelLoadFailure(model?.name ?? 'offline')));
        return;
      }
    }
    await _activate(local, localEngine: engine);
    await local.start();
  }

  @override
  Future<void> stop() async {
    final SttService? active = _active;
    if (active == null) {
      _emit(const SttStopped());
      return;
    }
    await active.stop();
  }

  @override
  Future<void> cancel() async {
    await _active?.cancel();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    _active = null;
    final Set<SttService> services = <SttService>{_system, ..._local.values};
    _local.clear();
    for (final SttService service in services) {
      await service.dispose();
    }
    await _events.close();
  }

  Future<void> _activate(
    SttService service, {
    SttEngineKind? localEngine,
  }) async {
    if (!identical(_active, service)) {
      final SttService? old = _active;
      await _subscription?.cancel();
      _active = service;
      _subscription = service.events.listen(_emit);
      if (old != null) {
        await old.cancel();
      }
    }
    await _disposeOtherLocals(localEngine);
  }

  /// Keeps at most one offline model loaded in memory.
  Future<void> _disposeOtherLocals(SttEngineKind? keep) async {
    final List<SttEngineKind> stale = _local.keys
        .where((SttEngineKind engine) => engine != keep)
        .toList();
    for (final SttEngineKind engine in stale) {
      final SttService? service = _local.remove(engine);
      if (service != null && !identical(service, _active)) {
        await service.dispose();
      }
    }
  }

  void _emit(SttEvent event) {
    if (!_disposed && !_events.isClosed) {
      _events.add(event);
    }
  }
}
