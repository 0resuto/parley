import 'package:flutter/foundation.dart';

import 'package:parley/core/constants.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/tutor/notes_updater.dart';

/// Schedules background notes updates (PLAN 7.4, SPEC 5.6).
///
/// Triggers:
/// - after each assistant reply when global unprocessed user messages ≥ 8,
/// - on app lifecycle pause (always runs; [NotesUpdater] no-ops when empty),
/// - when the user leaves a conversation or starts a new one, only when
///   global unprocessed user messages ≥ 2.
///
/// Each run calls [NotesUpdater.updateOnce] up to [notesMaxCallsPerRun]
/// times (40 messages per call) and stops on the first `false`. Runs are
/// serialized with a mutex: a second [run] while one is in progress returns
/// immediately. Offline runs are skipped. Failures are caught and logged
/// with `debugPrint`, never shown and never thrown.
class TutorScheduler {
  TutorScheduler({
    required ChatRepository chats,
    required NotesUpdater notes,
    required ConnectivityService connectivity,
  }) : _chats = chats,
       _notes = notes,
       _connectivity = connectivity;

  final ChatRepository _chats;
  final NotesUpdater _notes;
  final ConnectivityService _connectivity;

  bool _running = false;

  /// True while a [run] is in progress (exposed for tests).
  bool get isRunning => _running;

  /// Runs up to [notesMaxCallsPerRun] updater chunks. Never throws.
  Future<void> run() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      bool online = false;
      try {
        online = await _connectivity.isOnline();
      } catch (_) {
        online = false;
      }
      if (!online) {
        return;
      }
      for (int i = 0; i < notesMaxCallsPerRun; i++) {
        bool wrote = false;
        try {
          wrote = await _notes.updateOnce();
        } catch (e) {
          debugPrint('tutor scheduler failed: $e');
          break;
        }
        if (!wrote) {
          break;
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Checked after each assistant reply (SPEC 5.6). Never throws.
  Future<void> onAssistantReplyDone() async {
    try {
      final int count = await _chats.unprocessedUserCount();
      if (count < notesUnprocessedThreshold) {
        return;
      }
      await run();
    } catch (e) {
      debugPrint('tutor scheduler after-reply failed: $e');
    }
  }

  /// Called when the app goes to the background (SPEC 5.6). Never throws.
  Future<void> onAppPaused() async {
    try {
      await run();
    } catch (e) {
      debugPrint('tutor scheduler pause failed: $e');
    }
  }

  /// Called when the user leaves a conversation (SPEC 5.6). Never throws.
  Future<void> onConversationLeft() async {
    try {
      final int count = await _chats.unprocessedUserCount();
      if (count < notesUnprocessedThresholdOnLeave) {
        return;
      }
      await run();
    } catch (e) {
      debugPrint('tutor scheduler leave failed: $e');
    }
  }

  /// Called when the user starts a new conversation (SPEC 5.6). Never throws.
  Future<void> onNewConversation() async {
    try {
      final int count = await _chats.unprocessedUserCount();
      if (count < notesUnprocessedThresholdOnLeave) {
        return;
      }
      await run();
    } catch (e) {
      debugPrint('tutor scheduler new-chat failed: $e');
    }
  }
}
