import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_providers.dart';
import 'package:parley/services/documents/document_store.dart';
import 'document_screen.dart';

/// Tutor settings: new-word density plus Rules and Notes entries (SPEC 5.10).
class TutorSection extends ConsumerStatefulWidget {
  const TutorSection({super.key});

  @override
  ConsumerState<TutorSection> createState() => _TutorSectionState();
}

class _TutorSectionState extends ConsumerState<TutorSection> {
  late int _percent;

  @override
  void initState() {
    super.initState();
    _percent = ref.read(settingsRepositoryProvider).newWordPercent;
  }

  void _openDocument(DocumentKind kind) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DocumentScreen(kind: kind)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Tutor', style: Theme.of(context).textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('New-word density: $_percent%'),
        ),
        Slider(
          key: const Key('densitySlider'),
          value: _percent.toDouble(),
          min: 0,
          max: 30,
          divisions: 6,
          label: '$_percent%',
          onChanged: (double value) {
            final int next = value.round();
            setState(() {
              _percent = next;
            });
            ref.read(settingsRepositoryProvider).setNewWordPercent(next);
          },
        ),
        ListTile(
          leading: const Icon(Icons.rule),
          title: const Text('Rules'),
          subtitle: const Text('View and edit tutor rules'),
          onTap: () => _openDocument(DocumentKind.rules),
        ),
        ListTile(
          leading: const Icon(Icons.note),
          title: const Text('Notes'),
          subtitle: const Text('View and edit tutor notes'),
          onTap: () => _openDocument(DocumentKind.notes),
        ),
      ],
    );
  }
}
