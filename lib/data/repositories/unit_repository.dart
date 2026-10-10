import 'package:drift/drift.dart';
import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart' as db;
import 'package:parley/data/models/unit.dart';
import 'package:parley/services/srs/srs_service.dart';

/// Dictionary storage (PLAN 2.2).
///
/// Time comes from [Clock]; new units get a fresh FSRS card from
/// [SrsService]. `setKnown` only flips the flag so un-marking Known
/// restores the previous FSRS state.
class UnitRepository {
  UnitRepository(this._db, {required Clock clock, SrsService? srs})
    : _clock = clock,
      _srs = srs ?? SrsService();

  final db.AppDatabase _db;
  final Clock _clock;
  final SrsService _srs;

  /// Adds a unit. [text] is trimmed for display, [textKey] is normalized.
  ///
  /// Throws when [text] is blank or [textKey] already exists.
  Future<Unit> add({
    required String text,
    String translationRu = '',
    String? description,
    List<String> forms = const [],
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('text is required');
    }
    final String key = normalizeKey(trimmed);
    if (key.isEmpty) {
      throw ArgumentError('text is required');
    }
    final DateTime now = _clock.now().toUtc();
    final SrsCard card = _srs.newCard(now);
    final List<String> normalizedForms = _normalizeForms(forms, key);

    final int id = await _db
        .into(_db.units)
        .insert(
          db.UnitsCompanion.insert(
            unitText: trimmed,
            textKey: key,
            forms: Value(encodeForms(normalizedForms)),
            translationRu: Value(translationRu),
            description: Value(description),
            phase: card.phase.value,
            due: card.due,
            stability: Value(card.stability),
            fsrsJson: card.toJson(),
            createdAt: now,
          ),
        );
    final Unit? created = await getById(id);
    return created!;
  }

  /// Finds a unit by normalized key matching `text_key` or `forms`.
  Future<Unit?> findByKey(String query) async {
    final String key = normalizeKey(query);
    if (key.isEmpty) {
      return null;
    }
    final List<db.Unit> rows = await _db.select(_db.units).get();
    for (final db.Unit row in rows) {
      if (row.textKey == key) {
        return _toModel(row);
      }
    }
    for (final db.Unit row in rows) {
      if (decodeForms(row.forms).contains(key)) {
        return _toModel(row);
      }
    }
    return null;
  }

  /// Reads one unit by id, or null when missing.
  Future<Unit?> getById(int id) async {
    final List<db.Unit> rows = await (_db.select(
      _db.units,
    )..where((t) => t.id.equals(id))).get();
    if (rows.isEmpty) {
      return null;
    }
    return _toModel(rows.first);
  }

