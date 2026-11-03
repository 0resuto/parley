/// Events emitted by an [SttService].
sealed class SttEvent {
  const SttEvent();
}

/// Recognition started and the microphone is live.
final class SttStarted extends SttEvent {
  const SttStarted();
}

/// Partial text, updated while the user speaks.
final class SttPartial extends SttEvent {
  const SttPartial(this.text);

  final String text;
}

/// Normalized microphone level (0..1) for the listening meter.
final class SttLevel extends SttEvent {
  const SttLevel(this.level);

  final double level;
}

/// Coarse frequency bands (0..1) for the live spectrum.
final class SttAudioSpectrum extends SttEvent {
  const SttAudioSpectrum(this.bands);

  final List<double> bands;
}

/// Final text for the current phrase.
final class SttFinalResult extends SttEvent {
  const SttFinalResult(this.text);

  final String text;
}

/// The recognizer stopped (final result already delivered, if any).
final class SttStopped extends SttEvent {
  const SttStopped();
}

/// Recognition failed; the message is user-visible.
final class SttFailed extends SttEvent {
  const SttFailed(this.failure);

  final SttFailure failure;
}

/// A voiced failure with a user-visible message.
sealed class SttFailure implements Exception {
  const SttFailure();

  /// Exact English text shown to the user.
  String get userMessage;
}

/// The microphone permission was denied.
final class SttPermissionFailure extends SttFailure {
  const SttPermissionFailure();

  @override
  String get userMessage =>
      'Microphone permission is required for voice input.';
}

/// The recognizer cannot start.
final class SttUnavailableFailure extends SttFailure {
  const SttUnavailableFailure();

  @override
  String get userMessage =>
      'Speech recognition isn\'t available. Check the microphone permission.';
}

/// Nothing was recognized.
final class SttNoSpeechFailure extends SttFailure {
  const SttNoSpeechFailure();

  @override
  String get userMessage => 'No speech detected. Try again.';
}

/// The selected offline model has not been downloaded yet.
final class SttModelMissingFailure extends SttFailure {
  const SttModelMissingFailure(this.modelName);

  final String modelName;

  @override
  String get userMessage =>
      'Download the $modelName model in Settings > Voice.';
}

/// The selected offline model could not be loaded.
final class SttModelLoadFailure extends SttFailure {
  const SttModelLoadFailure(this.modelName);

  final String modelName;

  @override
  String get userMessage =>
      'Could not load the $modelName model. Download it again in Settings.';
}

/// Any other recognizer failure.
final class SttUnknownFailure extends SttFailure {
  const SttUnknownFailure();

  @override
  String get userMessage => 'Voice input failed. Try again.';
}

/// Voice-input service backed by a local speech model.
abstract class SttService {
  /// Prepares the recognizer. Safe to call more than once.
  Future<bool> initialize();

  /// Starts dictating.
  Future<void> start();

  /// Stops listening; the final result is still delivered as an event.
  Future<void> stop();

  /// Stops listening without returning a final result.
  Future<void> cancel();

  /// Recognition events.
  Stream<SttEvent> get events;

  Future<void> dispose();
}
