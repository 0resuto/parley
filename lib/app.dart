import 'package:flutter/material.dart';

import 'package:parley/core/theme.dart';
import 'package:parley/features/shell/shell_screen.dart';
import 'package:parley/features/startup/voice_model_initializer.dart';

class ParleyApp extends StatelessWidget {
  const ParleyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parley',
      theme: buildParleyTheme(),
      home: const VoiceModelInitializer(child: ShellScreen()),
    );
  }
}
