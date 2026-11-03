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
      builder: (BuildContext context, Widget? child) {
        return Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(gradient: parleyBackgroundGradient),
            ),
            Positioned(
              top: -160,
              right: -120,
              child: IgnorePointer(
                child: SizedBox(
                  width: 420,
                  height: 420,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[Color(0x147C9CF5), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ?child,
          ],
        );
      },
      home: const VoiceModelInitializer(child: ShellScreen()),
    );
  }
}
