import 'package:flutter/material.dart';

/// About section (SPEC 5.10): app version.
///
/// Version matches `pubspec.yaml` (0.2.0). No `package_info` dependency
/// is allowed by SPEC 3.1, so the version is a plain constant.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  // (A-63) Kept in sync with `version:` in pubspec.yaml by a test.
  static const String appVersion = '0.2.0';

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
          subtitle: Text('Version $appVersion'),
        ),
        const ListTile(
          leading: Icon(Icons.menu_book_outlined),
          title: Text('Dictionary data'),
          subtitle: Text('Wiktionary via kaikki.org (CC BY-SA)'),
        ),
      ],
    );
  }
}
