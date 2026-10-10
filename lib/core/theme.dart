import 'package:flutter/material.dart';

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
