/// One imported user dictionary (SPEC 5.12).
///
/// Metadata only: the dictionary data stays in its original files under
/// [path]; nothing is copied into the app database.
class UserDictionary {
  const UserDictionary({
    required this.id,
    required this.name,
    required this.format,
    required this.path,
    required this.targetLang,
    required this.enabled,
    required this.position,
    required this.wordCount,
    required this.importedAt,
  });

  final int id;

  final String name;

  /// Source format, e.g. `stardict`.
  final String format;

  /// Absolute directory holding the dictionary files.
  final String path;

  /// Language code meanings are translated into (matched against the
  /// meaning language setting).
  final String targetLang;

  /// Disabled dictionaries are skipped by lookups.
  final bool enabled;

  /// Priority: lower values are consulted first.
  final int position;

  final int wordCount;

  final DateTime importedAt;
}
