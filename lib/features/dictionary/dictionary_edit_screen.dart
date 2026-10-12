import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'dictionary_providers.dart';

/// Shown when the word field is empty.
const String emptyWordError = 'Enter a word';

/// Shown when another unit already uses the word.
const String duplicateWordError = 'This word is already in the dictionary.';

/// Add / edit / detail screen for one dictionary unit (SPEC 5.1).
///
/// Add mode ([unitId] null) edits the word only (meanings resolve live).
/// Edit mode also shows dates, the description when present,
/// the "I already know this" switch and delete with confirmation.
class DictionaryEditScreen extends StatelessWidget {
  const DictionaryEditScreen({super.key, this.unitId});

  final int? unitId;

  @override
  Widget build(BuildContext context) {
    final int? id = unitId;
    if (id == null) {
      return const _AddScreen();
    }
    return _EditScreen(unitId: id);
  }
}

class _AddScreen extends ConsumerStatefulWidget {
  const _AddScreen();

  @override
  ConsumerState<_AddScreen> createState() => _AddScreenState();
}

class _AddScreenState extends ConsumerState<_AddScreen> {
  final TextEditingController _textController = TextEditingController();
  String? _textError;
  String? _formError;
  bool _saving = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _textError = emptyWordError;
      });
      return;
    }
    setState(() {
      _textError = null;
      _formError = null;
      _saving = true;
    });
    try {
      final UnitRepository repo = ref.read(unitRepositoryProvider);
      final Unit? existing = await repo.findByKey(text);
      if (existing != null) {
        if (mounted) {
          setState(() {
            _formError = duplicateWordError;
          });
        }
        return;
      }
      await repo.add(text: text);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _formError = _isDuplicate(e)
              ? duplicateWordError
              : 'Something went wrong.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add word')),
      body: _UnitFormBody(
        textController: _textController,
        textError: _textError,
        formError: _formError,
        saving: _saving,
        onSave: _save,
      ),
    );
  }
}

class _EditScreen extends ConsumerStatefulWidget {
  const _EditScreen({required this.unitId});

  final int unitId;

  @override
  ConsumerState<_EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends ConsumerState<_EditScreen> {
  final TextEditingController _textController = TextEditingController();
  Unit? _unit;
  bool _loading = true;
  bool _notFound = false;
  bool _loadFailed = false;
  String? _textError;
  String? _formError;
  bool _saving = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final Unit? unit = await ref
          .read(unitRepositoryProvider)
          .getById(widget.unitId);
      if (!mounted) {
        return;
      }
      if (unit == null) {
        setState(() {
          _loading = false;
          _notFound = true;
        });
        return;
      }
      _textController.text = unit.text;
      setState(() {
        _unit = unit;
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

  Future<void> _save() async {
    final Unit? unit = _unit;
    if (unit == null) {
      return;
    }
    final String text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _textError = emptyWordError;
      });
      return;
    }
    setState(() {
      _textError = null;
      _formError = null;
      _saving = true;
    });
    try {
      final UnitRepository repo = ref.read(unitRepositoryProvider);
      final Unit? existing = await repo.findByKey(text);
      if (existing != null && existing.id != unit.id) {
        if (mounted) {
          setState(() {
            _formError = duplicateWordError;
          });
        }
        return;
      }
      await repo.updateWord(unit.id, text: text);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _formError = _isDuplicate(e)
              ? duplicateWordError
              : 'Something went wrong.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _toggleKnown(bool value) async {
    final Unit? unit = _unit;
    if (unit == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      final Unit? updated = await ref
          .read(unitRepositoryProvider)
          .setKnown(unit.id, value);
      if (mounted && updated != null) {
        setState(() {
          _unit = updated;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not update.')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _confirmDelete() async {
    final Unit? unit = _unit;
    if (unit == null) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete this word?'),
          content: Text('Delete "${unit.text}" from the dictionary?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await ref.read(unitRepositoryProvider).delete(unit.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete the word.')),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit word')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadFailed) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit word')),
        body: const Center(child: Text('Something went wrong.')),
      );
    }
    final Unit? unit = _unit;
    if (_notFound || unit == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit word')),
        body: const Center(child: Text('Word not found.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Edit word')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _UnitFormBody(
            textController: _textController,
            textError: _textError,
            formError: _formError,
            saving: _saving,
            onSave: _save,
          ),
          const Divider(height: 32),
          Text('Added: ${_formatDate(unit.createdAt)}'),
          const SizedBox(height: 8),
          Text('Last review: ${_formatNullableDate(unit.lastReview)}'),
          const SizedBox(height: 8),
          Text('Due: ${_formatDate(unit.due)}'),
          if (unit.description != null && unit.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(unit.description!),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('I already know this'),
            value: unit.knownManual,
            onChanged: _busy ? null : _toggleKnown,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _confirmDelete,
              icon: const Icon(Icons.delete),
              label: const Text('Delete word'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Word field + save button for add and edit.
class _UnitFormBody extends StatelessWidget {
  const _UnitFormBody({
    required this.textController,
    required this.textError,
    required this.formError,
    required this.saving,
    required this.onSave,
  });

  final TextEditingController textController;
  final String? textError;
  final String? formError;
  final bool saving;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final String? error = formError;
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: textController,
          decoration: InputDecoration(
            labelText: 'Word',
            errorText: textError,
            border: const OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: saving ? null : onSave,
            child: saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ),
      ],
    );
  }
}

bool _isDuplicate(Object e) {
  final String message = e.toString().toLowerCase();
  return message.contains('unique') || message.contains('duplicate');
}

String _formatDate(DateTime value) {
  return DateFormat.yMMMd().add_jm().format(value.toLocal());
}

String _formatNullableDate(DateTime? value) {
  if (value == null) {
    return 'Never';
  }
  return _formatDate(value);
}
