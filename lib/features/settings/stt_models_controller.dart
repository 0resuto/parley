import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model.dart';
import 'package:parley/services/stt/stt_model_manager.dart';
import 'package:parley/services/stt/stt_providers.dart';

/// Statuses of the downloadable offline models.
class SttModelsState {
  const SttModelsState(this.statuses);

  final Map<SttEngineKind, SttModelStatus> statuses;

  SttModelStatus statusOf(SttEngineKind engine) =>
      statuses[engine] ?? const SttModelStatus();

  bool get isBusy => statuses.values.any((SttModelStatus value) {
    return value.isBusy;
  });
}

/// Riverpod state for offline model downloads (SPEC 5.10).
class SttModelsController extends Notifier<SttModelsState> {
  late final SttModelManager _manager;
  StreamSubscription<Map<SttEngineKind, SttModelStatus>>? _subscription;

  @override
  SttModelsState build() {
    _manager = ref.watch(sttModelManagerProvider);
    _subscription = _manager.states.listen((
      Map<SttEngineKind, SttModelStatus> statuses,
    ) {
      if (ref.mounted) {
        state = SttModelsState(statuses);
      }
    });
    ref.onDispose(() {
      _subscription?.cancel();
    });
    unawaited(_manager.refresh());
    return SttModelsState(_manager.snapshot);
  }

  SttModel? modelFor(SttEngineKind engine) => _manager.modelFor(engine);

  Future<bool> download(SttEngineKind engine) => _manager.download(engine);

  Future<void> cancel() => _manager.cancel();

  Future<void> delete(SttEngineKind engine) => _manager.delete(engine);
}

/// Download state for the offline speech models.
final sttModelsControllerProvider =
    NotifierProvider<SttModelsController, SttModelsState>(
      SttModelsController.new,
    );
