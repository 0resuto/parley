import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_providers.dart';
import 'stt_engine_section.dart';
import 'stt_models_section.dart';

/// Voice settings (SPEC 5.10): auto-play replies, speech speed and voice input.
class VoiceSection extends ConsumerStatefulWidget {
  const VoiceSection({super.key});

  @override
  ConsumerState<VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends ConsumerState<VoiceSection> {
  late bool _autoPlay;
  late double _speed;
  late bool _autoSend;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsRepositoryProvider);
    final sttSettings = ref.read(sttSettingsProvider);
    _autoPlay = settings.autoPlay;
    _speed = settings.speechSpeed;
    _autoSend = sttSettings.autoSend;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Voice', style: Theme.of(context).textTheme.titleSmall),
        ),
        SwitchListTile(
          title: const Text('Auto-play replies'),
          value: _autoPlay,
          onChanged: (bool value) {
            setState(() {
              _autoPlay = value;
            });
            ref.read(settingsRepositoryProvider).setAutoPlay(value);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Speech speed: ${_speed.toStringAsFixed(1)}x'),
        ),
        Slider(
          key: const Key('speechSpeedSlider'),
          value: _speed,
          min: 0.5,
          max: 1.5,
          divisions: 10,
          label: '${_speed.toStringAsFixed(1)}x',
          onChanged: (double value) {
            setState(() {
              _speed = value;
            });
            ref.read(settingsRepositoryProvider).setSpeechSpeed(value);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Voice input',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        SwitchListTile(
          key: const Key('sttAutoSendSwitch'),
          title: const Text('Send after recognition'),
          subtitle: const Text(
            'Send the recognized message immediately instead of inserting it.',
          ),
          value: _autoSend,
          onChanged: (bool value) {
            setState(() {
              _autoSend = value;
            });
            ref.read(sttSettingsProvider).setAutoSend(value);
          },
        ),
        const SttEngineSection(),
        const SttModelsSection(),
      ],
    );
  }
}
