import 'package:parley/core/clock.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/srs/srs_service.dart';

/// In-memory fake of [UnitRepository] for widget tests.
///
/// Mirrors the real repository's behavior (same filters and ordering),
/// keeping state in a plain list. Returns single-emission streams from
/// [watchAll] so there are no drift stream subscriptions (and no pending
/// timers) in widget tests.
class FakeUnitRepository implements UnitRepository {
  FakeUnitRepository({required Clock clock, SrsService? srs})
    : _clock = clock,
      _srs = srs ?? SrsService();

  final Clock _clock;
  final SrsService _srs;
  final List<Unit> _units = [];
  int _nextId = 1;

  @override
  Future<Unit> add({
    required String text,
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
    if (_units.any((u) => u.textKey == key)) {
      throw StateError('duplicate text_key');
    }
    final DateTime now = _clock.now().toUtc();
    final SrsCard card = _srs.newCard(now);
    final Unit unit = Unit(
      id: _nextId++,
      text: trimmed,
      textKey: key,
      forms: _normalizeForms(forms, key),
      description: description,
      knownManual: false,
      phase: card.phase,
      due: card.due,
      stability: card.stability,
      fsrsJson: card.toJson(),
      createdAt: now,
      lastReview: null,
    );
    _units.add(unit);
    return unit;
  }

  @override
  Future<List<Unit>> addAll(List<String> texts) async {
    final List<Unit> created = [];
    for (final String text in texts) {
      created.add(await add(text: text));
    }
    return created;
  }

  @override
  Future<Set<String>> allKeys() async {
    final Set<String> keys = <String>{};
    for (final Unit unit in _units) {
      keys.add(unit.textKey);
      keys.addAll(unit.forms);
    }
    return keys;
  }

  @override
  Future<Unit?> getById(int id) async {
    for (final Unit unit in _units) {
      if (unit.id == id) {
        return unit;
      }
    }
    return null;
  }

  @override
  Future<Unit?> setKnown(int id, bool known) async {
    final int index = _units.indexWhere((u) => u.id == id);
    if (index == -1) {
      return null;
    }
    _units[index] = _units[index].copyWith(knownManual: known);
    return _units[index];
  }

  @override
  Stream<List<Unit>> watchAll({UnitStatus? status, String? query}) {
    final List<Unit> sorted = _units.toList()
      ..sort((a, b) {
        final int byCreated = b.createdAt.compareTo(a.createdAt);
        if (byCreated != 0) {
          return byCreated;
        }
        return b.id.compareTo(a.id);
      });
    Iterable<Unit> units = sorted;
    if (status != null) {
      units = units.where((u) => statusOf(u) == status);
    }
    final String needle = (query ?? '').trim().toLowerCase();
    if (needle.isNotEmpty) {
      final String normNeedle = normalizeKey(needle);
      units = units.where(
        (u) =>
            u.text.toLowerCase().contains(needle) ||
            u.textKey.contains(normNeedle),
      );
    }
    return Stream.value(units.toList());
  }

  @override
  Future<Unit?> findByKey(String query) async {
    final String key = normalizeKey(query);
    if (key.isEmpty) {
      return null;
    }
    for (final Unit unit in _units) {
      if (unit.textKey == key) {
        return unit;
      }
    }
    for (final Unit unit in _units) {
      if (unit.forms.contains(key)) {
        return unit;
      }
    }
    return null;
  }

  @override
  Future<Unit> update(Unit unit) async {
    final int index = _units.indexWhere((u) => u.id == unit.id);
    if (index == -1) {
      throw ArgumentError('unit not found');
    }
    final String trimmed = unit.text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('text is required');
    }
    final String key = normalizeKey(trimmed);
    if (key.isEmpty) {
      throw ArgumentError('text is required');
    }
    if (_units.any((u) => u.id != unit.id && u.textKey == key)) {
      throw StateError('duplicate text_key');
    }
    final Unit updated = unit.copyWith(
      text: trimmed,
      textKey: key,
      forms: _normalizeForms(unit.forms, key),
    );
    _units[index] = updated;
    return updated;
  }

  @override
  Future<Unit> updateWord(int id, {required String text}) async {
    final int index = _units.indexWhere((u) => u.id == id);
    if (index == -1) {
      throw ArgumentError('unit not found');
    }
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('text is required');
    }
    final String key = normalizeKey(trimmed);
    if (key.isEmpty) {
      throw ArgumentError('text is required');
    }
    if (_units.any((u) => u.id != id && u.textKey == key)) {
      throw StateError('duplicate text_key');
    }
    final Unit current = _units[index];
    final Unit updated = current.copyWith(
      text: trimmed,
      textKey: key,
      forms: _normalizeForms(current.forms, key),
    );
    _units[index] = updated;
    return updated;
  }

  @override
  Future<void> delete(int id) async {
    _units.removeWhere((u) => u.id == id);
  }

  @override
  Future<List<Unit>> dueQueue(DateTime now) async {
    final DateTime utc = now.toUtc();
    final List<Unit> queue =
        _units.where((u) => !u.knownManual && !u.due.isAfter(utc)).toList()
          ..sort((a, b) {
            final int byDue = a.due.compareTo(b.due);
            if (byDue != 0) {
              return byDue;
            }
            return a.id.compareTo(b.id);
          });
    return queue;
  }

  @override
  Future<List<Unit>> targetWords(int limit, DateTime now) async {
    final DateTime utc = now.toUtc();
    final List<Unit> units = _units
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

  @override
  Future<List<Unit>> recentlyKnown(int limit) async {
    final List<Unit> units = _units.where((u) {
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
}