  /// Replaces the unit row with [unit] (by id).
  ///
  /// [unit.text] is trimmed and [unit.textKey] is recomputed so the row
  /// stays consistent. Throws when the new key collides.
  Future<Unit> update(Unit unit) async {
    final String trimmed = unit.text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('text is required');
    }
    final String key = normalizeKey(trimmed);
    if (key.isEmpty) {
      throw ArgumentError('text is required');
    }
    final List<String> normalizedForms = _normalizeForms(unit.forms, key);
    await (_db.update(_db.units)..where((t) => t.id.equals(unit.id))).write(
      db.UnitsCompanion(
        unitText: Value(trimmed),
        textKey: Value(key),
        forms: Value(encodeForms(normalizedForms)),
        translationRu: Value(unit.translationRu),
        description: Value(unit.description),
        knownManual: Value(unit.knownManual),
        phase: Value(unit.phase.value),
        due: Value(unit.due),
        stability: Value(unit.stability),
        fsrsJson: Value(unit.fsrsJson),
        createdAt: Value(unit.createdAt),
        lastReview: Value(unit.lastReview),
      ),
    );
    final Unit? updated = await getById(unit.id);
    return updated!;
  }

  /// Deletes the unit (reviews cascade).
  Future<void> delete(int id) async {
    await (_db.delete(_db.units)..where((t) => t.id.equals(id))).go();
  }

  /// Flips only the Known flag, keeping the FSRS state untouched.
  Future<Unit?> setKnown(int id, bool known) async {
    await (_db.update(_db.units)..where((t) => t.id.equals(id))).write(
      db.UnitsCompanion(knownManual: Value(known)),
    );
    return getById(id);
  }

  /// Watches all units, newest first.
  ///
  /// [status] filters by derived status, [query] matches text,
  /// translation or key (case-insensitive, substring).
  Stream<List<Unit>> watchAll({UnitStatus? status, String? query}) {
    final String needle = (query ?? '').trim().toLowerCase();
    final String normNeedle = needle.isEmpty ? '' : normalizeKey(needle);
    final queryStream = _db.select(_db.units)
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ]);
    return queryStream.watch().map((rows) {
      Iterable<Unit> units = rows.map(_toModel);
      if (status != null) {
        units = units.where((u) => statusOf(u) == status);
      }
      if (needle.isNotEmpty) {
        units = units.where(
          (u) =>
              u.text.toLowerCase().contains(needle) ||
              u.translationRu.toLowerCase().contains(needle) ||
              u.textKey.contains(normNeedle),
        );
      }
      return units.toList();
    });
  }

  /// Non-Known units with `due <= now`, oldest due first.
  Future<List<Unit>> dueQueue(DateTime now) async {
    final DateTime utc = now.toUtc();
    final List<db.Unit> rows =
        await (_db.select(_db.units)
              ..where(
                (t) =>
                    t.knownManual.equals(false) &
                    t.due.isSmallerOrEqualValue(utc),
              )
              ..orderBy([
                (t) => OrderingTerm(expression: t.due, mode: OrderingMode.asc),
                (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
              ]))
            .get();
    return rows.map(_toModel).toList();
  }

  /// Non-Known New/Learning/Young units: due-now first, then newest.
  Future<List<Unit>> targetWords(int limit, DateTime now) async {
    final DateTime utc = now.toUtc();
    final List<db.Unit> rows = await _db.select(_db.units).get();
    final List<Unit> units = rows
        .map(_toModel)
        .where((u) => !u.knownManual && isTargetWord(u))
        .toList();
    units.sort((a, b) {
      final bool aDue = !a.due.isAfter(utc);
      final bool bDue = !b.due.isAfter(utc);
      if (aDue && !bDue) {
        return -1;
      }
      if (!aDue && bDue) {
        return 1;
      }
      if (aDue && bDue) {
        final int byDue = a.due.compareTo(b.due);
        if (byDue != 0) {
          return byDue;
        }
      }
      final int byCreated = b.createdAt.compareTo(a.createdAt);
      if (byCreated != 0) {
        return byCreated;
      }
      return b.id.compareTo(a.id);
    });
    if (units.length > limit) {
      return units.sublist(0, limit);
    }
    return units;
  }

  /// Mature and Known units by latest `last_review` (nulls last).
  Future<List<Unit>> recentlyKnown(int limit) async {
    final List<db.Unit> rows = await _db.select(_db.units).get();
    final List<Unit> units = rows.map(_toModel).where((u) {
      final UnitStatus status = statusOf(u);
      return status == UnitStatus.mature || status == UnitStatus.known;
    }).toList();
    units.sort((a, b) {
      final DateTime? la = a.lastReview;
      final DateTime? lb = b.lastReview;
      if (la == null && lb == null) {
        return b.createdAt.compareTo(a.createdAt);
      }
      if (la == null) {
        return 1;
      }
      if (lb == null) {
        return -1;
      }
      final int byReview = lb.compareTo(la);
      if (byReview != 0) {
        return byReview;
      }
      return b.createdAt.compareTo(a.createdAt);
    });
    if (units.length > limit) {
      return units.sublist(0, limit);
    }
    return units;
  }

  List<String> _normalizeForms(List<String> forms, String key) {
    final Set<String> seen = <String>{};
    final List<String> result = [];
    for (final String form in forms) {
      final String normalized = normalizeKey(form);
      if (normalized.isEmpty || normalized == key || !seen.add(normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return result;
  }

  Unit _toModel(db.Unit row) {
    return Unit(
      id: row.id,
      text: row.unitText,
      textKey: row.textKey,
      forms: decodeForms(row.forms),
      translationRu: row.translationRu,
      description: row.description,
      knownManual: row.knownManual,
      phase: CardPhase.fromValue(row.phase),
      due: row.due.toUtc(),
      stability: row.stability,
      fsrsJson: row.fsrsJson,
      createdAt: row.createdAt.toUtc(),
      lastReview: row.lastReview?.toUtc(),
    );
  }
}
