/// One imported user dictionary (SPEC 5.12).
class UserDictionary {
  const UserDictionary({
    required this.id,
    required this.name,
    required this.enabled,
    required this.position,
    required this.entryCount,
    required this.importedAt,
  });

  final int id;

  final String name;

  /// Disabled dictionaries are skipped by lookups.
  final bool enabled;

  /// Priority: lower values are consulted first.
  final int position;

  final int entryCount;

  final DateTime importedAt;

  UserDictionary copyWith({bool? enabled}) {
    return UserDictionary(
      id: id,
      name: name,
      enabled: enabled ?? this.enabled,
      position: position,
      entryCount: entryCount,
      importedAt: importedAt,
    );
  }
}
