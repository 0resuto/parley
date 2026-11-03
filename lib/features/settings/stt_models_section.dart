import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model.dart';
import 'package:parley/services/stt/stt_model_manager.dart';
import 'stt_engine_controller.dart';
import 'stt_models_controller.dart';
import 'settings_section.dart';

/// Offline speech-model selection and downloads (SPEC 5.10).
class SttModelsSection extends ConsumerWidget {
  const SttModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SttModelsState state = ref.watch(sttModelsControllerProvider);
    final SttEngineKind selected = ref.watch(sttEngineProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Recognition model',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: SettingsDescription(
            'Whisper Tiny.en is required and downloads automatically on first '
            'launch. Moonshine is optional and faster.',
          ),
        ),
        const SizedBox(height: 4),
        RadioGroup<SttEngineKind>(
          groupValue: selected,
          onChanged: (SttEngineKind? engine) {
            if (engine == null || !state.statusOf(engine).isReady) {
              return;
            }
            ref.read(sttEngineProvider.notifier).select(engine);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final SttModel model in sttModels)
                _ModelCard(
                  model: model,
                  status: state.statusOf(model.engine),
                  selectedEngine: selected,
                  anotherBusy:
                      state.isBusy && !state.statusOf(model.engine).isBusy,
                  onSelect: () =>
                      ref.read(sttEngineProvider.notifier).select(model.engine),
                  onDownload: () => _download(context, ref, model),
                  onCancel: () =>
                      ref.read(sttModelsControllerProvider.notifier).cancel(),
                  onDelete: () => _delete(context, ref, model),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    SttModel model,
  ) async {
    bool? confirmed = true;
    if (!model.required) {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Download model?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${model.name} (${model.sizeLabel})'),
                const SizedBox(height: 8),
                const Text(
                  'The model is downloaded from GitHub and stays on this device. '
                  'Use Wi-Fi for large downloads.',
                ),
              ],
            ),
            actions: [
              TextButton(
                key: const Key('sttDownloadCancelButton'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const Key('sttDownloadConfirmButton'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Download'),
              ),
            ],
          );
        },
      );
    }
    if (confirmed != true || !context.mounted) {
      return;
    }
    try {
      await ref
          .read(sttModelsControllerProvider.notifier)
          .download(model.engine);
    } on SttModelException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.userMessage)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not download the model.')),
        );
      }
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SttModel model,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete model?'),
          content: Text(
            '${model.name} will be removed from this device. '
            'You can download it again later.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('sttDeleteConfirmButton'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    await ref.read(sttModelsControllerProvider.notifier).delete(model.engine);
    if (ref.read(sttEngineProvider) == model.engine) {
      await ref.read(sttEngineProvider.notifier).select(SttEngineKind.whisper);
    }
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.status,
    required this.selectedEngine,
    required this.anotherBusy,
    required this.onSelect,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
  });

  final SttModel model;
  final SttModelStatus status;
  final SttEngineKind selectedEngine;
  final bool anotherBusy;
  final VoidCallback onSelect;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String id = model.engine.id;
    final bool ready = status.isReady;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            key: Key('sttEngine_$id'),
            leading: Radio<SttEngineKind>(value: model.engine, enabled: ready),
            title: Text(model.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsDescription(
                  '${model.sizeLabel} · ${model.description}',
                ),
                if (status.phase == SttModelPhase.ready)
                  Text(
                    model.required ? 'Required' : 'Downloaded',
                    key: Key('sttModelStatus_$id'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.primary),
                  ),
              ],
            ),
            trailing: _action(context, id),
            selected: selectedEngine == model.engine,
            enabled: ready,
            onTap: ready ? onSelect : null,
          ),
          if (status.phase == SttModelPhase.downloading) _downloadProgress(id),
          if (status.phase == SttModelPhase.verifying ||
              status.phase == SttModelPhase.extracting)
            _preparing(),
          if (status.phase == SttModelPhase.failed) _failure(context, id),
        ],
      ),
    );
  }

  Widget _downloadProgress(String id) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: [
          LinearProgressIndicator(
            key: Key('sttModelProgress_$id'),
            value: status.progress,
          ),
          Row(
            children: [
              Text('${(status.progress * 100).round()}%'),
              const Spacer(),
              if (!model.required)
                TextButton(
                  key: Key('sttCancel_$id'),
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _preparing() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            status.phase == SttModelPhase.verifying
                ? 'Checking the download...'
                : 'Unpacking the model...',
          ),
        ],
      ),
    );
  }

  Widget _failure(BuildContext context, String id) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        status.error ?? 'The model download failed.',
        key: Key('sttModelError_$id'),
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  Widget _action(BuildContext context, String id) {
    if (model.required) {
      if (status.phase == SttModelPhase.failed) {
        return TextButton(
          key: Key('sttRetry_$id'),
          onPressed: anotherBusy ? null : onDownload,
          child: const Text('Retry'),
        );
      }
      return const SizedBox.shrink();
    }
    return switch (status.phase) {
      SttModelPhase.notDownloaded => TextButton(
        key: Key('sttDownload_$id'),
        onPressed: anotherBusy ? null : onDownload,
        child: const Text('Download'),
      ),
      SttModelPhase.downloading => const SizedBox.shrink(),
      SttModelPhase.verifying ||
      SttModelPhase.extracting => const SizedBox.shrink(),
      SttModelPhase.ready => IconButton(
        key: Key('sttDelete_$id'),
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete',
        onPressed: onDelete,
      ),
      SttModelPhase.failed => TextButton(
        key: Key('sttRetry_$id'),
        onPressed: anotherBusy ? null : onDownload,
        child: const Text('Retry'),
      ),
    };
  }
}
