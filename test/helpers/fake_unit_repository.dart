import 'package:parley/core/clock.dart';
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/srs/srs_service.dart';

/// In-memory fake of [UnitRepository] for widget tests.
///
/// Returns single-emission streams from [watchAll] so there are no drift
/// stream subscriptions (and no pending timers) in widget tests.
/// Only the members used by the dictionary UI are implemented; the rest
/// throw [UnimplementedError].
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
      translationRu: translationRu,
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
            u.translationRu.toLowerCase().contains(needle) ||
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
      throw StateError('unit not found');
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
    // Chat prompt tests use an empty dictionary; no target words.
    return [];
  }

  @override
  Future<List<Unit>> recentlyKnown(int limit) async {
    return [];
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
