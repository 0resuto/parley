import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/features/startup/voice_model_initializer.dart';
import 'package:parley/services/stt/stt_providers.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model_manager.dart';

import '../../helpers/fake_stt_service.dart';

class FakeInitializerModelsController extends SttModelsController {
  FakeInitializerModelsController({required this.gate, this.ready = false});

  final Completer<void> gate;
  final bool ready;
  bool ensured = false;

  @override
  SttModelsState build() {
    return SttModelsState(<SttEngineKind, SttModelStatus>{
      SttEngineKind.moonshine: const SttModelStatus(),
      SttEngineKind.whisper: ready
          ? const SttModelStatus(phase: SttModelPhase.ready, progress: 1)
          : const SttModelStatus(),
    });
  }

  @override
  Future<void> ensureRequired() async {
    ensured = true;
    await gate.future;
  }
}

void main() {
  testWidgets('starts the download without blocking the app', (
    WidgetTester tester,
  ) async {
    final Completer<void> gate = Completer<void>();
    final FakeInitializerModelsController controller =
        FakeInitializerModelsController(gate: gate);
    final FakeSttService stt = FakeSttService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sttModelsControllerProvider.overrideWith(() => controller),
          sttServiceProvider.overrideWithValue(stt),
        ],
        child: const MaterialApp(
          home: VoiceModelInitializer(child: Text('app')),
        ),
      ),
    );
    await tester.pump();

    expect(controller.ensured, isTrue);
    expect(find.text('app'), findsOneWidget);
    expect(stt.calls, isEmpty);

    gate.complete();
    await tester.pump();
    expect(find.text('app'), findsOneWidget);
    expect(stt.calls, isEmpty);
  });

  testWidgets('loads the selected model once it is ready', (
    WidgetTester tester,
  ) async {
    final Completer<void> gate = Completer<void>()..complete();
    final FakeInitializerModelsController controller =
        FakeInitializerModelsController(gate: gate, ready: true);
    final FakeSttService stt = FakeSttService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sttModelsControllerProvider.overrideWith(() => controller),
          sttServiceProvider.overrideWithValue(stt),
        ],
        child: const MaterialApp(
          home: VoiceModelInitializer(child: Text('app')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(controller.ensured, isTrue);
    expect(stt.calls, contains('initialize'));
  });
}
