import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/stt/stt_service.dart';

void main() {
  test('failures expose user-visible messages', () {
    expect(
      const SttPermissionFailure().userMessage,
      contains('Microphone permission'),
    );
    expect(const SttNoSpeechFailure().userMessage, contains('No speech'));
    expect(
      const SttModelMissingFailure('Whisper Tiny.en').userMessage,
      contains('Whisper Tiny.en'),
    );
    expect(
      const SttModelLoadFailure('Moonshine Tiny').userMessage,
      contains('Moonshine Tiny'),
    );
    expect(
      const SttUnknownFailure().userMessage,
      contains('Voice input failed'),
    );
  });
}
