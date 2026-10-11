import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/services/settings/settings_repository.dart';
import 'settings_providers.dart';

/// Translation settings (SPEC 5.10): the AI in-sentence meaning switch
/// and the meaning language.
class TranslationSection extends ConsumerStatefulWidget {
  const TranslationSection({super.key});

  @override
  ConsumerState<TranslationSection> createState() => _TranslationSectionState();
}

class _TranslationSectionState extends ConsumerState<TranslationSection> {
  late bool _contextTranslation;
  late String _meaningLanguage;
  final TextEditingController _languageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final SettingsRepository settings = ref.read(settingsRepositoryProvider);
    _contextTranslation = settings.contextTranslation;
    _meaningLanguage = settings.meaningLanguage;
  }

  @override
  void dispose() {
    _languageController.dispose();
    super.dispose();
  }

  Future<void> _editMeaningLanguage() async {
    _languageController.text = _meaningLanguage;
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Meaning language'),
          content: TextField(
            key: const Key('meaningLanguageField'),
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
              key: const Key('meaningLanguageSave'),
              onPressed: () =>
                  Navigator.of(context).pop(_languageController.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (value == null || !mounted) {
      return;
    }
    await ref.read(settingsRepositoryProvider).setMeaningLanguage(value);
    if (mounted) {
      setState(() {
        _meaningLanguage = ref.read(settingsRepositoryProvider).meaningLanguage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Translation',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        SwitchListTile(
          key: const Key('contextTranslationSwitch'),
          title: const Text('In-sentence translation (AI)'),
          subtitle: const Text(
            'Ask the AI how the word is meant in the sentence '
            '(uses extra tokens).',
          ),
          value: _contextTranslation,
          onChanged: (bool value) {
            setState(() {
              _contextTranslation = value;
            });
            ref.read(settingsRepositoryProvider).setContextTranslation(value);
          },
        ),
        ListTile(
          key: const Key('meaningLanguageTile'),
          title: const Text('Meaning language'),
          subtitle: const Text(
            'Language the AI translates meanings into '
            '(the bundled dictionary is English-Russian).',
          ),
          trailing: Text(_meaningLanguage),
          onTap: _editMeaningLanguage,
        ),
      ],
    );
  }
}
