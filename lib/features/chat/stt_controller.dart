import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/stt/stt_providers.dart';
import 'package:parley/services/stt/stt_service.dart';
import 'package:parley/services/tts/tts_service.dart';

/// Voice-input phase shown by the composer.
enum SttPhase { idle, listening, processing }

/// Level (0..1) at which a chunk counts as speech.
///
/// The level is normalized over -50..0 dBFS, so 0.25 is about -37 dBFS:
/// clearly above typical room noise, below normal speech.
const double sttSpeechLevel = 0.25;

/// Pause after speech that stops the recording.
const Duration sttSilenceTimeout = Duration(milliseconds: 1800);

/// State of the voice-input controller.
class SttState {
  const SttState({
    this.phase = SttPhase.idle,
    this.partial = '',
    this.finalText = '',
    this.failure,
    this.resultSequence = 0,
    this.failureSequence = 0,
  });

  /// Idle, recording, or waiting for the final result.
  final SttPhase phase;

  /// Latest partial text, empty before the first result.
  final String partial;

  /// Last final text.
  final String finalText;

  /// Last failure, if any.
  final SttFailure? failure;

  /// Increments once per final result; the UI uses it to apply text once.
  final int resultSequence;

  /// Increments once per failure; the UI uses it to show one snackbar.
  final int failureSequence;

  bool get isListening => phase == SttPhase.listening;

  bool get isProcessing => phase == SttPhase.processing;

  SttState copyWith({
    SttPhase? phase,
    String? partial,
    String? finalText,
    SttFailure? failure,
    bool clearFailure = false,
    int? resultSequence,
    int? failureSequence,
  }) {
    return SttState(
      phase: phase ?? this.phase,
      partial: partial ?? this.partial,
      finalText: finalText ?? this.finalText,
      failure: clearFailure ? null : failure ?? this.failure,
      resultSequence: resultSequence ?? this.resultSequence,
      failureSequence: failureSequence ?? this.failureSequence,
    );
  }
}

/// Controls voice input for the chat composer (SPEC 5.8).
///
/// Stops TTS before opening the microphone so the tutor's voice is not
/// recognized as user speech. The controller only manages recognition state;
/// the screen decides where the text goes.
class SttController extends Notifier<SttState> {
  StreamSubscription<SttEvent>? _subscription;
  Timer? _silenceTimer;
  bool _speechHeard = false;

  @override
  SttState build() {
    final SttService service = ref.read(sttServiceProvider);
    _subscription = service.events.listen(_onEvent);
    ref.onDispose(() {
      _cancelSilenceTimer();
      _subscription?.cancel();
      unawaited(service.cancel());
    });
    return const SttState();
  }

  /// Starts listening unless a session is already running.
  Future<void> start() async {
    if (state.phase != SttPhase.idle) {
      return;
    }
    _cancelSilenceTimer();
    _speechHeard = false;
    final SttService service = ref.read(sttServiceProvider);
    // Show the busy indicator while the engine initializes or loads its model;
    // SttStarted moves the phase to listening.
    state = const SttState(phase: SttPhase.processing);
    try {
      await ref.read(ttsServiceProvider).stop();
    } catch (_) {
      // TTS is best-effort; voice input still works.
    }
    try {
      final bool available = await service.initialize();
      if (!ref.mounted) {
        return;
      }
      if (!available) {
        _fail(const SttUnavailableFailure());
        return;
      }
      await service.start();
    } on SttFailure catch (failure) {
      _fail(failure);
    } catch (_) {
      _fail(const SttUnknownFailure());
    }
  }

  /// Stops recording and waits for the final result.
  Future<void> stop() async {
    _cancelSilenceTimer();
    if (state.phase != SttPhase.listening) {
      return;
    }
    state = state.copyWith(phase: SttPhase.processing);
    try {
      await ref.read(sttServiceProvider).stop();
    } catch (_) {
      _fail(const SttUnknownFailure());
    }
  }

  /// Cancels recording and discards the current result.
  Future<void> cancel() async {
    _cancelSilenceTimer();
    state = const SttState();
    try {
      await ref.read(sttServiceProvider).cancel();
    } catch (_) {
      // Cancelling is best-effort.
    }
  }

  /// Starts when idle, stops when listening.
  Future<void> toggle() async {
    if (state.phase == SttPhase.listening) {
      await stop();
    } else if (state.phase == SttPhase.idle) {
      await start();
    }
  }

  void _onEvent(SttEvent event) {
    switch (event) {
      case SttStarted():
        _speechHeard = false;
        _cancelSilenceTimer();
        if (state.phase != SttPhase.listening) {
          state = state.copyWith(phase: SttPhase.listening);
        }
      case SttPartial(:final String text):
        _speechHeard = true;
        _cancelSilenceTimer();
        state = state.copyWith(phase: SttPhase.listening, partial: text);
      case SttLevel(:final double level):
        _onLevel(level);
      case SttAudioSpectrum():
        // Audio data drives the spectrum and level providers, not the state.
        break;
      case SttFinalResult(:final String text):
        _cancelSilenceTimer();
        state = state.copyWith(
          phase: SttPhase.processing,
          partial: text,
          finalText: text,
          resultSequence: state.resultSequence + 1,
          clearFailure: true,
        );
      case SttStopped():
        _cancelSilenceTimer();
        state = state.copyWith(phase: SttPhase.idle);
      case SttFailed(:final SttFailure failure):
        _cancelSilenceTimer();
        _fail(failure);
    }
  }

  /// Tracks pauses so a recording can end without a second mic tap.
  ///
  /// Silence before the first speech is ignored: the user may need a moment
  /// after tapping the mic. Only a pause after audible speech starts the
  /// timer.
  void _onLevel(double level) {
    if (state.phase != SttPhase.listening) {
      return;
    }
    if (level >= sttSpeechLevel) {
      _speechHeard = true;
      _cancelSilenceTimer();
      return;
    }
    if (!_speechHeard ||
        _silenceTimer != null ||
        !ref.read(sttSettingsProvider).autoStop) {
      return;
    }
    _silenceTimer = Timer(ref.read(sttSilenceTimeoutProvider), () {
      _silenceTimer = null;
      if (ref.mounted && state.phase == SttPhase.listening) {
        unawaited(stop());
      }
    });
  }

  void _cancelSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  void _fail(SttFailure failure) {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      phase: SttPhase.idle,
      failure: failure,
      failureSequence: state.failureSequence + 1,
    );
  }
}

/// Voice-input controller for the chat composer.
final sttControllerProvider = NotifierProvider<SttController, SttState>(
  SttController.new,
);

/// How long a pause may last before the recording stops on its own.
///
/// A provider so tests can shorten the wait.
final sttSilenceTimeoutProvider = Provider<Duration>((ref) {
  return sttSilenceTimeout;
});

/// Live frequency bands for the composer spectrum.
final sttSpectrumProvider = StreamProvider<List<double>>((ref) {
  return ref
      .watch(sttServiceProvider)
      .events
      .where((SttEvent event) => event is SttAudioSpectrum)
      .map((SttEvent event) => (event as SttAudioSpectrum).bands);
});

/// Latest normalized microphone level, used by the recording mic button.
final sttLevelProvider = StreamProvider<double>((ref) {
  return ref
      .watch(sttServiceProvider)
      .events
      .where((SttEvent event) => event is SttLevel)
      .map((SttEvent event) => (event as SttLevel).level);
});
