import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/stt_engine_section.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/services/settings/stt_settings.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model_manager.dart';

class FakeSttModelsController extends SttModelsController {
  FakeSttModelsController(this.initial);

  final SttModelsState initial;

  @override
  SttModelsState build() => initial;
}

SttModelsState stateWith({SttModelStatus? moonshine, SttModelStatus? whisper}) {
  return SttModelsState(<SttEngineKind, SttModelStatus>{
    SttEngineKind.moonshine: moonshine ?? const SttModelStatus(),
    SttEngineKind.whisper:
        whisper ??
        const SttModelStatus(phase: SttModelPhase.ready, progress: 1),
  });
}

void main() {
  late MemorySttSettings settings;

  setUp(() {
    settings = MemorySttSettings();
  });

  Future<void> pumpSection(WidgetTester tester, SttModelsState models) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sttSettingsProvider.overrideWithValue(settings),
          sttModelsControllerProvider.overrideWith(
            () => FakeSttModelsController(models),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SttEngineSection())),
      ),
    );
    await tester.pumpAndSettle();
  }

  ListTile tile(WidgetTester tester, SttEngineKind engine) {
    return tester.widget<ListTile>(find.byKey(Key('sttEngine_${engine.id}')));
  }

  testWidgets('Whisper is selected and Moonshine is locked until ready', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester, stateWith());

    expect(tile(tester, SttEngineKind.whisper).selected, isTrue);
    expect(tile(tester, SttEngineKind.whisper).enabled, isTrue);
    expect(tile(tester, SttEngineKind.moonshine).enabled, isFalse);
    expect(find.text('Download the model in Offline models.'), findsOneWidget);
    expect(find.text('Works without a connection.'), findsOneWidget);
  });

  testWidgets('a ready Moonshine model can be selected', (
    WidgetTester tester,
  ) async {
    await pumpSection(
      tester,
      stateWith(
        moonshine: const SttModelStatus(
          phase: SttModelPhase.ready,
          progress: 1,
        ),
      ),
    );

    expect(tile(tester, SttEngineKind.moonshine).enabled, isTrue);
    await tester.tap(find.byKey(const Key('sttEngine_moonshine')));
    await tester.pumpAndSettle();

    expect(settings.engine, SttEngineKind.moonshine);
    expect(tile(tester, SttEngineKind.moonshine).selected, isTrue);
    expect(tile(tester, SttEngineKind.whisper).selected, isFalse);
  });

  testWidgets('Whisper can be selected again after Moonshine', (
    WidgetTester tester,
  ) async {
    settings = MemorySttSettings(engine: SttEngineKind.moonshine);
    await pumpSection(tester, stateWith());

    expect(tile(tester, SttEngineKind.whisper).enabled, isTrue);
    await tester.tap(find.byKey(const Key('sttEngine_whisper')));
    await tester.pumpAndSettle();

    expect(settings.engine, SttEngineKind.whisper);
    expect(tile(tester, SttEngineKind.whisper).selected, isTrue);
    expect(tile(tester, SttEngineKind.moonshine).selected, isFalse);
  });

  testWidgets('a downloading model shows progress and stays disabled', (
    WidgetTester tester,
  ) async {
    await pumpSection(
      tester,
      stateWith(
        moonshine: const SttModelStatus(
          phase: SttModelPhase.downloading,
          progress: 0.4,
        ),
      ),
    );

    expect(tile(tester, SttEngineKind.moonshine).enabled, isFalse);
    expect(find.text('Downloading the model...'), findsOneWidget);
  });
}
