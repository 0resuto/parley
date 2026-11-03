import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model.dart';
import 'package:parley/services/stt/stt_model_manager.dart';
import 'stt_engine_controller.dart';
import 'stt_models_controller.dart';
import 'settings_section.dart';

/// Recognition-engine picker (SPEC 5.10).
class SttEngineSection extends ConsumerWidget {
  const SttEngineSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SttEngineKind selected = ref.watch(sttEngineProvider);
    final SttModelsState models = ref.watch(sttModelsControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Recognition engine',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final SttModel model in sttModels)
          _EngineTile(
            engine: model.engine,
            title: model.name,
            subtitle: _subtitle(models.statusOf(model.engine)),
            selected: selected == model.engine,
            enabled: models.statusOf(model.engine).isReady,
            onTap: () =>
                ref.read(sttEngineProvider.notifier).select(model.engine),
          ),
      ],
    );
  }

  String _subtitle(SttModelStatus status) {
    return switch (status.phase) {
      SttModelPhase.ready => 'Works without a connection.',
      SttModelPhase.downloading ||
      SttModelPhase.verifying ||
      SttModelPhase.extracting => 'Downloading the model...',
      SttModelPhase.failed => 'Download failed. See Offline models.',
      SttModelPhase.notDownloaded => 'Download the model in Offline models.',
    };
  }
}

class _EngineTile extends StatelessWidget {
  const _EngineTile({
    required this.engine,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final SttEngineKind engine;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('sttEngine_${engine.id}'),
      leading: Icon(Icons.offline_bolt),
      title: Text(title),
      subtitle: SettingsDescription(subtitle),
      selected: selected,
      enabled: enabled,
      trailing: selected
          ? Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
      onTap: enabled ? onTap : null,
    );
  }
}
