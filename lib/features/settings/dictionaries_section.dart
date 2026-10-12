import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:parley/data/models/user_dictionary.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/dictionary/dictionary_importer.dart';
import 'package:parley/services/dictionary/dictionary_initializer.dart';
import 'package:parley/services/dictionary/import/import_worker.dart';
import 'settings_providers.dart';

/// Settings -> Dictionaries (SPEC 5.12).
///
/// Lists the bundled dictionary (fixed, lowest priority) and the imported
/// StarDict dictionaries, highest priority first, and enables, reorders or
/// removes them. The resolver consults enabled dictionaries whose target
/// language matches the meaning language setting.
class DictionariesSection extends ConsumerStatefulWidget {
  const DictionariesSection({super.key});

  @override
  ConsumerState<DictionariesSection> createState() =>
      _DictionariesSectionState();
}

class _DictionariesSectionState extends ConsumerState<DictionariesSection> {
  /// Guards the import from a second start (A-15).
  bool _importing = false;

  /// True only while the import job runs; drives the progress row (the
  /// guard also covers the picker and the language dialog).
  bool _working = false;
  DictionaryImportProgress? _progress;

  /// Invalidates progress callbacks of a finished import (A-49): a late
  /// callback must not overwrite the next import's progress.
  int _importToken = 0;

  /// True while a switch or reorder write is in flight (A-49); the
  /// controls are disabled so taps cannot interleave.
  bool _updating = false;
  final TextEditingController _languageController = TextEditingController();

  @override
  void dispose() {
    _languageController.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    if (_importing) {
      return;
    }
    final int token = _importToken;
    // Busy is set before the picker so a double tap cannot open two
    // pickers or two language dialogs (A-15).
    setState(() {
      _importing = true;
      _progress = null;
    });
    bool pickFailed = false;
    DictionaryImportSummary? summary;
    String? invalidReason;
    bool cancelled = false;
    bool failed = false;
    try {
      List<String>? paths;
      try {
        paths = await ref.read(filePickerServiceProvider).pickDictionaryFiles();
      } catch (_) {
        pickFailed = true;
      }
      if (!pickFailed && paths != null && paths.isNotEmpty && mounted) {
        final String? language = await _askLanguage();
        if (language != null && mounted) {
          setState(() {
            _working = true;
          });
          try {
            summary = await ref
                .read(dictionaryImporterProvider)
                .importFiles(
                  paths,
                  targetLang: language,
                  onProgress: (DictionaryImportProgress progress) {
                    // A straggler from a previous import must not touch
                    // the current one (A-49).
                    if (mounted && token == _importToken) {
                      setState(() {
                        _progress = progress;
                      });
                    }
                  },
                );
          } on DictionaryImportException catch (e) {
            invalidReason = e.message;
          } on DictionaryImportCancelledException {
            cancelled = true;
          } catch (_) {
            failed = true;
          }
        }
      }
    } finally {
      // Anything still in flight belongs to this finished import (A-49).
      _importToken++;
      if (mounted) {
        setState(() {
          _importing = false;
          _working = false;
          _progress = null;
        });
      }
    }
    if (!mounted) {
      return;
    }
    if (pickFailed) {
      _showMessage('Could not read the file.');
      return;
    }
    if (summary != null) {
      _showMessage('Imported "${summary.name}" (${summary.wordCount} words).');
    } else if (cancelled) {
      _showMessage('Import cancelled.');
    } else if (invalidReason != null) {
      _showMessage(invalidReason);
    } else if (failed) {
      _showMessage('Import failed.');
    }
  }

  void _cancelImport() {
    ref.read(dictionaryImporterProvider).cancelImport();
  }

  String _progressLabel() {
    final DictionaryImportProgress? progress = _progress;
    final String phase = switch (progress?.phase) {
      ImportPhase.extracting => 'Extracting…',
      ImportPhase.copying => 'Copying files…',
      ImportPhase.indexing => 'Building index…',
      null => 'Starting…',
    };
    final double? fraction = progress?.fraction;
    if (fraction == null) {
      return phase;
    }
    return '$phase ${(fraction * 100).round()}%';
  }

  Future<String?> _askLanguage() async {
    final String current = ref.read(settingsRepositoryProvider).meaningLanguage;
    _languageController.text = current;
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Dictionary language'),
          content: TextField(
            key: const Key('dictionaryLanguageField'),
            controller: _languageController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Language code',
              hintText: 'e.g. ru, de, es',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('dictionaryLanguageImport'),
              onPressed: () =>
                  Navigator.of(context).pop(_languageController.text),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );
    if (value == null) {
      return null;
    }
    final String trimmed = value.trim().toLowerCase();
    return trimmed.isEmpty ? current : trimmed;
  }

  Future<void> _setEnabled(UserDictionary dictionary, bool enabled) async {
    if (_updating) {
      return;
    }
    setState(() {
      _updating = true;
    });
    try {
      await ref
          .read(userDictionaryRepositoryProvider)
          .setEnabled(dictionary.id, enabled);
    } catch (_) {
      if (mounted) {
        _showMessage('Could not update the dictionary.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
        });
      }
    }
  }

  Future<void> _move(UserDictionary dictionary, int delta) async {
    if (_updating) {
      return;
    }
    setState(() {
      _updating = true;
    });
    try {
      await ref
          .read(userDictionaryRepositoryProvider)
          .move(dictionary.id, delta);
    } catch (_) {
      if (mounted) {
        _showMessage('Could not update the dictionary.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
        });
      }
    }
  }

  Future<void> _remove(UserDictionary dictionary) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Remove dictionary?'),
          content: Text('"${dictionary.name}" and its files will be removed.'),
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
        // The bundled dictionary has the lowest priority, so it is listed
        // after the user dictionaries (A-67).
        ListTile(
          key: const Key('bundledDictionaryTile'),
          title: const Text('Bundled English-Russian'),
          subtitle: Text(
            'Built-in · '
            '${NumberFormat.decimalPattern().format(bundledDictionaryWordCount)}'
            ' words',
          ),
        ),
        ListTile(
          key: const Key('importDictionaryTile'),
          leading: const Icon(Icons.library_add),
          title: const Text('Import dictionary'),
          subtitle: const Text(
            'Select the .ifo or .dsl files of one dictionary '
            '(or a single .zip archive with them).',
          ),
          enabled: !_importing,
          onTap: _import,
        ),
        if (_working)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: _progress?.fraction),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _progressLabel(),
                        key: const Key('importProgressLabel'),
                      ),
                    ),
                    TextButton(
                      key: const Key('importCancelButton'),
                      onPressed: _cancelImport,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
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
            onChanged: _updating
                ? null
                : (bool value) => _setEnabled(dictionary, value),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dictionary.name, overflow: TextOverflow.ellipsis),
                Text(
                  '${dictionary.targetLang} · '
                  '${NumberFormat.decimalPattern().format(dictionary.wordCount)}'
                  ' words',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('dictionaryUp_${dictionary.id}'),
            icon: const Icon(Icons.arrow_upward),
            tooltip: 'Move up',
            onPressed: _updating ? null : () => _move(dictionary, -1),
          ),
          IconButton(
            key: ValueKey('dictionaryDown_${dictionary.id}'),
            icon: const Icon(Icons.arrow_downward),
            tooltip: 'Move down',
            onPressed: _updating ? null : () => _move(dictionary, 1),
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
