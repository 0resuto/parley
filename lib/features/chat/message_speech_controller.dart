import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/tts/tts_service.dart';

/// Playback state for chat assistant messages (SPEC 5.8, PLAN 8.2).
class MessageSpeechState {
  const MessageSpeechState({this.playingId});

  /// The assistant message currently playing, null when idle.
  final int? playingId;

  bool get isPlaying => playingId != null;
}

/// Controls Play/Stop for assistant messages (SPEC 5.8, PLAN 8.2).
///
/// One playback at a time: starting another message speaks the new text
/// ([TtsService.speak] stops the current engine playback first) and moves
/// [MessageSpeechState.playingId]. The controller also follows
/// [TtsService.isSpeaking]: when the engine reports it stopped on its own
/// (completion, cancel or error), the state returns to idle so the button
/// shows Play again. Text cleaning and the speech rate live in [TtsService],
/// so this controller passes the raw message text through.
/// Failures are best-effort and never surface in the UI: visible text never
/// changes because of audio.
class MessageSpeechController extends Notifier<MessageSpeechState> {
  /// True while [play] waits for the engine to start the utterance.
  bool _starting = false;

  @override
  MessageSpeechState build() {
    final StreamSubscription<bool> subscription = ref
        .read(ttsServiceProvider)
        .isSpeaking
        .listen(_onSpeakingChanged);
    ref.onDispose(subscription.cancel);
    return const MessageSpeechState();
  }

  void _onSpeakingChanged(bool speaking) {
    // A false outside play() means playback ended by itself; a false emitted
    // while starting is the tail of the previous utterance and is ignored.
    if (speaking || _starting || state.playingId == null) {
      return;
    }
    state = const MessageSpeechState();
  }

  /// Speaks [rawText] as message [id], replacing any current playback.
  Future<void> play(int id, String rawText) async {
    if (cleanTtsText(rawText).trim().isEmpty) {
      return;
    }
    _starting = true;
    try {
      await ref.read(ttsServiceProvider).speak(rawText);
    } catch (_) {
      // Speak is best-effort; a failure leaves the button on Play.
      _starting = false;
      state = const MessageSpeechState();
      return;
    }
    _starting = false;
    if (!ref.mounted) {
      return;
    }
    state = MessageSpeechState(playingId: id);
  }

  /// Stops playback and returns to the idle Play state.
  Future<void> stop() async {
    try {
      await ref.read(ttsServiceProvider).stop();
    } catch (_) {
      // Best-effort; the button still returns to Play.
    }
    if (!ref.mounted) {
      return;
    }
    state = const MessageSpeechState();
  }

  /// Toggles message [id]: stops when it is playing, plays otherwise.
  Future<void> toggle(int id, String rawText) async {
    if (state.playingId == id) {
      await stop();
    } else {
      await play(id, rawText);
    }
  }

  /// Plays [rawText] when the auto-play setting is on (SPEC 5.8, 5.10).
  ///
  /// Called once after a completed assistant reply. Empty text never plays.
  Future<void> maybeAutoPlay(int id, String rawText) async {
    bool autoPlay = false;
    try {
      autoPlay = ref.read(settingsRepositoryProvider).autoPlay;
    } catch (_) {
      autoPlay = false;
    }
    if (!autoPlay) {
      return;
    }
    await play(id, rawText);
  }
}

/// Playback state for the open conversation.
final messageSpeechProvider =
    NotifierProvider<MessageSpeechController, MessageSpeechState>(
      MessageSpeechController.new,
    );
