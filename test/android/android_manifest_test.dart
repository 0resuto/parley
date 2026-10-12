import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String manifest;
  late String rules;

  String stripComments(String xml) {
    return xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  }

  setUpAll(() {
    manifest = stripComments(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    rules = stripComments(
      File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsStringSync(),
    );
  });

  String section(String name) {
    final int start = rules.indexOf('<$name>');
    final int end = rules.indexOf('</$name>');
    expect(start, isNonNegative, reason: 'missing <$name> section');
    expect(end, greaterThan(start), reason: 'missing </$name> section');
    return rules.substring(start, end);
  }

  group('Android manifest', () {
    test('release builds declare the INTERNET permission', () {
      expect(manifest, contains('android.permission.INTERNET'));
    });

    test('auto backup is disabled and the extraction rules are wired', () {
      expect(manifest, contains('android:allowBackup="false"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
    });

    test('the system TTS service is visible to flutter_tts (Android 11+)', () {
      final int queriesStart = manifest.indexOf('<queries>');
      final int queriesEnd = manifest.indexOf('</queries>');
      expect(queriesStart, isNonNegative);
      expect(queriesEnd, greaterThan(queriesStart));
      expect(
        manifest.substring(queriesStart, queriesEnd),
        contains('android.intent.action.TTS_SERVICE'),
      );
    });

    test('secure storage prefs are excluded from backup and transfer', () {
      for (final String part in [
        section('cloud-backup'),
        section('device-transfer'),
      ]) {
        expect('<exclude'.allMatches(part).length, 2);
        expect(part, contains('domain="sharedpref"'));
        expect(part, contains('path="FlutterSecureStorage.xml"'));
        expect(part, contains('path="FlutterSecureKeyStorage.xml"'));
      }
    });
  });
}
