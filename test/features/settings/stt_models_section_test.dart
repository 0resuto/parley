import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/features/settings/stt_models_section.dart';
import 'package:parley/services/settings/stt_settings.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model_manager.dart';

class FakeSttModelsController extends SttModelsController {
  FakeSttModelsController(this.initial, {this.downloadResult = true});

  final SttModelsState initial;
  final bool downloadResult;
  final List<SttEngineKind> downloads = [];
  final List<SttEngineKind> deletes = [];
  int cancels = 0;

  @override
  SttModelsState build() => initial;

  @override
  Future<bool> download(SttEngineKind engine) async {
    downloads.add(engine);
    if (downloadResult) {
      final Map<SttEngineKind, SttModelStatus> statuses =
          Map<SttEngineKind, SttModelStatus>.of(state.statuses);
      statuses[engine] = const SttModelStatus(
        phase: SttModelPhase.ready,
        progress: 1,
      );
      state = SttModelsState(statuses);
    }
    return downloadResult;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> delete(SttEngineKind engine) async {
    deletes.add(engine);
    final Map<SttEngineKind, SttModelStatus> statuses =
        Map<SttEngineKind, SttModelStatus>.of(state.statuses);
    statuses[engine] = const SttModelStatus();
    state = SttModelsState(statuses);
  }
}

void main() {
  SttModelsState emptyState() {
    return const SttModelsState(<SttEngineKind, SttModelStatus>{
      SttEngineKind.moonshine: SttModelStatus(),
      SttEngineKind.whisper: SttModelStatus(),
    });
  }

  Future<FakeSttModelsController> pumpSection(
    WidgetTester tester,
    SttModelsState initial, {
    bool downloadResult = true,
    MemorySttSettings? settings,
  }) async {
    final FakeSttModelsController controller = FakeSttModelsController(
      initial,
      downloadResult: downloadResult,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sttModelsControllerProvider.overrideWith(() => controller),
          if (settings != null) sttSettingsProvider.overrideWithValue(settings),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SttModelsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('download asks for confirmation and marks the model ready', (
    WidgetTester tester,
  ) async {
    final FakeSttModelsController controller = await pumpSection(
      tester,
      emptyState(),
    );

    await tester.tap(find.byKey(const Key('sttDownload_moonshine')));
    await tester.pumpAndSettle();
    expect(find.text('Download model?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sttDownloadCancelButton')));
    await tester.pumpAndSettle();
    expect(controller.downloads, isEmpty);

    await tester.tap(find.byKey(const Key('sttDownload_moonshine')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sttDownloadConfirmButton')));
    await tester.pumpAndSettle();

    expect(controller.downloads, [SttEngineKind.moonshine]);
    expect(find.byKey(const Key('sttModelStatus_moonshine')), findsOneWidget);
    expect(find.byKey(const Key('sttDelete_moonshine')), findsOneWidget);
  });

  testWidgets('a busy model shows progress and can be canceled', (
    WidgetTester tester,
  ) async {
    final SttModelsState state =
        const SttModelsState(<SttEngineKind, SttModelStatus>{
          SttEngineKind.moonshine: SttModelStatus(
            phase: SttModelPhase.downloading,
            progress: 0.5,
          ),
          SttEngineKind.whisper: SttModelStatus(),
        });
    final FakeSttModelsController controller = await pumpSection(tester, state);

    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('sttModelProgress_moonshine')),
          )
          .value,
      0.5,
    );
    expect(find.text('50%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sttCancel_moonshine')));
    await tester.pumpAndSettle();
    expect(controller.cancels, 1);
  });

  testWidgets('a downloaded model can be deleted', (WidgetTester tester) async {
    final SttModelsState state =
        const SttModelsState(<SttEngineKind, SttModelStatus>{
          SttEngineKind.moonshine: SttModelStatus(
            phase: SttModelPhase.ready,
            progress: 1,
          ),
          SttEngineKind.whisper: SttModelStatus(),
        });
    final FakeSttModelsController controller = await pumpSection(tester, state);

    await tester.tap(find.byKey(const Key('sttDelete_moonshine')));
    await tester.pumpAndSettle();
    expect(find.text('Delete model?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sttDeleteConfirmButton')));
    await tester.pumpAndSettle();

    expect(controller.deletes, [SttEngineKind.moonshine]);
    expect(find.byKey(const Key('sttDownload_moonshine')), findsOneWidget);
  });

  testWidgets('a failed model shows its error and a retry action', (
    WidgetTester tester,
  ) async {
    final SttModelsState state =
        const SttModelsState(<SttEngineKind, SttModelStatus>{
          SttEngineKind.moonshine: SttModelStatus(
            phase: SttModelPhase.failed,
            error: 'The model download is corrupted. Try again.',
          ),
          SttEngineKind.whisper: SttModelStatus(),
        });
    final FakeSttModelsController controller = await pumpSection(tester, state);

    expect(
      find.text('The model download is corrupted. Try again.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('sttRetry_moonshine')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sttDownloadConfirmButton')));
    await tester.pumpAndSettle();

    expect(controller.downloads, [SttEngineKind.moonshine]);
  });

  testWidgets('another download disables the second download button', (
    WidgetTester tester,
  ) async {
    final SttModelsState state =
        const SttModelsState(<SttEngineKind, SttModelStatus>{
          SttEngineKind.moonshine: SttModelStatus(
            phase: SttModelPhase.downloading,
            progress: 0.2,
          ),
          SttEngineKind.whisper: SttModelStatus(),
        });
    await pumpSection(tester, state);

    await tester.ensureVisible(find.byKey(const Key('sttDownload_whisper')));
    final TextButton button = tester.widget<TextButton>(
      find.byKey(const Key('sttDownload_whisper')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('deleting the selected offline model falls back to system', (
    WidgetTester tester,
  ) async {
    final MemorySttSettings settings = MemorySttSettings(
      engine: SttEngineKind.whisper,
    );
    const SttModelsState state = SttModelsState(<SttEngineKind, SttModelStatus>{
      SttEngineKind.moonshine: SttModelStatus(),
      SttEngineKind.whisper: SttModelStatus(
        phase: SttModelPhase.ready,
        progress: 1,
      ),
    });
    await pumpSection(tester, state, settings: settings);

    await tester.tap(find.byKey(const Key('sttDelete_whisper')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sttDeleteConfirmButton')));
    await tester.pumpAndSettle();

    expect(settings.engine, SttEngineKind.system);
  });
}
