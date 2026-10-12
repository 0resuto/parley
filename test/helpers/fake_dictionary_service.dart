import 'dart:async';

import 'package:parley/data/models/unit.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';

/// In-memory dictionary fake for widget and unit tests.
///
/// Mirrors the real service by normalizing the lookup key.
class FakeDictionaryService implements DictionaryService {
  FakeDictionaryService([Map<String, String> entries = const {}])
    : this.withDetails(entries: entries);

  FakeDictionaryService.withDetails({
    Map<String, String> entries = const {},
    Map<String, String> transcriptions = const {},
    Map<String, List<String>> examples = const {},
  }) : _entries = Map<String, String>.of(entries),
       _transcriptions = Map<String, String>.of(transcriptions),
       _examples = Map<String, List<String>>.of(examples);

  final Map<String, String> _entries;
  final Map<String, String> _transcriptions;
  final Map<String, List<String>> _examples;

  /// When set, [lookup] waits for it before answering (for pending-state
  /// tests).
  Completer<void>? gate;

  /// Number of lookups, for assertions.
  int lookups = 0;

  @override
  Future<DictionaryEntry?> lookup(String wordKey) async {
    lookups++;
    final Completer<void>? pending = gate;
    if (pending != null) {
      await pending.future;
    }
    final String key = normalizeKey(wordKey);
    final String? translation = _entries[key];
    if (key.isEmpty || translation == null) {
      return null;
    }
    return DictionaryEntry(
      textKey: key,
      translation: translation,
      transcription: _transcriptions[key],
      examples: _examples[key] ?? const [],
    );
  }

  @override
  Future<void> dispose() async {}
}
