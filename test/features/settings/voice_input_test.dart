import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/voice_section.dart';
import 'package:parley/services/settings/stt_settings.dart';

void main() {
  late MemorySttSettings sttSettings;

  setUp(() {
    sttSettings = MemorySttSettings();
  });

  Future<void> pumpVoice(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sttSettingsProvider.overrideWithValue(sttSettings)],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: VoiceSection())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('voice input switches reflect and update settings', (
    WidgetTester tester,
  ) async {
    await pumpVoice(tester);

    await tester.ensureVisible(find.byKey(const Key('sttAutoSendSwitch')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('sttAutoSendSwitch')))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('sttAutoStopSwitch')))
          .value,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('sttAutoSendSwitch')));
    await tester.pumpAndSettle();
    expect(sttSettings.autoSend, isTrue);

    await tester.ensureVisible(find.byKey(const Key('sttAutoStopSwitch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sttAutoStopSwitch')));
    await tester.pumpAndSettle();
    expect(sttSettings.autoStop, isFalse);
  });
}
