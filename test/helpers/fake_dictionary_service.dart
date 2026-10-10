import 'package:parley/data/models/unit.dart';
import 'package:parley/services/dictionary/dictionary_service.dart';

/// In-memory dictionary fake for widget and unit tests.
///
/// Mirrors the real service by normalizing the lookup key.
class FakeDictionaryService implements DictionaryService {
  FakeDictionaryService([Map<String, String> entries = const {}])
    : _entries = Map<String, String>.of(entries);

  final Map<String, String> _entries;

  /// Number of lookups, for assertions.
  int lookups = 0;

  @override
  Future<DictionaryEntry?> lookup(String wordKey) async {
    lookups++;
    final String key = normalizeKey(wordKey);
    final String? translation = _entries[key];
    if (key.isEmpty || translation == null) {
      return null;
    }
    return DictionaryEntry(textKey: key, translation: translation);
  }

  @override
  Future<void> dispose() async {}
}
