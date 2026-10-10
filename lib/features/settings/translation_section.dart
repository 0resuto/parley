import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_providers.dart';

/// Translation settings (SPEC 5.10): the AI in-sentence meaning switch.
class TranslationSection extends ConsumerStatefulWidget {
  const TranslationSection({super.key});

  @override
  ConsumerState<TranslationSection> createState() => _TranslationSectionState();
}

class _TranslationSectionState extends ConsumerState<TranslationSection> {
  late bool _contextTranslation;

  @override
  void initState() {
    super.initState();
    _contextTranslation = ref
        .read(settingsRepositoryProvider)
        .contextTranslation;
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
      ],
    );
  }
}
