import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/export/csv_importer.dart';
import 'package:parley/services/export/export_service.dart';
import 'package:parley/services/export/file_picker_service.dart';
import 'about_section.dart';
import 'ai_provider_section.dart';
import 'dictionaries_section.dart';
import 'settings_providers.dart';
import 'translation_section.dart';
import 'tutor_section.dart';
import 'voice_section.dart';

/// Settings screen (SPEC 5.10).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Guards the data actions from a second start (A-15).
  bool _busy = false;

  /// True only while the actual export/import work runs; drives the
  /// progress indicator (the guard also covers pickers and dialogs).
  bool _working = false;

  Future<void> _export() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _working = true;
    });
    try {
      final ExportService service = ref.read(exportServiceProvider);
      final String json = await service.exportJson();
      final String name = service.exportFileName(ref.read(clockProvider).now());
      await ref.read(shareServiceProvider).shareJsonFile(name, json);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Export failed.')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _working = false;
        });
      }
    }
  }

  Future<void> _import() async {
    if (_busy) {
      return;
    }
    // Busy is set before the picker so a double tap cannot open two
    // pickers (A-15).
    setState(() {
      _busy = true;
    });
    bool pickFailed = false;
    bool invalidFile = false;
    bool failed = false;
    ImportSummary? summary;
    try {
      PickedJsonFile? picked;
      try {
        picked = await ref.read(filePickerServiceProvider).pickJsonFile();
      } catch (_) {
        pickFailed = true;
      }
      if (!pickFailed && picked != null && mounted) {
        final ImportOptions? options = await _askImportOptions();
        if (options != null && mounted) {
          setState(() {
            _working = true;
          });
          try {
            summary = await ref
                .read(exportServiceProvider)
                .importJson(picked.content, options: options);
          } on ExportFormatException {
            invalidFile = true;
          } catch (_) {
            failed = true;
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _working = false;
        });
      }
    }
    if (!mounted) {
      return;
    }
    if (pickFailed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not read the file.')));
      return;
    }
    if (summary != null) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Import finished'),
            content: Text(summary!.describe()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } else if (invalidFile) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid export file.')));
    } else if (failed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Import failed.')));
    }
  }

  Future<void> _importCsv() async {
    if (_busy) {
      return;
    }
    // Busy is set before the picker so a double tap cannot open two
    // pickers (A-15).
    setState(() {
      _busy = true;
    });
    bool pickFailed = false;
    bool failed = false;
    CsvImportSummary? summary;
    try {
      PickedCsvFile? picked;
      try {
        picked = await ref.read(filePickerServiceProvider).pickCsvFile();
      } catch (_) {
        pickFailed = true;
      }
      if (!pickFailed && picked != null && mounted) {
        setState(() {
          _working = true;
        });
        try {
          summary = await ref
              .read(csvImporterProvider)
              .importCsv(picked.content);
        } catch (_) {
          failed = true;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _working = false;
        });
      }
    }
    if (!mounted) {
      return;
    }
    if (pickFailed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not read the file.')));
      return;
    }
    if (summary != null) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Import finished'),
            content: Text(summary!.describe()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } else if (failed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Import failed.')));
    }
  }

  Future<ImportOptions?> _askImportOptions() {
    bool overwrite = false;
    bool replaceDocs = false;
    return showDialog<ImportOptions>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              title: const Text('Import JSON'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    title: const Text('Overwrite existing'),
                    value: overwrite,
                    onChanged: (bool? value) {
                      setState(() {
                        overwrite = value ?? false;
                      });
                    },
                  ),
                  CheckboxListTile(
                    title: const Text('Replace rules and notes'),
                    value: replaceDocs,
                    onChanged: (bool? value) {
                      setState(() {
                        replaceDocs = value ?? false;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    ImportOptions(
                      overwriteExisting: overwrite,
                      replaceDocs: replaceDocs,
                    ),
                  ),
                  child: const Text('Import'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // SingleChildScrollView + Column (not a lazy ListView) so every
      // section is built upfront; widget tests can find off-screen items
      // and scroll to them with ensureVisible.
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AiProviderSection(),
            const TutorSection(),
            const TranslationSection(),
            const DictionariesSection(),
            const VoiceSection(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Data',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.upload),
              title: const Text('Export JSON'),
              subtitle: const Text('Share a backup of your dictionary'),
              onTap: _busy ? null : _export,
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Import JSON'),
              subtitle: const Text('Restore from a backup file'),
              onTap: _busy ? null : _import,
            ),
            ListTile(
              leading: const Icon(Icons.table_chart),
              title: const Text('Import CSV'),
              subtitle: const Text('Add words from a CSV file'),
              onTap: _busy ? null : _importCsv,
            ),
            const AboutSection(),
            if (_working) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
