import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/theme.dart';

void main() {
  test('input fields share the rounded filled style', () {
    final ThemeData theme = buildParleyTheme();
    final InputDecorationThemeData input = theme.inputDecorationTheme;

    expect(input.filled, isTrue);
    expect(input.fillColor, theme.colorScheme.surfaceContainerHigh);
    expect(input.border, isA<OutlineInputBorder>());
    final OutlineInputBorder border = input.border! as OutlineInputBorder;
    expect(border.borderRadius, BorderRadius.circular(18));
    expect(border.borderSide, BorderSide.none);
  });
}
