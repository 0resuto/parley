import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:parley/features/settings/settings_providers.dart';
import 'stt_model_manager.dart';
import 'stt_service.dart';
import 'switchable_stt_service.dart';

/// Offline model storage and downloads.
final sttModelManagerProvider = Provider<SttModelManager>((ref) {
  final SttModelManager manager = SttModelManager(
    supportDirectory: getApplicationSupportDirectory,
  );
  ref.onDispose(() async {
    await manager.dispose();
  });
  return manager;
});

/// Voice input, routed to the engine selected in Settings.
final sttServiceProvider = Provider<SttService>((ref) {
  final SttModelManager models = ref.watch(sttModelManagerProvider);
  final SwitchableSttService service = SwitchableSttService(
    settings: ref.watch(sttSettingsProvider),
    modelDirectory: models.readyDirectory,
  );
  ref.onDispose(() async {
    await service.dispose();
  });
  return service;
});
