import 'package:flutter/material.dart';

/// Color of dictionary words the user is still learning (SPEC 5.4):
/// a light pastel orange that stands out on the dark theme.
const Color learningWordColor = Color(0xFFFFCC99);

ThemeData buildParleyTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF7C9CF5),
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF0F1115),
  );
}
