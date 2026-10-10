import 'dart:convert';

import 'package:parley/core/constants.dart';
import 'package:parley/services/srs/srs_service.dart';

/// Dictionary status, derived and never stored (SPEC 4.2).
enum UnitStatus {
  /// Phase new, not marked known.
  newUnit,

  /// Phase learning or relearning, not marked known.
  learning,

  /// Phase review with stability below the threshold.
  young,

  /// Phase review with stability at or above the threshold.
  mature,

  /// Manually marked known (excluded from cards).
  known,
}

/// Hand-written dictionary unit (SPEC 4.1).
///
/// Mirrors the `units` table. [forms] holds extra normalized keys
/// (inflections, surface forms). [textKey] is [normalizeKey(text)].
class Unit {
  const Unit({
    required this.id,
    required this.text,
    required this.textKey,
    required this.forms,
    required this.translationRu,
    required this.description,
    required this.knownManual,
    required this.phase,
    required this.due,
    required this.stability,
    required this.fsrsJson,
    required this.createdAt,
    required this.lastReview,
  });

  final int id;
  final String text;
  final String textKey;
  final List<String> forms;
  final String translationRu;
  final String? description;
  final bool knownManual;
  final CardPhase phase;
  final DateTime due;
  final double? stability;
  final String fsrsJson;
  final DateTime createdAt;
  final DateTime? lastReview;

  Unit copyWith({
    int? id,
    String? text,
    String? textKey,
    List<String>? forms,
    String? translationRu,
    String? description,
    bool? knownManual,
    CardPhase? phase,
    DateTime? due,
    double? stability,
    String? fsrsJson,
    DateTime? createdAt,
    DateTime? lastReview,
  }) {
    return Unit(
      id: id ?? this.id,
      text: text ?? this.text,
      textKey: textKey ?? this.textKey,
      forms: forms ?? this.forms,
      translationRu: translationRu ?? this.translationRu,
      description: description ?? this.description,
      knownManual: knownManual ?? this.knownManual,
      phase: phase ?? this.phase,
      due: due ?? this.due,
      stability: stability ?? this.stability,
      fsrsJson: fsrsJson ?? this.fsrsJson,
      createdAt: createdAt ?? this.createdAt,
      lastReview: lastReview ?? this.lastReview,
    );
  }

  @override
  String toString() {
    return 'Unit(id: $id, text: $text, status: ${statusOf(this)})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Unit &&
        other.id == id &&
        other.text == text &&
        other.textKey == textKey &&
        _equalLists(other.forms, forms) &&
        other.translationRu == translationRu &&
        other.description == description &&
        other.knownManual == knownManual &&
        other.phase == phase &&
        other.due == due &&
        other.stability == stability &&
        other.fsrsJson == fsrsJson &&
        other.createdAt == createdAt &&
        other.lastReview == lastReview;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      text,
      textKey,
      Object.hashAll(forms),
      translationRu,
      description,
      knownManual,
      phase,
      due,
      stability,
      fsrsJson,
      createdAt,
      lastReview,
    );
  }
}

bool _equalLists(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Normalized lookup key: lowercase, `’` to `'`, trim, collapse spaces.
String normalizeKey(String input) {
  final String apostrophes = input.replaceAll('\u2019', "'");
  final String lower = apostrophes.toLowerCase();
  final String trimmed = lower.trim();
  return trimmed.replaceAll(RegExp(r'\s+'), ' ');
}

/// Derived status per SPEC 4.2.
///
/// Review units with null stability count as [UnitStatus.young].
UnitStatus statusOf(Unit unit) {
  if (unit.knownManual) {
    return UnitStatus.known;
  }
  switch (unit.phase) {
    case CardPhase.isNew:
      return UnitStatus.newUnit;
    case CardPhase.learning:
    case CardPhase.relearning:
      return UnitStatus.learning;
    case CardPhase.review:
      final double? stability = unit.stability;
      if (stability == null || stability < youngStabilityThresholdDays) {
        return UnitStatus.young;
      }
      return UnitStatus.mature;
  }
}

/// True for New, Learning and Young (SPEC 4.2, tutor target words).
bool isTargetWord(Unit unit) {
  final UnitStatus status = statusOf(unit);
  return status == UnitStatus.newUnit ||
      status == UnitStatus.learning ||
      status == UnitStatus.young;
}

/// Decodes the `forms` column (JSON array). Invalid input gives `[]`.
List<String> decodeForms(String raw) {
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.whereType<String>().toList();
    }
    return [];
  } catch (_) {
    return [];
  }
}

/// Encodes [forms] for the `forms` column.
String encodeForms(List<String> forms) => jsonEncode(forms);
