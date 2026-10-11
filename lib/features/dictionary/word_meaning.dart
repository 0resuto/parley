import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dictionary_providers.dart';

/// Shows a word's meaning resolved live from the local dictionary sources
/// (user dictionaries, then the bundle; PLAN 19.1, SPEC 5.12). Renders
/// nothing while loading or when the word is missing.
class WordMeaning extends ConsumerStatefulWidget {
  const WordMeaning({super.key, required this.textKey, this.style});

  final String textKey;
  final TextStyle? style;

  @override
  ConsumerState<WordMeaning> createState() => _WordMeaningState();
}

class _WordMeaningState extends ConsumerState<WordMeaning> {
  String? _meaning;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant WordMeaning oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textKey != widget.textKey) {
      _load();
    }
  }

  Future<void> _load() async {
    String? meaning;
    try {
      meaning = await ref
          .read(meaningResolverProvider)
          .dictionaryMeaning(widget.textKey);
    } catch (_) {
      meaning = null;
    }
    if (mounted) {
      setState(() {
        _meaning = meaning;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? meaning = _meaning;
    if (meaning == null || meaning.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(meaning, style: widget.style);
  }
}
