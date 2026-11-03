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

  test('cards, dialogs, sheets and chips share the radius scale', () {
    final ThemeData theme = buildParleyTheme();

    final RoundedRectangleBorder card =
        theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(card.borderRadius, BorderRadius.circular(20));

    final RoundedRectangleBorder dialog =
        theme.dialogTheme.shape! as RoundedRectangleBorder;
    expect(dialog.borderRadius, BorderRadius.circular(24));

    final RoundedRectangleBorder sheet =
        theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
    expect(
      sheet.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(24)),
    );

    expect(theme.chipTheme.shape, isA<StadiumBorder>());
  });

  test('button themes share height and shape', () {
    final ThemeData theme = buildParleyTheme();
    const Set<WidgetState> states = <WidgetState>{};

    expect(
      theme.filledButtonTheme.style?.minimumSize?.resolve(states),
      const Size(0, 48),
    );
    expect(
      theme.outlinedButtonTheme.style?.minimumSize?.resolve(states),
      const Size(0, 48),
    );
    expect(
      theme.textButtonTheme.style?.minimumSize?.resolve(states),
      const Size(0, 44),
    );

    final RoundedRectangleBorder filled =
        theme.filledButtonTheme.style!.shape!.resolve(states)!
            as RoundedRectangleBorder;
    expect(filled.borderRadius, BorderRadius.circular(16));
  });
}
