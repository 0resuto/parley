import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/services/dictionary/dictionary_service.dart';
import 'dictionary_providers.dart';

/// Shows a word's meaning resolved live from the local dictionary sources
/// (user dictionaries, then the bundle; PLAN 19.1, SPEC 5.12). Renders the
/// transcription too when the source provides one (PLAN 20.3); nothing
/// while loading or when the word is missing.
class WordMeaning extends ConsumerStatefulWidget {
  const WordMeaning({super.key, required this.textKey, this.style});

  final String textKey;
  final TextStyle? style;

  @override
  ConsumerState<WordMeaning> createState() => _WordMeaningState();
}

class _WordMeaningState extends ConsumerState<WordMeaning> {
  DictionaryEntry? _entry;
  int _loadToken = 0;

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
    // Only the newest load may set the state: an older slow lookup must
    // not overwrite a newer word's meaning (A-28).
    final int token = ++_loadToken;
    final String textKey = widget.textKey;
    DictionaryEntry? entry;
    try {
      entry = await ref.read(meaningResolverProvider).dictionaryEntry(textKey);
    } catch (_) {
      entry = null;
    }
    if (mounted && token == _loadToken) {
      setState(() {
        _entry = entry;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-resolve when the user dictionaries change (import, enable,
    // reorder, remove): the shown meaning follows the active sources.
    ref.listen(userDictionariesProvider, (_, _) {
      _load();
    });
    final DictionaryEntry? entry = _entry;
    if (entry == null || entry.translation.isEmpty) {
      return const SizedBox.shrink();
    }
    final String? transcription = entry.transcription;
    if (transcription == null) {
      return Text(entry.translation, style: widget.style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(entry.translation, style: widget.style),
        Text(
          transcription,
          key: const Key('wordMeaningTranscription'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
