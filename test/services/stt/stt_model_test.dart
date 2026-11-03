import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model.dart';

void main() {
  test('the catalog has the two offline models', () {
    final SttModel moonshine = sttModelFor(SttEngineKind.moonshine);
    expect(moonshine.name, 'Moonshine Tiny');
    expect(moonshine.sizeLabel, '29 MB');
    expect(moonshine.sha256, hasLength(64));
    expect(moonshine.required, isFalse);

    final SttModel whisper = sttModelFor(SttEngineKind.whisper);
    expect(whisper.name, 'Whisper Tiny.en');
    expect(whisper.sizeLabel, '113 MB');
    expect(whisper.sha256, hasLength(64));
    expect(whisper.required, isTrue);
  });

  test('model URLs point at the sherpa-onnx release assets', () {
    for (final SttModel model in sttModels) {
      expect(
        model.url,
        startsWith(
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/',
        ),
      );
      expect(model.url, endsWith('.tar.bz2'));
      expect(model.files, isNotEmpty);
    }
  });
}
