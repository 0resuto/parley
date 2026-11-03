import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/features/settings/stt_engine_controller.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_providers.dart';
import 'package:parley/services/stt/stt_service.dart';

/// Loads the selected recognition model in the background.
///
/// The first microphone tap otherwise pays the model-loading cost. Warm-up is
/// best-effort: a failure is ignored here because starting voice input shows
/// the specific model error.
class SttWarmupController extends Notifier<void> {
  @override
  void build() {
    ref.listen<SttModelsState>(sttModelsControllerProvider, (_, next) {
      _warm(next, ref.read(sttEngineProvider));
    });
    ref.listen<SttEngineKind>(sttEngineProvider, (_, next) {
      _warm(ref.read(sttModelsControllerProvider), next);
    });
    Future<void>.microtask(() {
      if (!ref.mounted) {
        return;
      }
      _warm(ref.read(sttModelsControllerProvider), ref.read(sttEngineProvider));
    });
  }

  Future<void> _warm(SttModelsState models, SttEngineKind engine) async {
    if (!models.statusOf(engine).isReady) {
      return;
    }
    final SttService service = ref.read(sttServiceProvider);
    try {
      await service.initialize();
    } catch (_) {
      // The next mic start retries and reports the real failure.
    }
  }
}

/// Keeps the selected speech model warm for the whole app session.
final sttWarmupProvider = NotifierProvider<SttWarmupController, void>(
  SttWarmupController.new,
);
