import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/features/settings/stt_models_controller.dart';

/// Starts the mandatory voice-model download in the background.
///
/// The app stays usable; the composer hides its microphone until the model
/// is ready. Settings shows the download progress and a Retry on failure.
class VoiceModelInitializer extends ConsumerStatefulWidget {
  const VoiceModelInitializer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VoiceModelInitializer> createState() =>
      _VoiceModelInitializerState();
}

class _VoiceModelInitializerState extends ConsumerState<VoiceModelInitializer> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => unawaited(
        ref.read(sttModelsControllerProvider.notifier).ensureRequired(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the controller (and its download) alive for the whole app session
    // without rebuilding the tree on every progress tick.
    ref.watch(sttModelsControllerProvider.notifier);
    return widget.child;
  }
}
