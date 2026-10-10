import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_providers.dart';

/// Voice settings (SPEC 5.10): auto-play replies and speech speed.
class VoiceSection extends ConsumerStatefulWidget {
  const VoiceSection({super.key});

  @override
  ConsumerState<VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends ConsumerState<VoiceSection> {
  late bool _autoPlay;
  late double _speed;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsRepositoryProvider);
    _autoPlay = settings.autoPlay;
    _speed = settings.speechSpeed;
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
      ],
    );
  }
}
