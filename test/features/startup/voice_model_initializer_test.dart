import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/features/startup/voice_model_initializer.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model_manager.dart';

class FakeInitializerModelsController extends SttModelsController {
  FakeInitializerModelsController({required this.gate});

  final Completer<void> gate;
  bool ensured = false;

  @override
  SttModelsState build() {
    return const SttModelsState(<SttEngineKind, SttModelStatus>{
      SttEngineKind.moonshine: SttModelStatus(),
      SttEngineKind.whisper: SttModelStatus(),
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sttModelsControllerProvider.overrideWith(() => controller)],
        child: const MaterialApp(
          home: VoiceModelInitializer(child: Text('app')),
        ),
      ),
    );
    await tester.pump();

    expect(controller.ensured, isTrue);
    expect(find.text('app'), findsOneWidget);

    gate.complete();
    await tester.pump();
    expect(find.text('app'), findsOneWidget);
  });
}
