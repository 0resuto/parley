import 'package:parley/services/dictionary/dictionary_service.dart';

/// Priority-ordered lookups over the user's imported dictionaries (SPEC 5.12).
///
/// The meaning resolver consults user dictionaries before the bundled one.
abstract class UserDictionaryLookup {
  /// The entry for [wordKey] from the highest-priority enabled user
  /// dictionary, or null when no enabled dictionary contains the word.
  ///
  /// [wordKey] is normalized internally, so any case/apostrophe form works.
  Future<DictionaryEntry?> lookup(String wordKey);
}

/// Fallback used before any user dictionary exists: every lookup misses.
class EmptyUserDictionaryLookup implements UserDictionaryLookup {
  const EmptyUserDictionaryLookup();

  @override
  Future<DictionaryEntry?> lookup(String wordKey) async => null;
}
