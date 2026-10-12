import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:parley/services/documents/document_store.dart';
import 'settings_providers.dart';

/// Shared Rules / Notes viewer and editor (SPEC 5.10).
///
/// View shows the current text, Edit opens a plain multiline field with a
/// `used / limit` counter (Save disabled over the limit), History lists
/// previous versions with a timestamp, preview and Restore.
class DocumentScreen extends ConsumerStatefulWidget {
  const DocumentScreen({super.key, required this.kind});

  final DocumentKind kind;

  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  final TextEditingController _editController = TextEditingController();
  String _text = '';
  String _editBase = '';
  List<DocumentVersion> _versions = [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _editing = false;
  bool _saving = false;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _editController.addListener(_onEditChanged);
    _load();
  }

  @override
  void dispose() {
    _editController.removeListener(_onEditChanged);
    _editController.dispose();
    super.dispose();
  }

  void _onEditChanged() {
    if (_editing && mounted) {
      setState(() {});
    }
  }

  String get _title {
    switch (widget.kind) {
      case DocumentKind.rules:
        return 'Rules';
      case DocumentKind.notes:
        return 'Notes';
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final DocumentStore store = ref.read(documentStoreProvider);
      final String text = await store.read(widget.kind);
      final List<DocumentVersion> versions = await store.versions(widget.kind);
      if (!mounted) {
        return;
      }
      setState(() {
        _text = text;
        _versions = versions;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _startEdit() {
    _editController.text = _text;
    _editBase = _text;
    setState(() {
      _editing = true;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
    });
  }

  Future<void> _save() async {
    final DocumentStore store = ref.read(documentStoreProvider);
    final int limit = store.limitFor(widget.kind);
    final String next = _editController.text;
    if (next.length > limit || _saving) {
      return;
    }
    setState(() {
      _saving = true;
    });
    try {
      final String latest = await store.read(widget.kind);
      if (latest != _editBase) {
        // The notes updater (or a restore) changed the document while the
        // editor was open; let an explicit second Save overwrite it (A-26).
        _editBase = latest;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('The document changed. Save again to overwrite.'),
            ),
          );
        }
        return;
      }
      await store.write(widget.kind, next);
      if (!mounted) {
        return;
      }
      setState(() {
        _editing = false;
      });
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not save.')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _restore(String versionId) async {
    if (_restoring) {
      return;
    }
    setState(() {
      _restoring = true;
    });
    try {
      await ref.read(documentStoreProvider).restore(widget.kind, versionId);
      if (!mounted) {
        return;
      }
      setState(() {
        _editing = false;
      });
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not restore.')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _restoring = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final int limit = ref.watch(documentStoreProvider).limitFor(widget.kind);
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Something went wrong.'),
                  const SizedBox(height: 8),
                  ElevatedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_editing) ...[
                  TextField(
                    key: const Key('documentEditField'),
                    controller: _editController,
                    minLines: 8,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Counter(used: _editController.text.length, limit: limit),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            key: const Key('documentSaveButton'),
                            onPressed:
                                _editController.text.length > limit || _saving
                                ? null
                                : _save,
                            child: _saving
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Save'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            onPressed: _saving ? null : _cancelEdit,
                            child: const Text('Cancel'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  if (_text.isEmpty)
                    const Text('No content yet.')
                  else
                    Text(_text, key: const Key('documentViewText')),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      key: const Key('documentEditButton'),
                      onPressed: _startEdit,
                      child: const Text('Edit'),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text('History', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_versions.isEmpty)
                  const Text('No previous versions.')
                else
                  ..._versions.map(
                    (DocumentVersion version) => Card(
                      child: ListTile(
                        title: Text(_formatDate(version.createdAt)),
                        subtitle: version.preview.isEmpty
                            ? const Text('(empty)')
                            : Text(version.preview),
                        trailing: TextButton(
                          onPressed: _restoring
                              ? null
                              : () => _restore(version.id),
                          child: const Text('Restore'),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.used, required this.limit});

  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final bool over = used > limit;
    return Text(
      '$used / $limit',
      style: TextStyle(
        color: over ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

String _formatDate(DateTime value) {
  return DateFormat.yMMMd().add_jm().format(value.toLocal());
}
