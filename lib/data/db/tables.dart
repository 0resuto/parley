import 'package:drift/drift.dart';

// A-52: the due queue filters and orders by due.
@TableIndex(name: 'units_due', columns: {#due})
class Units extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get unitText => text().named('text')();
  TextColumn get textKey => text().unique()();
  TextColumn get forms => text().withDefault(const Constant('[]'))();
  TextColumn get description => text().nullable()();
  BoolColumn get knownManual => boolean().withDefault(const Constant(false))();
  IntColumn get phase => integer()();
  DateTimeColumn get due => dateTime()();
  RealColumn get stability => real().nullable()();
  TextColumn get fsrsJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastReview => dateTime().nullable()();
}

// A-52: review lookups per unit (Tap Again, Word Judge).
@TableIndex(name: 'reviews_unit_id', columns: {#unitId})
class Reviews extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get unitId =>
      integer().references(Units, #id, onDelete: KeyAction.cascade)();
  IntColumn get rating => integer()();
  TextColumn get source => text()();
  DateTimeColumn get reviewedAt => dateTime()();
}

/// One imported user dictionary (SPEC 5.12).
///
/// Metadata only: the dictionary data stays in its original files under
/// `path`; `position` is the priority (lower values are consulted first)
/// and `target_lang` is matched against the meaning language setting.
// A-52: the resolver scans enabled dictionaries of the target language
// ordered by priority.
@TableIndex(
  name: 'dictionaries_lookup',
  columns: {#targetLang, #enabled, #position},
)
// A-55: one row per directory, so removing one row cannot delete the
// files of another.
@TableIndex(name: 'dictionaries_path', columns: {#path}, unique: true)
@DataClassName('UserDictionaryRow')
class Dictionaries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get format => text()();
  TextColumn get path => text()();
  TextColumn get targetLang => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get position => integer()();
  IntColumn get wordCount => integer()();
  DateTimeColumn get importedAt => dateTime()();
}

class Conversations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

// A-52: message lists per conversation.
@TableIndex(name: 'messages_conversation_id', columns: {#conversationId})
class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get conversationId =>
      integer().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text()();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get processedByNotes =>
      boolean().withDefault(const Constant(false))();
}
