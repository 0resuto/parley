import 'package:drift/drift.dart';

class Units extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get unitText => text().named('text')();
  TextColumn get textKey => text().unique()();
  TextColumn get forms => text().withDefault(const Constant('[]'))();
  TextColumn get translationRu => text().withDefault(const Constant(''))();
  TextColumn get description => text().nullable()();
  BoolColumn get knownManual => boolean().withDefault(const Constant(false))();
  IntColumn get phase => integer()();
  DateTimeColumn get due => dateTime()();
  RealColumn get stability => real().nullable()();
  TextColumn get fsrsJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastReview => dateTime().nullable()();
}

class Reviews extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get unitId =>
      integer().references(Units, #id, onDelete: KeyAction.cascade)();
  IntColumn get rating => integer()();
  TextColumn get source => text()();
  DateTimeColumn get reviewedAt => dateTime()();
}

class Conversations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

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
