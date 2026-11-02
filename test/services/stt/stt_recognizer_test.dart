import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_recognizer.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

void main() {
  test('Moonshine uses the v2 ORT files', () {
    final OfflineModelConfig config = buildOfflineModelConfig(
      SttEngineKind.moonshine,
      Directory('/models'),
    );

    expect(config.moonshine.encoder, endsWith('encoder_model.ort'));
    expect(
      config.moonshine.mergedDecoder,
      endsWith('decoder_model_merged.ort'),
    );
    expect(config.tokens, endsWith('tokens.txt'));
    expect(config.whisper.encoder, isEmpty);
  });

  test('Whisper uses the int8 files with English transcription', () {
    final OfflineModelConfig config = buildOfflineModelConfig(
      SttEngineKind.whisper,
      Directory('/models'),
    );

    expect(config.modelType, 'whisper');
    expect(config.whisper.encoder, endsWith('tiny.en-encoder.int8.onnx'));
    expect(config.whisper.decoder, endsWith('tiny.en-decoder.int8.onnx'));
    expect(config.whisper.language, 'en');
    expect(config.whisper.task, 'transcribe');
    expect(config.tokens, endsWith('tiny.en-tokens.txt'));
    expect(config.moonshine.encoder, isEmpty);
  });

  test('the system engine has no offline model config', () {
    expect(
      () => buildOfflineModelConfig(SttEngineKind.system, Directory('/models')),
      throwsUnsupportedError,
    );
  });
}
