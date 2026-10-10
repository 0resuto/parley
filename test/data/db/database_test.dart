import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/data/db/database.dart';
import 'package:path/path.dart' as p;

void main() {
  late AppDatabase db;

  final createdAt = DateTime.utc(2026, 1, 1, 12);
  final due = DateTime.utc(2026, 1, 2, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  UnitsCompanion unitRow(String text, String key) {
    return UnitsCompanion.insert(
      unitText: text,
      textKey: key,
      phase: 0,
      due: due,
      fsrsJson: '{}',
      createdAt: createdAt,
    );
  }

  test('units insert, read and delete', () async {
    final id = await db.into(db.units).insert(unitRow('Cow', 'cow'));

    final rows = await db.select(db.units).get();
    expect(rows, hasLength(1));
    expect(rows.first.id, id);
    expect(rows.first.unitText, 'Cow');
    expect(rows.first.textKey, 'cow');
    expect(rows.first.forms, '[]');
    expect(rows.first.knownManual, isFalse);
    expect(rows.first.phase, 0);

    await (db.delete(db.units)..where((t) => t.id.equals(id))).go();
    expect(await db.select(db.units).get(), isEmpty);
  });

  test('text_key unique constraint throws', () async {
    await db.into(db.units).insert(unitRow('Cow', 'cow'));

    expect(
      () => db.into(db.units).insert(unitRow('COW copy', 'cow')),
      throwsException,
    );
  });

  test('reviews insert, read and delete', () async {
    final unitId = await db.into(db.units).insert(unitRow('Cow', 'cow'));
    final reviewedAt = DateTime.utc(2026, 1, 3, 12);

    final reviewId = await db
        .into(db.reviews)
        .insert(
          ReviewsCompanion.insert(
            unitId: unitId,
            rating: 3,
            source: 'card',
            reviewedAt: reviewedAt,
          ),
        );

    final rows = await db.select(db.reviews).get();
    expect(rows, hasLength(1));
    expect(rows.first.id, reviewId);
    expect(rows.first.unitId, unitId);
    expect(rows.first.rating, 3);
    expect(rows.first.source, 'card');

    await (db.delete(db.reviews)..where((t) => t.id.equals(reviewId))).go();
    expect(await db.select(db.reviews).get(), isEmpty);
  });

  test('conversations and messages insert, read and delete', () async {
    final conversationId = await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            title: 'First chat',
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );

    final messageId = await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            conversationId: conversationId,
            role: 'user',
            content: 'Hello',
            createdAt: createdAt,
          ),
        );

    final conversations = await db.select(db.conversations).get();
    expect(conversations, hasLength(1));
    expect(conversations.first.title, 'First chat');

    final messages = await db.select(db.messages).get();
    expect(messages, hasLength(1));
    expect(messages.first.id, messageId);
    expect(messages.first.processedByNotes, isFalse);

    await (db.delete(db.messages)..where((t) => t.id.equals(messageId))).go();
    expect(await db.select(db.messages).get(), isEmpty);

    await (db.delete(
      db.conversations,
    )..where((t) => t.id.equals(conversationId))).go();
    expect(await db.select(db.conversations).get(), isEmpty);
  });

  test('deleting a conversation deletes its messages', () async {
    final conversationId = await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            title: 'To delete',
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
    for (final content in ['hi', 'hello']) {
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              conversationId: conversationId,
              role: 'user',
              content: content,
              createdAt: createdAt,
            ),
          );
    }
    expect(await db.select(db.messages).get(), hasLength(2));

    await (db.delete(
      db.conversations,
    )..where((t) => t.id.equals(conversationId))).go();

    expect(await db.select(db.conversations).get(), isEmpty);
    expect(await db.select(db.messages).get(), isEmpty);
  });

  test('deleting a unit deletes its reviews', () async {
    final unitId = await db.into(db.units).insert(unitRow('Cow', 'cow'));
    await db
        .into(db.reviews)
        .insert(
          ReviewsCompanion.insert(
            unitId: unitId,
            rating: 4,
            source: 'chat',
            reviewedAt: createdAt,
          ),
        );
    expect(await db.select(db.reviews).get(), hasLength(1));

    await (db.delete(db.units)..where((t) => t.id.equals(unitId))).go();

    expect(await db.select(db.units).get(), isEmpty);
    expect(await db.select(db.reviews).get(), isEmpty);
  });

  test('a v1 database migrates to v2 keeping units and reviews', () async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'parley_migration_test',
    );
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
    final File file = File(p.join(dir.path, 'v1.sqlite'));
    await File(p.join('test', 'fixtures', 'db_v1.sqlite')).copy(file.path);

    final AppDatabase migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);

    final List<Unit> rows = await migrated.select(migrated.units).get();
    expect(rows, hasLength(1));
    expect(rows.first.unitText, 'Cow');
    expect(rows.first.textKey, 'cow');
    expect(rows.first.forms, '["cows"]');
    expect(rows.first.knownManual, isFalse);

    final List<Review> reviewRows = await migrated
        .select(migrated.reviews)
        .get();
    expect(reviewRows, hasLength(1));
    expect(reviewRows.first.rating, 3);
    expect(reviewRows.first.source, 'card');
  });
}
