import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/failures.dart';
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/settings/document_screen.dart';
import 'package:parley/features/settings/settings_providers.dart';
import 'package:parley/features/settings/settings_screen.dart';
import 'package:parley/services/documents/document_store.dart';
import 'chat_controller.dart';
import 'conversations_screen.dart';
import 'message_speech_controller.dart';
import 'message_text.dart';
import 'rules_tool.dart';
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
  int? _conversationId;
  String _title = 'Chat';
  bool _starting = true;
  String? _loadError;
  final Set<int> _undoing = {};

  @override
  void initState() {
    super.initState();
    _input = TextEditingController();
    _scroll = ScrollController();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_start);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
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
      Conversation? chosen;
      final int? preset = widget.initialConversationId;
      if (preset != null) {
        chosen = await chats.getConversation(preset);
      }
      chosen ??= await _mostRecentOrNew(chats);
      if (!mounted) {
        return;
      }
      setState(() {
        _conversationId = chosen!.id;
        _title = chosen.title;
      });
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
      _scrollToBottom();
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
    _notifyNewConversation();
    try {
      final Conversation created = await ref
          .read(chatRepositoryProvider)
          .createConversation();
      if (!mounted) {
        return;
      }
      setState(() {
        _conversationId = created.id;
        _title = created.title;
      });
      _input.clear();
      await ref.read(chatControllerProvider(created.id).notifier).refresh();
      if (!mounted) {
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
    await controller.send(text);
    if (!mounted) {
      return;
    }
    final ChatState state = ref.read(chatControllerProvider(id));
    // Early failures (offline / not configured) keep the typed text in
    // [ChatState.draft]; success clears it, so clear the field only then.
    if (state.draft.isEmpty) {
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

  Future<void> _openHistory() async {
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
    _notifyConversationLeft();
    try {
      final Conversation? conversation = await ref
          .read(chatRepositoryProvider)
          .getConversation(id);
      if (!mounted) {
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
      _input.clear();
      await ref
          .read(chatControllerProvider(conversation.id).notifier)
          .refresh();
      if (!mounted) {
        return;
      }
      await _refreshTitle();
      if (!mounted) {
        return;
      }
      setState(() {});
      _scrollToBottom();
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
    try {
      final ChatRepository chats = ref.read(chatRepositoryProvider);
      final Conversation chosen = await _mostRecentOrNew(chats);
      if (!mounted) {
        return;
      }
      setState(() {
        _conversationId = chosen.id;
        _title = chosen.title;
      });
      _input.clear();
      await ref.read(chatControllerProvider(chosen.id).notifier).refresh();
      if (!mounted) {
        return;
      }
      await _refreshTitle();
      if (!mounted) {
        return;
      }
      setState(() {});
      _scrollToBottom();
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
    final Unit? unit = index.lookup(key) ?? index.lookupPhrase(key);
    showWordPopup(
      context: context,
      surface: surface,
      wordKey: key,
      sentence: sentence,
      initialUnit: unit,
    );
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) {
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
    final UnitIndex index = ref
        .watch(unitIndexProvider)
        .maybeWhen(data: (v) => v, orElse: UnitIndex.empty);

    return Scaffold(
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
          Expanded(child: _buildList(context, state, index)),
          if (state.error != null) _buildError(context, state),
          _buildComposer(state),
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
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      itemCount: messages.length + extra,
      itemBuilder: (BuildContext context, int indexBuilder) {
        if (indexBuilder >= messages.length) {
          final String text = state.streamingText.isEmpty
              ? '...'
              : state.streamingText;
          return _streamingText(context, text);
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
    );
  }

  Widget _userBubble(BuildContext context, String content, UnitIndex index) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: MessageText(
          rawText: content,
          index: index,
          style: Theme.of(context).textTheme.bodyLarge,
          onWordTap: (surface, key, sentence) =>
              _openWordPopup(index, surface, key, sentence),
        ),
      ),
    );
  }

  Widget _streamingText(BuildContext context, String content) {
    final UnitIndex empty = UnitIndex.empty();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: MessageText(
        rawText: content,
        index: empty,
        style: Theme.of(context).textTheme.bodyLarge,
        onWordTap: (surface, key, sentence) =>
            _openWordPopup(empty, surface, key, sentence),
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

  Widget _buildComposer(ChatState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const Key('chatInput'),
              controller: _input,
              minLines: 1,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Type a message',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (state.isStreaming)
            IconButton(
              key: const Key('chatStopButton'),
              icon: const Icon(Icons.stop),
              tooltip: 'Stop',
              onPressed: _stop,
            )
          else
            IconButton(
              key: const Key('chatSendButton'),
              icon: const Icon(Icons.send),
              tooltip: 'Send',
              onPressed: _send,
            ),
        ],
      ),
    );
  }
}
