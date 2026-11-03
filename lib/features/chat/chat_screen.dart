import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/failures.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/settings/document_screen.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_service.dart';
import 'chat_controller.dart';
import 'chat_session_store.dart';
import 'conversations_screen.dart';
import 'message_speech_controller.dart';
import 'message_text.dart';
import 'rules_tool.dart';
import 'stt_controller.dart';
import 'stt_mic_button.dart';
import 'stt_spectrum.dart';
import 'tokenizer.dart';
import 'word_popup.dart';

/// Chat screen per SPEC 5.3 and 7 (PLAN 6.4).
///
/// Message list (newest at bottom), multiline composer with Send / Stop,
/// error banner with Retry or Settings, streaming text as plain [Text].
/// Assistant messages are full-width text; user messages are right-aligned
/// tonal bubbles. Holds no business logic: all sends go through
/// [ChatController].
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, this.initialConversationId});

  /// Preselects a conversation (used by tests and, later, history).
  /// When null the most recent conversation is opened, or a new one
  /// is created when none exists.
  final int? initialConversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _input;
  late final ScrollController _scroll;
  late final FocusNode _inputFocus;
  bool _keyboardVisible = false;
  bool _stickToBottom = true;
  double? _lastListHeight;
  int? _conversationId;
  String _title = 'Chat';
  bool _starting = true;
  String? _loadError;
  final Set<int> _undoing = {};

  /// Composer text as it was when the current dictation started; partial and
  /// final results replace only the dictated part.
  String _sttInputBase = '';

  /// Whether the composer has something to send; drives the Send button.
  bool _canSend = false;

  /// Keeps the current conversation's controller alive while the screen
  /// switches between conversations (the controller is auto-disposed,
  /// A-31). Closed on switch and in [dispose].
  ProviderSubscription<ChatState>? _chatSubscription;

  /// Monotonic token: only the newest conversation switch or creation may
  /// apply its result, so a slower earlier one cannot win (A-35).
  int _switchToken = 0;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController()..addListener(_onInputChanged);
    _scroll = ScrollController();
    _inputFocus = FocusNode();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_start);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelStt();
    _chatSubscription?.close();
    _input.removeListener(_onInputChanged);
    _inputFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    final bool canSend = _input.text.trim().isNotEmpty;
    if (canSend != _canSend && mounted) {
      setState(() {
        _canSend = canSend;
      });
    }
  }

  /// Drops keyboard focus from the composer.
  void _dismissKeyboard() {
    if (_inputFocus.hasFocus) {
      _inputFocus.unfocus();
    }
  }

  /// Stops voice input without waiting for a final result.
  void _cancelStt() {
    try {
      unawaited(ref.read(sttControllerProvider.notifier).cancel());
    } catch (_) {
      // The provider is already gone during app teardown.
    }
  }

  /// Drops composer focus when the system hides the keyboard.
  ///
  /// The Android back button hides the keyboard without moving focus away
  /// from the field. The field then regains primary focus when a route or
  /// a bottom sheet closes, which reopens the keyboard (for example after
  /// adding a word from the chat).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_keyboardVisible && !visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _inputFocus.hasFocus) {
          _inputFocus.unfocus();
        }
      });
    }
    _keyboardVisible = visible;
  }

  /// Listens to the controller of [id] (and stops listening to the
  /// previous one), so `refresh` can run before the next frame watches it.
  void _watchConversation(int id) {
    _chatSubscription?.close();
    _chatSubscription = ref.listenManual(chatControllerProvider(id), (_, _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _cancelStt();
      // Best-effort background notes update (PLAN 7.4, SPEC 5.6).
      // Never blocks the UI; failures are only logged.
      unawaited(ref.read(tutorSchedulerProvider).onAppPaused());
    }
  }

  /// Best-effort scheduler trigger when leaving a conversation (7.4).
  void _notifyConversationLeft() {
    try {
      unawaited(ref.read(tutorSchedulerProvider).onConversationLeft());
    } catch (_) {
      // Scheduler never throws; UI must never break.
    }
  }

  /// Best-effort scheduler trigger when starting a new chat (7.4).
  void _notifyNewConversation() {
    try {
      unawaited(ref.read(tutorSchedulerProvider).onNewConversation());
    } catch (_) {
      // Scheduler never throws; UI must never break.
    }
  }

  Future<void> _start() async {
    if (mounted) {
      setState(() {
        _starting = true;
        _loadError = null;
      });
    }
    try {
      final ChatRepository chats = ref.read(chatRepositoryProvider);
      final ChatSessionStore session = ref.read(chatSessionStoreProvider);
      Conversation? chosen;
      final int? preset = widget.initialConversationId;
      if (preset != null) {
        chosen = await chats.getConversation(preset);
      }
      chosen ??= await _lastOpened(chats, session);
      chosen ??= await _mostRecentOrNew(chats);
      if (!mounted) {
        return;
      }
      setState(() {
        _conversationId = chosen!.id;
        _title = chosen.title;
      });
      _stickToBottom = true;
      _lastListHeight = null;
      unawaited(_rememberConversation(chosen.id));
      _watchConversation(chosen.id);
      await ref.read(chatControllerProvider(chosen.id).notifier).refresh();
      if (!mounted) {
        return;
      }
      await _refreshTitle();
      if (!mounted) {
        return;
      }
      setState(() {
        _starting = false;
      });
      _scrollToBottom(jump: true);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _starting = false;
        _loadError = 'Something went wrong.';
      });
    }
  }

  Future<Conversation?> _lastOpened(
    ChatRepository chats,
    ChatSessionStore session,
  ) async {
    final int? id = session.lastConversationId;
    if (id == null) {
      return null;
    }
    try {
      return await chats.getConversation(id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberConversation(int id) async {
    try {
      await ref.read(chatSessionStoreProvider).setLastConversationId(id);
    } catch (_) {
      // Remembering the session is best-effort.
    }
  }

  Future<Conversation> _mostRecentOrNew(ChatRepository chats) async {
    final List<Conversation> all = await chats.listConversations();
    if (all.isEmpty) {
      return chats.createConversation();
    }
    return all.first;
  }

  Future<void> _refreshTitle() async {
    final int? id = _conversationId;
    if (id == null) {
      return;
    }
    try {
      final Conversation? current = await ref
          .read(chatRepositoryProvider)
          .getConversation(id);
      if (!mounted || current == null) {
        return;
      }
      if (current.title != _title) {
        setState(() {
          _title = current.title;
        });
      }
    } catch (_) {
      // Title refresh is best-effort; the list already shows messages.
    }
  }

  Future<void> _newChat() async {
    _dismissKeyboard();
    final int token = ++_switchToken;
    final int? currentId = _conversationId;
    if (currentId != null) {
      final ChatState current = ref.read(chatControllerProvider(currentId));
      // An empty conversation is already a new chat: keep it (and the
      // draft) instead of stacking duplicate empty rows in history
      // (PLAN 21.1). The token bump above still cancels an in-flight
      // slower switch.
      if (current.messages.isEmpty &&
          !current.isStreaming &&
          !current.isLoading) {
        return;
      }
    }
    _notifyNewConversation();
    _cancelStt();
    try {
      final Conversation created = await ref
          .read(chatRepositoryProvider)
          .createConversation();
      if (!mounted || token != _switchToken) {
        return;
      }
      setState(() {
        _conversationId = created.id;
        _title = created.title;
      });
      _stickToBottom = true;
      _lastListHeight = null;
      unawaited(_rememberConversation(created.id));
      _input.clear();
      _watchConversation(created.id);
      await ref.read(chatControllerProvider(created.id).notifier).refresh();
      if (!mounted || token != _switchToken) {
        return;
      }
      setState(() {});
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not create a chat.')));
    }
  }

  Future<void> _send() async {
    final int? id = _conversationId;
    if (id == null) {
      return;
    }
    _cancelStt();
    final String text = _input.text;
    if (text.trim().isEmpty) {
      return;
    }
    final ChatController controller = ref.read(
      chatControllerProvider(id).notifier,
    );
    if (ref.read(chatControllerProvider(id)).isStreaming) {
      return;
    }
    _stickToBottom = true;
    await controller.send(text);
    if (!mounted) {
      return;
    }
    final ChatState state = ref.read(chatControllerProvider(id));
    // Early failures (offline / not configured) keep the typed text in
    // [ChatState.draft]; success clears it. The field is cleared only when
    // it still holds the sent text in the same conversation, so a message
    // typed during the stream (or after switching chats) is not wiped
    // (A-32).
    if (state.draft.isEmpty && _conversationId == id && _input.text == text) {
      _input.clear();
    }
    await _refreshTitle();
    _scrollToBottom();
    await _maybeAutoPlay(id);
  }

  Future<void> _stop() async {
    final int? id = _conversationId;
    if (id == null) {
      return;
    }
    await ref.read(chatControllerProvider(id).notifier).stop();
    if (!mounted) {
      return;
    }
    await _refreshTitle();
    _scrollToBottom();
  }

  Future<void> _retry() async {
    final int? id = _conversationId;
    if (id == null) {
      return;
    }
    await ref.read(chatControllerProvider(id).notifier).retry();
    if (!mounted) {
      return;
    }
    await _refreshTitle();
    _scrollToBottom();
    await _maybeAutoPlay(id);
  }

  /// Toggles speech for one assistant message (PLAN 8.2, SPEC 5.8).
  ///
  /// Best-effort: TTS failures never break the chat UI.
  Future<void> _toggleSpeech(ChatMessage message) async {
    try {
      await ref
          .read(messageSpeechProvider.notifier)
          .toggle(message.id, message.content);
    } catch (_) {
      // Speak is best-effort; visible text never changes because of audio.
    }
  }

  /// Auto-plays the latest assistant reply when the setting is on (8.2).
  ///
  /// Called once after a completed send/retry. Stopped partials are not
  /// auto-played because [_stop] never calls this.
  Future<void> _maybeAutoPlay(int conversationId) async {
    try {
      final List<ChatMessage> messages = ref
          .read(chatControllerProvider(conversationId))
          .messages;
      if (messages.isEmpty) {
        return;
      }
      final ChatMessage last = messages.last;
      if (last.role != ChatRole.assistant) {
        return;
      }
      await ref
          .read(messageSpeechProvider.notifier)
          .maybeAutoPlay(last.id, last.content);
    } catch (_) {
      // Auto-play is best-effort.
    }
  }

  /// Starts or stops dictation (SPEC 5.8).
  Future<void> _toggleMic() async {
    final SttState stt = ref.read(sttControllerProvider);
    if (stt.phase == SttPhase.listening) {
      await ref.read(sttControllerProvider.notifier).stop();
      return;
    }
    if (stt.phase != SttPhase.idle) {
      return;
    }
    // Hide the keyboard: its clicks would otherwise be recorded.
    _inputFocus.unfocus();
    _sttInputBase = _input.text;
    await ref.read(sttControllerProvider.notifier).start();
  }

  /// Applies recognition updates and failures to the composer.
  void _onSttChanged(SttState? previous, SttState next) {
    if (next.failureSequence != (previous?.failureSequence ?? 0)) {
      final SttFailure? failure = next.failure;
      if (failure != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure.userMessage)));
      }
    }
    if (next.resultSequence != (previous?.resultSequence ?? 0)) {
      _applyDictation(next.finalText, finalResult: true);
      return;
    }
    if (next.phase == SttPhase.listening &&
        next.partial != (previous?.partial ?? '')) {
      _applyDictation(next.partial, finalResult: false);
    }
  }

  /// Replaces the dictated part of the composer, keeping text typed before
  /// the microphone was opened.
  void _applyDictation(String recognized, {required bool finalResult}) {
    if (recognized.trim().isEmpty) {
      return;
    }
    final String base = _sttInputBase;
    final String text;
    if (base.isEmpty) {
      text = recognized;
    } else if (base.endsWith(' ')) {
      text = '$base$recognized';
    } else {
      text = '$base $recognized';
    }
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (!finalResult) {
      return;
    }
    final int? id = _conversationId;
    if (id == null || !ref.read(sttSettingsProvider).autoSend) {
      return;
    }
    if (ref.read(chatControllerProvider(id)).isStreaming) {
      return;
    }
    unawaited(_send());
  }

  Future<void> _openHistory() async {
    _inputFocus.unfocus();
    final int? currentId = _conversationId;
    final int? selected = await Navigator.of(
      context,
    ).push<int>(MaterialPageRoute(builder: (_) => const ConversationsScreen()));
    if (!mounted) {
      return;
    }
    if (selected != null) {
      await _openConversation(selected);
      return;
    }
    if (currentId == null) {
      return;
    }
    // Returning without a pick: the current conversation may have been
    // deleted from history, so fall back to the most recent one.
    try {
      final Conversation? existing = await ref
          .read(chatRepositoryProvider)
          .getConversation(currentId);
      if (!mounted) {
        return;
      }
      if (existing == null) {
        await _openMostRecentOrNew();
      }
    } catch (_) {
      // Best-effort; the open chat stays as it is.
    }
  }

  Future<void> _openConversation(int id) async {
    final int token = ++_switchToken;
    _notifyConversationLeft();
    _cancelStt();
    try {
      final Conversation? conversation = await ref
          .read(chatRepositoryProvider)
          .getConversation(id);
      if (!mounted || token != _switchToken) {
        return;
      }
      if (conversation == null) {
        await _openMostRecentOrNew();
        return;
      }
      setState(() {
        _conversationId = conversation.id;
        _title = conversation.title;
      });
      _stickToBottom = true;
      _lastListHeight = null;
      unawaited(_rememberConversation(conversation.id));
      _input.clear();
      _watchConversation(conversation.id);
      await ref
          .read(chatControllerProvider(conversation.id).notifier)
          .refresh();
      if (!mounted || token != _switchToken) {
        return;
      }
      await _refreshTitle();
      if (!mounted || token != _switchToken) {
        return;
      }
      setState(() {});
      _scrollToBottom(jump: true);
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open the chat.')));
    }
  }

  Future<void> _openMostRecentOrNew() async {
    final int token = ++_switchToken;
    _cancelStt();
    try {
      final ChatRepository chats = ref.read(chatRepositoryProvider);
      final Conversation chosen = await _mostRecentOrNew(chats);
      if (!mounted || token != _switchToken) {
        return;
      }
      setState(() {
        _conversationId = chosen.id;
        _title = chosen.title;
      });
      _stickToBottom = true;
      _lastListHeight = null;
      unawaited(_rememberConversation(chosen.id));
      _input.clear();
      _watchConversation(chosen.id);
      await ref.read(chatControllerProvider(chosen.id).notifier).refresh();
      if (!mounted) {
        return;
      }
      await _refreshTitle();
      if (!mounted || token != _switchToken) {
        return;
      }
      setState(() {});
      _scrollToBottom(jump: true);
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open the chat.')));
    }
  }

  void _openSettings() {
    _inputFocus.unfocus();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  void _openWordPopup(
    UnitIndex index,
    String surface,
    String key,
    String sentence,
  ) {
    _inputFocus.unfocus();
    final Unit? unit = index.lookup(key) ?? index.lookupPhrase(key);
    showWordPopup(
      context: context,
      surface: surface,
      wordKey: key,
      sentence: sentence,
      initialUnit: unit,
    );
  }

  /// Keeps the bottom anchored when the list viewport changes (keyboard or
  /// composer height), but only if the user was already at the newest message.
  void _onListHeight(double height) {
    final double? previous = _lastListHeight;
    _lastListHeight = height;
    if (previous == null || (previous - height).abs() < 1) {
      return;
    }
    if (_stickToBottom) {
      _scrollToBottom(jump: true);
    }
  }

  /// Scrolls the list so the newest message stays visible.
  ///
  /// The callback is scheduled even when the controller has no clients
  /// yet: on the first build after opening a conversation the [ListView]
  /// is not attached until the next frame, so a synchronous
  /// [ScrollController.hasClients] check would silently skip the scroll
  /// and leave the list at its top.
  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      if (jump) {
        _jumpToBottom();
        return;
      }
      try {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } catch (_) {
        // List not laid out yet; the next build will show the bottom.
      }
    });
  }

  /// Jumps to the end, repeating while the lazy list refines its extent
  /// estimate as the last items are laid out.
  void _jumpToBottom([int attempts = 5, double previousMax = -1]) {
    if (!mounted || !_scroll.hasClients) {
      return;
    }
    final double max = _scroll.position.maxScrollExtent;
    _scroll.jumpTo(max);
    if (max != previousMax && attempts > 0) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _jumpToBottom(attempts - 1, max),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_starting || _conversationId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chat')),
        body: _loadError != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Something went wrong.'),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      key: const Key('chatLoadRetryButton'),
                      onPressed: _start,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }
    final int id = _conversationId!;
    final ChatState state = ref.watch(chatControllerProvider(id));
    final SttState sttState = ref.watch(sttControllerProvider);
    ref.listen<SttState>(sttControllerProvider, _onSttChanged);
    // Follow the growing streamed reply, so new text stays visible (A-33).
    ref.listen(chatControllerProvider(id), (
      ChatState? previous,
      ChatState next,
    ) {
      final int before = previous?.streamingText.length ?? 0;
      if (next.streamingText.length > before) {
        _scrollToBottom();
      }
    });
    final UnitIndex index = ref
        .watch(unitIndexProvider)
        .maybeWhen(data: (v) => v, orElse: UnitIndex.empty);

    return Scaffold(
      // The shell owns the keyboard inset for tab screens.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(_title),
        actions: [
          TextButton(
            key: const Key('chatNewChatButton'),
            onPressed: _newChat,
            child: const Text('New chat'),
          ),
          IconButton(
            key: const Key('chatHistoryButton'),
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _openHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                _onListHeight(constraints.maxHeight);
                return _buildList(context, state, index);
              },
            ),
          ),
          if (state.error != null) _buildError(context, state),
          _buildComposer(state, sttState),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, ChatState state, UnitIndex index) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<ChatMessage> messages = state.messages;
    final bool streaming = state.isStreaming;
    if (messages.isEmpty && !streaming) {
      return const Center(child: Text('No messages yet. Say hello!'));
    }
    final int extra = streaming ? 1 : 0;
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification is ScrollUpdateNotification &&
            notification.dragDetails != null) {
          _stickToBottom =
              notification.metrics.pixels >=
              notification.metrics.maxScrollExtent - 32;
        }
        return false;
      },
      child: ListView.builder(
        key: const Key('chatList'),
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        itemCount: messages.length + extra,
        itemBuilder: (BuildContext context, int indexBuilder) {
          if (indexBuilder >= messages.length) {
            final String text = state.streamingText.isEmpty
                ? '...'
                : state.streamingText;
            return _streamingText(context, text, index);
          }
          final ChatMessage message = messages[indexBuilder];
          switch (message.role) {
            case ChatRole.user:
              return _userBubble(context, message.content, index);
            case ChatRole.assistant:
              return _assistantText(context, message, index);
            case ChatRole.event:
              return _eventChip(context, message);
          }
        },
      ),
    );
  }

  Widget _userBubble(BuildContext context, String content, UnitIndex index) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: MessageText(
            rawText: content,
            index: index,
            style: Theme.of(context).textTheme.bodyLarge,
            onWordTap: (surface, key, sentence) =>
                _openWordPopup(index, surface, key, sentence),
          ),
        ),
      ),
    );
  }

  Widget _streamingText(BuildContext context, String content, UnitIndex index) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: MessageText(
        rawText: content,
        index: index,
        style: Theme.of(context).textTheme.bodyLarge,
        onWordTap: (surface, key, sentence) =>
            _openWordPopup(index, surface, key, sentence),
      ),
    );
  }

  Widget _assistantText(
    BuildContext context,
    ChatMessage message,
    UnitIndex index,
  ) {
    final MessageSpeechState speech = ref.watch(messageSpeechProvider);
    final bool isPlaying = speech.playingId == message.id;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: MessageText(
              rawText: message.content,
              index: index,
              style: Theme.of(context).textTheme.bodyLarge,
              onWordTap: (surface, key, sentence) =>
                  _openWordPopup(index, surface, key, sentence),
            ),
          ),
          IconButton(
            key: Key(
              isPlaying
                  ? 'assistantStopButton_${message.id}'
                  : 'assistantPlayButton_${message.id}',
            ),
            icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow),
            tooltip: isPlaying ? 'Stop' : 'Play',
            onPressed: () => _toggleSpeech(message),
          ),
        ],
      ),
    );
  }

  Widget _eventChip(BuildContext context, ChatMessage message) {
    final RulesUpdatedEvent? event = parseRulesUpdatedEvent(message.content);
    if (event == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Chip(
            label: Text(message.content),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    }
    final bool undoing = _undoing.contains(message.id);
    final String label = event.reverted ? 'Reverted' : 'Rules updated';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Chip(
              key: const Key('rulesUpdatedChip'),
              label: Text(label),
              visualDensity: VisualDensity.compact,
            ),
            if (!event.reverted && event.versionId.isNotEmpty)
              TextButton(
                key: const Key('rulesUndoButton'),
                onPressed: undoing ? null : () => _undoRules(message, event),
                child: undoing
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Undo'),
              ),
            TextButton(
              key: const Key('rulesViewButton'),
              onPressed: _viewRules,
              child: const Text('View'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _undoRules(ChatMessage message, RulesUpdatedEvent event) async {
    if (event.versionId.isEmpty || _undoing.contains(message.id)) {
      return;
    }
    setState(() {
      _undoing.add(message.id);
    });
    try {
      final DocumentStore docs = ref.read(documentStoreProvider);
      await docs.restore(DocumentKind.rules, event.versionId);
      final String reverted = buildRulesUpdatedEvent(
        summary: event.summary,
        versionId: event.versionId,
        reverted: true,
      );
      await ref
          .read(chatRepositoryProvider)
          .updateMessageContent(message.id, reverted);
      final int? id = _conversationId;
      if (id != null) {
        await ref.read(chatControllerProvider(id).notifier).refresh();
      }
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not restore.')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _undoing.remove(message.id);
        });
      } else {
        _undoing.remove(message.id);
      }
    }
  }

  void _viewRules() {
    _inputFocus.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const DocumentScreen(kind: DocumentKind.rules),
      ),
    );
  }

  Widget _buildError(BuildContext context, ChatState state) {
    final AppFailure error = state.error!;
    final bool needsSettings = error is NotConfiguredFailure;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        children: [
          Expanded(
            child: Text(
              error.userMessage,
              key: const Key('chatError'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          if (needsSettings)
            TextButton(
              key: const Key('chatSettingsButton'),
              onPressed: _openSettings,
              child: const Text('Settings'),
            )
          else
            TextButton(
              key: const Key('chatRetryButton'),
              onPressed: _retry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  Widget _buildComposer(ChatState state, SttState sttState) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool voiceReady = ref.watch(
      sttModelsControllerProvider.select(
        (SttModelsState state) => state.statusOf(SttEngineKind.whisper).isReady,
      ),
    );
    final bool showSpectrum = voiceReady && sttState.isListening;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSpectrum)
          const Padding(
            key: Key('chatListeningIndicator'),
            padding: EdgeInsets.fromLTRB(20, 8, 20, 2),
            child: SttSpectrum(),
          )
        else if (voiceReady && sttState.isProcessing)
          _sttStatus(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: sttState.isListening
                    ? colors.outline
                    : colors.outlineVariant,
                width: sttState.isListening ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('chatInput'),
                    controller: _input,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: 'Type a message',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.fromLTRB(16, 14, 6, 14),
                    ),
                  ),
                ),
                if (voiceReady)
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: sttState.isProcessing
                        ? const Center(
                            child: SizedBox(
                              key: Key('chatMicBusy'),
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Center(
                            child: SttMicButton(
                              isListening: sttState.isListening,
                              onPressed: _toggleMic,
                            ),
                          ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                  child: state.isStreaming
                      ? IconButton(
                          key: const Key('chatStopButton'),
                          icon: const Icon(Icons.stop),
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            backgroundColor: colors.secondaryContainer,
                            foregroundColor: colors.onSecondaryContainer,
                          ),
                          tooltip: 'Stop',
                          onPressed: _stop,
                        )
                      : IconButton(
                          key: const Key('chatSendButton'),
                          icon: const Icon(Icons.send),
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            backgroundColor: _canSend
                                ? colors.primary
                                : colors.surfaceContainerHighest,
                            foregroundColor: _canSend
                                ? colors.onPrimary
                                : colors.onSurfaceVariant,
                          ),
                          tooltip: 'Send',
                          onPressed: _send,
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sttStatus(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      child: Row(
        key: const Key('chatProcessingIndicator'),
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Processing...',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
