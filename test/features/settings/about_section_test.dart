import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/settings/about_section.dart';

void main() {
  test('app version matches pubspec.yaml (A-63)', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final String versionLine = pubspec
        .split('\n')
        .firstWhere((String line) => line.startsWith('version:'));
    // Ignore the +build suffix, compare only the semantic version part.
    final String pubspecVersion = versionLine
        .substring('version:'.length)
        .trim()
        .split('+')
        .first;

    expect(AboutSection.appVersion, pubspecVersion);
  });

  testWidgets('about section shows the app version (A-63)', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AboutSection())),
    );

    expect(find.text('Version ${AboutSection.appVersion}'), findsOneWidget);
  });
}
