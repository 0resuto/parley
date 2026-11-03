import 'package:flutter/material.dart';

/// Color of dictionary words the user is still learning (SPEC 5.4):
/// a light pastel orange that stands out on the dark theme.
const Color learningWordColor = Color(0xFFFFCC99);

/// Dark blue-gray bubble used for the user's own messages.
///
/// Kept darker than the action menu so overlays read as a higher layer.
const Color chatBubbleColor = Color(0xFF1F2531);

/// Soft diagonal backdrop used behind the whole app.
const LinearGradient parleyBackgroundGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: <Color>[
    Color(0xFF090B10),
    Color(0xFF0E121A),
    Color(0xFF141926),
    Color(0xFF0C0F16),
  ],
  stops: <double>[0, 0.35, 0.72, 1],
);

ThemeData buildParleyTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF7C9CF5),
    brightness: Brightness.dark,
  );
  final OutlineInputBorder fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(18),
    borderSide: BorderSide.none,
  );
  final OutlineInputBorder focusedFieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(18),
    borderSide: BorderSide(color: colorScheme.primary, width: 1.2),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    brightness: Brightness.dark,
    // The gradient lives behind the navigator in ParleyApp.
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: focusedFieldBorder,
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colorScheme.error, width: 1.2),
      ),
      hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
    ),
  );
}
