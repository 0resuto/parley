import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/constants.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/chat/rules_tool.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/llm/llm_client.dart';
import 'package:parley/services/llm/prompt_builder.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/tutor/notes_updater.dart';
import 'package:parley/services/tutor/tutor_scheduler.dart';
import 'package:parley/services/tutor/word_judge.dart';

/// Network connectivity for the chat controller.
///
/// Tests override this with a fake; production uses `connectivity_plus`.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityPlusService();
});

/// Builds the chat system prompt from live app state (SPEC 6.2).
final promptBuilderProvider = Provider<PromptBuilder>((ref) {
  return PromptBuilder(
    settings: ref.watch(settingsRepositoryProvider),
    documents: ref.watch(documentStoreProvider),
    units: ref.watch(unitRepositoryProvider),
    clock: ref.watch(clockProvider),
  );
});

/// Hook called after an assistant reply is persisted (PLAN 6.3).
///
/// Runs the word judge (7.1) and the notes scheduler threshold check (7.4).
/// Takes the conversation id so background jobs know which conversation
/// finished. Failures are caught inside the jobs and only logged.
typedef ChatReplyHook = Future<void> Function(int conversationId);

/// Background notes updater built from live app state (PLAN 7.3).
final notesUpdaterProvider = Provider<NotesUpdater>((ref) {
  return NotesUpdater(
    chats: ref.read(chatRepositoryProvider),
    documents: ref.read(documentStoreProvider),
    llm: ref.read(llmClientProvider),
    clock: ref.read(clockProvider),
    connectivity: ref.read(connectivityServiceProvider),
    settings: ref.read(settingsRepositoryProvider),
  );
});

/// Background tutor scheduler (PLAN 7.4, SPEC 5.6).
final tutorSchedulerProvider = Provider<TutorScheduler>((ref) {
  return TutorScheduler(
    chats: ref.read(chatRepositoryProvider),
    notes: ref.read(notesUpdaterProvider),
    connectivity: ref.read(connectivityServiceProvider),
  );
});

/// Default hook runs the word judge (7.1) and the scheduler check (7.4).
final chatReplyHookProvider = Provider<ChatReplyHook>((ref) {
  return (int conversationId) async {
    final AppDatabase db = ref.read(appDatabaseProvider);
    final WordJudge judge = WordJudge(
      db: db,
      chats: ref.read(chatRepositoryProvider),
      units: ref.read(unitRepositoryProvider),
      llm: ref.read(llmClientProvider),
      connectivity: ref.read(connectivityServiceProvider),
      settings: ref.read(settingsRepositoryProvider),
      reviews: ReviewService(
        db,
        units: ref.read(unitRepositoryProvider),
        clock: ref.read(clockProvider),
      ),
      clock: ref.read(clockProvider),
    );
    await judge.judgeConversation(conversationId);
    await ref.read(tutorSchedulerProvider).onAssistantReplyDone();
  };
});

/// Chat state for one conversation (PLAN 6.3, SPEC 5.3).
class ChatState {
  const ChatState({
    required this.messages,
    required this.isStreaming,
    required this.streamingText,
    required this.error,
    required this.draft,
    required this.isLoading,
  });

  const ChatState.initial()
    : messages = const [],
      isStreaming = false,
      streamingText = '',
      error = null,
      draft = '',
      isLoading = true;

  /// All stored messages, oldest first (includes `event` chips).
  final List<ChatMessage> messages;

  /// True while an assistant reply is streaming.
  final bool isStreaming;

  /// Accumulated streamed text not yet persisted.
  final String streamingText;

  /// Last failure shown in the error banner (null when none).
  final AppFailure? error;

  /// Typed text preserved when send fails early (offline / not configured).
  final String draft;

  /// True before the first [ChatController.refresh] finishes.
  final bool isLoading;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isStreaming,
    String? streamingText,
    AppFailure? error,
    bool clearError = false,
    String? draft,
    bool? isLoading,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      streamingText: streamingText ?? this.streamingText,
      error: clearError ? null : (error ?? this.error),
      draft: draft ?? this.draft,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// One streamed LLM round: final text plus any tool calls.
class _RoundOutcome {
  const _RoundOutcome({this.text = '', this.tools = const [], this.failure})
    : stopped = false;

  const _RoundOutcome.stopped()
    : text = '',
      tools = const [],
      failure = null,
      stopped = true;

  final String text;
  final List<ToolCallRequest> tools;
  final AppFailure? failure;
  final bool stopped;
}

/// Riverpod controller for one conversation (PLAN 6.3, SPEC 5.3).
///
/// Flow: not configured -> [NotConfiguredFailure]; offline ->
/// [OfflineFailure] (typed text kept in [ChatState.draft]); otherwise the
/// user message is persisted, the reply is streamed, and the assistant
/// message is persisted on completion or on [stop] when non-empty. A
/// mid-stream error discards the partial text and exposes the failure.
/// [retry] regenerates the reply to the last user message. Chat requests
/// include the `update_rules` tool (PLAN 6.8, SPEC 6.4, 5.7).
class ChatController extends Notifier<ChatState> {
  ChatController(this.conversationId);

