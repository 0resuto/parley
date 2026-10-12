import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';

/// Conversation history list per SPEC 5.3 (PLAN 6.7).
///
/// Shows conversations sorted by `updated_at` (newest first, via
/// [ChatRepository.listConversations]). Tapping a row pops the screen with
/// the conversation id so the chat can open it. `New chat` creates an empty
/// conversation: it pops with the new id when opened as a picker, otherwise
/// it refreshes the list. Deleting (swipe or trash icon) asks for
/// confirmation first. Holds no business logic.
class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});

  @override
  ConsumerState<ConversationsScreen> createState() =>
      _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  bool _loading = true;
  String? _error;
  List<Conversation> _conversations = const [];

  /// Bumped on every reload: a row restored after a failed swipe-delete
  /// gets fresh Dismissible keys, because a dismissed Dismissible may not
  /// stay in the tree with the same key (A-30).
  int _listRevision = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<Conversation> all = await ref
          .read(chatRepositoryProvider)
          .listConversations();
      if (!mounted) {
        return;
      }
      setState(() {
        _listRevision++;
        _conversations = all;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Something went wrong.';
      });
    }
  }

  Future<void> _newChat() async {
    try {
      final Conversation created = await ref
          .read(chatRepositoryProvider)
          .createConversation();
      if (!mounted) {
        return;
      }
      if (Navigator.canPop(context)) {
        Navigator.of(context).pop(created.id);
      } else {
        await _load();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not create a chat.')));
    }
  }

  void _open(Conversation conversation) {
    Navigator.of(context).pop(conversation.id);
  }

  Future<bool> _confirmDelete(Conversation conversation) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete conversation?'),
          content: Text(
            'Delete "${conversation.title}"? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('confirmDeleteButton'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _remove(Conversation conversation) async {
    try {
      await ref
          .read(chatRepositoryProvider)
          .deleteConversation(conversation.id);
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete the conversation.')),
      );
      // A swipe already removed the row from the tree; reload so the
      // still-existing conversation reappears (A-30).
      await _load();
      return;
    }
    await _load();
  }

  Future<void> _delete(Conversation conversation) async {
    final bool confirmed = await _confirmDelete(conversation);
    if (!confirmed || !mounted) {
      return;
    }
    await _remove(conversation);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          TextButton(
            key: const Key('newChatButton'),
            onPressed: _newChat,
            child: const Text('New chat'),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Something went wrong.'),
            const SizedBox(height: 8),
            ElevatedButton(
              key: const Key('conversationsRetryButton'),
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_conversations.isEmpty) {
      return const Center(child: Text('No conversations yet.'));
    }
    return ListView.builder(
      itemCount: _conversations.length,
      itemBuilder: (BuildContext context, int index) {
        final Conversation conversation = _conversations[index];
        return Dismissible(
          key: ValueKey(
            'conversationDismissible_${conversation.id}_$_listRevision',
          ),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.errorContainer,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: const Icon(Icons.delete_outline),
          ),
          confirmDismiss: (_) => _confirmDelete(conversation),
          onDismissed: (_) => _remove(conversation),
          child: ListTile(
            key: ValueKey('conversationTile_${conversation.id}'),
            title: Text(conversation.title),
            subtitle: Text(
              DateFormat.yMMMd().add_jm().format(
                conversation.updatedAt.toLocal(),
              ),
            ),
            onTap: () => _open(conversation),
            trailing: IconButton(
              key: ValueKey('deleteConversation_${conversation.id}'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () => _delete(conversation),
            ),
          ),
        );
      },
    );
  }
}
