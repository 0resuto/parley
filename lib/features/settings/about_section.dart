import 'package:flutter/material.dart';

import 'settings_section.dart';

/// About section (SPEC 5.10): app version.
///
/// Version matches `pubspec.yaml` (0.3.0). No `package_info` dependency
/// is allowed by SPEC 3.1, so the version is a plain constant.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  // (A-63) Kept in sync with `version:` in pubspec.yaml by a test.
  static const String appVersion = '0.4.0';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('About', style: Theme.of(context).textTheme.titleSmall),
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Parley'),
          subtitle: SettingsDescription('Version $appVersion'),
        ),
        const ListTile(
          leading: Icon(Icons.menu_book_outlined),
          title: Text('Dictionary data'),
          subtitle: SettingsDescription('Wiktionary via kaikki.org (CC BY-SA)'),
        ),
        const ListTile(
          leading: Icon(Icons.record_voice_over_outlined),
          title: Text('Offline speech models'),
          subtitle: SettingsDescription(
            'Moonshine and Whisper via sherpa-onnx (MIT)',
          ),
        ),
      ],
    );
  }
}