  /// Conversation this controller drives.
  final int conversationId;

  StreamSubscription<LlmEvent>? _sub;
  String _buffer = '';
  Completer<void>? _completer;
  bool _stopped = false;

  @override
  ChatState build() {
    ref.onDispose(() async {
      await _sub?.cancel();
      _sub = null;
    });
    return const ChatState.initial();
  }

  /// Loads stored messages (call once after creation).
  Future<void> refresh() async {
    final ChatRepository chats = ref.read(chatRepositoryProvider);
    try {
      final List<ChatMessage> messages = await chats.listMessages(
        conversationId,
      );
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(messages: messages, isLoading: false);
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(isLoading: false, error: const ServerFailure());
    }
  }

  /// Sends [text] as a new user message and streams the reply.
  Future<void> send(String text) async {
    if (state.isStreaming) {
      return;
    }
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (!await _checkReady(text)) {
      return;
    }
    final ChatRepository chats = ref.read(chatRepositoryProvider);
    try {
      await chats.addMessage(
        conversationId: conversationId,
        role: ChatRole.user,
        content: trimmed,
      );
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: const ServerFailure());
      return;
    }
    if (!ref.mounted) {
      return;
    }
    final List<ChatMessage> messages = await chats.listMessages(conversationId);
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      messages: messages,
      isLoading: false,
      isStreaming: true,
      streamingText: '',
      clearError: true,
      draft: '',
    );
    final List<LlmMessage>? request = await _buildRequest();
    if (request == null) {
      return;
    }
    await _runStream(request);
  }

  /// Stops streaming; keeps the partial text when non-empty.
  Future<void> stop() async {
    if (!state.isStreaming) {
      return;
    }
    _stopped = true;
    final StreamSubscription<LlmEvent>? sub = _sub;
    _sub = null;
    if (sub != null) {
      // Cancel in the background without awaiting: awaiting stream
      // teardown can stall (it hangs under widget-test FakeAsync),
      // which would freeze the Stop button. Later events are already
      // ignored via [_stopped] and `_sub = null`.
      unawaited(sub.cancel().then<void>((_) {}, onError: (_) {}));
    }
    final String partial = _buffer;
    _buffer = '';
    if (partial.isEmpty) {
      if (ref.mounted) {
        state = state.copyWith(isStreaming: false, streamingText: '');
      }
      _complete();
      return;
    }
    try {
      final ChatRepository chats = ref.read(chatRepositoryProvider);
      await chats.addMessage(
        conversationId: conversationId,
        role: ChatRole.assistant,
        content: partial,
      );
      if (!ref.mounted) {
        _complete();
        return;
      }
      final List<ChatMessage> messages = await chats.listMessages(
        conversationId,
      );
      if (!ref.mounted) {
        _complete();
        return;
      }
      state = state.copyWith(
        messages: messages,
        isStreaming: false,
        streamingText: '',
        clearError: true,
      );
      // Fire-and-forget: the Stop button must not wait for the background
      // tutor jobs (A-36).
      unawaited(_notifyHook());
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(
          isStreaming: false,
          streamingText: '',
          error: const ServerFailure(),
        );
      }
    } finally {
      _complete();
    }
  }

  /// Regenerates the reply to the last user message.
  Future<void> retry() async {
    if (state.isStreaming) {
      return;
    }
    if (!await _checkReady(null)) {
      return;
    }
    final ChatRepository chats = ref.read(chatRepositoryProvider);
    late final List<ChatMessage> current;
    try {
      current = await chats.listMessages(conversationId);
    } catch (_) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: const ServerFailure());
      return;
    }
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(messages: current, isLoading: false);
    ChatMessage? lastUser;
    for (int i = current.length - 1; i >= 0; i--) {
      if (current[i].role == ChatRole.user) {
        lastUser = current[i];
        break;
      }
    }
    if (lastUser == null) {
      return;
    }
    state = state.copyWith(
      isStreaming: true,
      streamingText: '',
      clearError: true,
      draft: '',
    );
    final List<LlmMessage>? request = await _buildRequest();
    if (request == null) {
      return;
    }
    await _runStream(request);
  }

  /// Checks LLM configuration and connectivity before streaming.
  ///
  /// Returns false and exposes the failure when not ready. When [text] is
  /// non-null the typed text is preserved in [ChatState.draft] so the UI
  /// can keep it in the input (SPEC 5.3).
  Future<bool> _checkReady(String? text) async {
    bool configured = false;
    try {
      configured = await ref.read(settingsRepositoryProvider).isLlmConfigured();
    } catch (_) {
      configured = false;
    }
    if (!configured) {
      if (!ref.mounted) {
        return false;
      }
      state = state.copyWith(
        error: const NotConfiguredFailure(),
        draft: text ?? state.draft,
      );
      return false;
    }
    bool online = false;
    try {
      online = await ref.read(connectivityServiceProvider).isOnline();
    } catch (_) {
      online = false;
    }
    if (!online) {
      if (!ref.mounted) {
        return false;
      }
      state = state.copyWith(
        error: const OfflineFailure(),
        draft: text ?? state.draft,
      );
      return false;
    }
    return true;
  }

  /// Builds `[system, ...history]` for the LLM request.
  ///
  /// Returns null and exposes [ServerFailure] when the prompt cannot
  /// be built (the user message stays persisted for a later retry).
  Future<List<LlmMessage>?> _buildRequest() async {
    final ChatRepository chats = ref.read(chatRepositoryProvider);
    try {
      final LlmMessage system = await ref
          .read(promptBuilderProvider)
          .buildSystemMessage();
      final List<LlmMessage> history = await chats.historyForLlm(
        conversationId,
      );
      return [system, ...history];
    } catch (_) {
      if (!ref.mounted) {
        return null;
      }
      state = state.copyWith(
        isStreaming: false,
        streamingText: '',
        error: const ServerFailure(),
      );
      return null;
    }
  }

  /// Streams [request] and persists the assistant reply on completion.
  ///
  /// Chat requests include the `update_rules` tool (SPEC 6.4, 5.7). Up to
  /// [updateRulesMaxRounds] tool rounds run per user message; each round
  /// validates args, writes `rules.md` via [DocumentStore], appends an
  /// `event` message, sends the tool result back, and streams the model's
  /// final reply. Mid-stream errors discard the partial text.
  Future<void> _runStream(List<LlmMessage> request) async {
    // A streaming reply keeps the controller alive even if the screen is
    // closed meanwhile, so the reply is still persisted (A-31).
    final keepAlive = ref.keepAlive();
    try {
      await _runStreamBody(request);
    } finally {
      keepAlive.close();
    }
  }

  Future<void> _runStreamBody(List<LlmMessage> request) async {
    final LlmClient llm = ref.read(llmClientProvider);
    _buffer = '';
    _stopped = false;
    try {
      await _sub?.cancel();
    } catch (_) {
      // Ignore a stale cancellation.
    }
    _sub = null;

    List<LlmMessage> current = List<LlmMessage>.of(request);
    String finalText = '';
    for (int round = 0; round < updateRulesMaxRounds; round++) {
      final _RoundOutcome outcome = await _streamOnce(
        llm,
        current,
        withTools: true,
      );
      if (outcome.stopped || _stopped) {
        return;
      }
      if (outcome.failure != null) {
        return;
      }
      if (outcome.tools.isEmpty) {
        finalText = outcome.text;
        break;
      }
      final List<LlmToolCall> assistantCalls = [];
      final List<LlmMessage> toolResults = [];
      for (final ToolCallRequest call in outcome.tools) {
        assistantCalls.add(
          LlmToolCall(
            name: call.name,
            argumentsJson: call.argsJson,
            id: call.id.isEmpty ? null : call.id,
          ),
        );
        final String result = await _handleUpdateRules(call);
        if (_stopped) {
          return;
        }
        toolResults.add(
          LlmMessage(
            role: LlmRole.tool,
            content: result,
            toolCallId: call.id.isEmpty ? null : call.id,
          ),
        );
      }
      current = [
        ...current,
        LlmMessage(
          role: LlmRole.assistant,
          content: outcome.text,
          toolCalls: assistantCalls,
        ),
        ...toolResults,
      ];
      if (round == updateRulesMaxRounds - 1) {
        final _RoundOutcome last = await _streamOnce(
          llm,
          current,
          withTools: false,
        );
        if (last.stopped || _stopped) {
          return;
        }
        if (last.failure != null) {
          return;
        }
        finalText = last.text;
        break;
      }
    }

    if (_stopped || !ref.mounted) {
      return;
    }
    if (finalText.isEmpty) {
      state = state.copyWith(isStreaming: false, streamingText: '');
      return;
    }
    try {
      final ChatRepository chats = ref.read(chatRepositoryProvider);
      await chats.addMessage(
        conversationId: conversationId,
        role: ChatRole.assistant,
        content: finalText,
      );
      if (!ref.mounted) {
        return;
      }
      final List<ChatMessage> messages = await chats.listMessages(
        conversationId,
      );
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        messages: messages,
        isStreaming: false,
        streamingText: '',
        clearError: true,
      );
      // Fire-and-forget: auto-play must not wait for the background tutor
      // jobs (A-36).
      unawaited(_notifyHook());
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(
          isStreaming: false,
          streamingText: '',
          error: const ServerFailure(),
        );
      }
    }
  }

  /// Streams one LLM round, collecting text and `update_rules` calls.
  Future<_RoundOutcome> _streamOnce(
    LlmClient llm,
    List<LlmMessage> messages, {
    required bool withTools,
  }) async {
    if (_stopped) {
      return const _RoundOutcome.stopped();
    }
    _buffer = '';
    _completer = Completer<void>();
    try {
      await _sub?.cancel();
    } catch (_) {
      // Ignore a stale cancellation.
    }
    _sub = null;
    if (ref.mounted) {
      state = state.copyWith(streamingText: '');
    }
    final List<ToolCallRequest> tools = [];
    AppFailure? failure;
    Stream<LlmEvent> stream;
    try {
      stream = llm.streamChat(
        messages,
        tools: withTools ? [updateRulesTool] : null,
      );
    } catch (e) {
      if (!ref.mounted) {
        _complete();
        return _RoundOutcome(failure: const ServerFailure());
      }
      state = state.copyWith(
        isStreaming: false,
        streamingText: '',
        error: e is AppFailure ? e : const ServerFailure(),
      );
      _complete();
      return _RoundOutcome(
        failure: e is AppFailure ? e : const ServerFailure(),
      );
    }
    _sub = stream.listen(
      (LlmEvent event) {
        if (_stopped) {
          return;
        }
        if (event is TextDelta) {
          _buffer += event.text;
          if (ref.mounted) {
            state = state.copyWith(streamingText: _buffer);
          }
        } else if (event is ToolCallRequest) {
          tools.add(event);
        }
      },
      onError: (Object e, StackTrace _) {
        _sub = null;
        if (_stopped) {
          _complete();
          return;
        }
        failure = e is AppFailure ? e : const ServerFailure();
        if (ref.mounted) {
          state = state.copyWith(
            isStreaming: false,
            streamingText: '',
            error: failure,
          );
        }
        _complete();
      },
      onDone: () {
        _sub = null;
        _complete();
      },
      cancelOnError: true,
    );
    await _completer!.future;
    if (_stopped) {
      return const _RoundOutcome.stopped();
    }
    if (failure != null) {
      return _RoundOutcome(failure: failure);
    }
    return _RoundOutcome(text: _buffer, tools: tools);
  }

  /// Validates `update_rules` args, writes rules, appends the event chip.
  Future<String> _handleUpdateRules(ToolCallRequest call) async {
    if (call.name != updateRulesToolName) {
      return updateRulesUnknownToolResult;
    }
    final UpdateRulesArgs? args = tryParseUpdateRulesArgs(call.argsJson);
    if (args == null || args.content.trim().isEmpty) {
      return updateRulesEmptyResult;
    }
    final String content = args.content;
    final DocumentStore docs = ref.read(documentStoreProvider);
    final int limit = docs.limitFor(DocumentKind.rules);
    if (content.length > limit) {
      return updateRulesTooLongResult(content.length, limit);
    }
    try {
      await docs.write(DocumentKind.rules, content);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('update_rules write failed: $e');
      }
      return 'ERROR: could not save.';
    }
    String versionId = '';
    try {
      final versions = await docs.versions(DocumentKind.rules);
      if (versions.isNotEmpty) {
        versionId = versions.first.id;
      }
    } catch (_) {
      // Best effort; the event still records the change.
    }
    final String eventJson = buildRulesUpdatedEvent(
      summary: args.summary,
      versionId: versionId,
    );
    try {
      final ChatRepository chats = ref.read(chatRepositoryProvider);
      await chats.addMessage(
        conversationId: conversationId,
        role: ChatRole.event,
        content: eventJson,
      );
      if (ref.mounted) {
        final List<ChatMessage> messages = await chats.listMessages(
          conversationId,
        );
        if (ref.mounted) {
          state = state.copyWith(messages: messages);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('update_rules event failed: $e');
      }
    }
    return updateRulesOkResult;
  }

  /// Calls the post-reply hook; failures are logged, never shown.
  Future<void> _notifyHook() async {
    try {
      await ref.read(chatReplyHookProvider)(conversationId);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('onAssistantReplyDone failed: $e');
      }
    }
  }

  void _complete() {
    final Completer<void>? completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

/// Chat controller family, keyed by conversation id.
///
/// Auto-disposed: a controller (and its stream subscription) lives only
/// while its conversation is watched or a reply is streaming (A-31).
final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatState, int>(
      (int arg) => ChatController(arg),
      isAutoDispose: true,
    );
