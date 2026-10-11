import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/dictionary/dictionary_importer.dart';
import 'package:parley/services/export/file_picker_service.dart';
import 'settings_providers.dart';

/// Settings -> Dictionaries (SPEC 5.12).
///
/// Imports dictionary files, lists them highest priority first, and
/// enables, reorders or removes them. The resolver consults enabled user
/// dictionaries before the bundled one.
class DictionariesSection extends ConsumerStatefulWidget {
  const DictionariesSection({super.key});

  @override
  ConsumerState<DictionariesSection> createState() =>
      _DictionariesSectionState();
}

class _DictionariesSectionState extends ConsumerState<DictionariesSection> {
  bool _importing = false;

  Future<void> _import() async {
    if (_importing) {
      return;
    }
    final PickedDictionaryFile? picked;
    try {
      picked = await ref.read(filePickerServiceProvider).pickDictionaryFile();
    } catch (_) {
      if (mounted) {
        _showMessage('Could not read the file.');
      }
      return;
    }
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _importing = true;
    });
    DictionaryImportSummary? summary;
    String? invalidReason;
    bool failed = false;
    try {
      summary = await ref.read(dictionaryImporterProvider).importFile(picked);
    } on DictionaryImportException catch (e) {
      invalidReason = e.message;
    } catch (_) {
      failed = true;
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
        });
      }
    }
    if (!mounted) {
      return;
    }
    if (summary != null) {
      _showMessage('Imported "${summary.name}" (${summary.entryCount} words).');
    } else if (invalidReason != null) {
      _showMessage(invalidReason);
    } else if (failed) {
      _showMessage('Import failed.');
    }
  }

  Future<void> _setEnabled(UserDictionary dictionary, bool enabled) async {
    try {
      await ref
          .read(userDictionaryRepositoryProvider)
          .setEnabled(dictionary.id, enabled);
    } catch (_) {
      if (mounted) {
        _showMessage('Could not update the dictionary.');
      }
    }
  }

  Future<void> _move(UserDictionary dictionary, int delta) async {
    try {
      await ref
          .read(userDictionaryRepositoryProvider)
          .move(dictionary.id, delta);
    } catch (_) {
      if (mounted) {
        _showMessage('Could not update the dictionary.');
      }
    }
  }

  Future<void> _remove(UserDictionary dictionary) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Remove dictionary?'),
          content: Text(
            '"${dictionary.name}" and its ${dictionary.entryCount} words '
            'will be removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await ref.read(userDictionaryRepositoryProvider).remove(dictionary.id);
    } catch (_) {
      if (mounted) {
        _showMessage('Could not remove the dictionary.');
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<UserDictionary>> dictionaries = ref.watch(
      userDictionariesProvider,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Dictionaries',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Your dictionaries are used first, then the bundled one; '
            'the AI fills the rest when online.',
          ),
        ),
        dictionaries.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const ListTile(
            key: Key('dictionariesError'),
            title: Text('Your dictionaries could not be loaded.'),
          ),
          data: (List<UserDictionary> list) {
            if (list.isEmpty) {
              return const ListTile(
                key: Key('dictionariesEmpty'),
                title: Text('No imported dictionaries yet.'),
              );
            }
            return Column(
              children: [for (final UserDictionary d in list) _tile(d)],
            );
          },
        ),
        ListTile(
          key: const Key('importDictionaryTile'),
          leading: const Icon(Icons.library_add),
          title: const Text('Import dictionary'),
          subtitle: const Text(
            'A CSV file (word;translation) or an SQLite file '
            "with an 'entry' table.",
          ),
          enabled: !_importing,
          onTap: _import,
        ),
      ],
    );
  }

  Widget _tile(UserDictionary dictionary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Switch(
            key: ValueKey('dictionarySwitch_${dictionary.id}'),
            value: dictionary.enabled,
            onChanged: (bool value) => _setEnabled(dictionary, value),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dictionary.name, overflow: TextOverflow.ellipsis),
                Text(
                  '${dictionary.entryCount} words',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('dictionaryUp_${dictionary.id}'),
            icon: const Icon(Icons.arrow_upward),
            tooltip: 'Move up',
            onPressed: () => _move(dictionary, -1),
          ),
          IconButton(
            key: ValueKey('dictionaryDown_${dictionary.id}'),
            icon: const Icon(Icons.arrow_downward),
            tooltip: 'Move down',
            onPressed: () => _move(dictionary, 1),
          ),
          IconButton(
            key: ValueKey('dictionaryRemove_${dictionary.id}'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove',
            onPressed: () => _remove(dictionary),
          ),
        ],
      ),
    );
  }
}
