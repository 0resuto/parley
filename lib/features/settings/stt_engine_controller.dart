import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/services/stt/stt_engine.dart';
import 'settings_providers.dart';

/// Reactive wrapper around the stored recognition-engine setting.
class SttEngineController extends Notifier<SttEngineKind> {
  @override
  SttEngineKind build() => ref.read(sttSettingsProvider).engine;

  Future<void> select(SttEngineKind engine) async {
    if (state == engine) {
      return;
    }
    await ref.read(sttSettingsProvider).setEngine(engine);
    if (ref.mounted) {
      state = engine;
    }
  }
}

/// Currently selected voice-input engine.
final sttEngineProvider = NotifierProvider<SttEngineController, SttEngineKind>(
  SttEngineController.new,
);
