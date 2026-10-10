import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart' as db;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/documents/document_store.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

/// Export envelope marker (SPEC 4.5).
const String exportFormat = 'parley-export';

/// Export envelope version (SPEC 4.5).
const int exportVersion = 1;

/// Thrown when an import file is not a valid Parley export.
class ExportFormatException implements Exception {
  const ExportFormatException(this.message);

  final String message;

  @override
  String toString() => 'ExportFormatException: $message';
}

/// Import options from the import dialog (SPEC 4.5).
class ImportOptions {
  const ImportOptions({
    this.overwriteExisting = false,
    this.replaceDocs = false,
  });

  /// When true, existing units are replaced; otherwise they are skipped.
  final bool overwriteExisting;

  /// When true, rules and notes are replaced; otherwise left untouched.
  final bool replaceDocs;
}

/// Import outcome shown in the summary dialog (SPEC 4.5).
class ImportSummary {
  const ImportSummary({
    required this.added,
    required this.skipped,
    required this.overwritten,
    required this.reviewsAdded,
    required this.docsReplaced,
  });

  final int added;
  final int skipped;
  final int overwritten;
  final int reviewsAdded;
  final bool docsReplaced;

  /// Multi-line English summary for the result dialog.
  String describe() {
    final buffer = StringBuffer()
      ..writeln('Added: $added')
      ..writeln('Skipped: $skipped')
      ..writeln('Overwritten: $overwritten')
      ..writeln('Reviews added: $reviewsAdded');
    if (docsReplaced) {
      buffer.writeln('Rules and notes replaced.');
    }
    return buffer.toString().trimRight();
  }
}

/// JSON export and import, format v1 (SPEC 4.5).
///
/// Units merge by `text_key`. Reviews link to units by unit text and are
/// always appended. Rules/notes are replaced only when [ImportOptions]
/// asks for it.
class ExportService {
  ExportService({
    required db.AppDatabase database,
    required UnitRepository units,
    required DocumentStore documents,
    required Clock clock,
  }) : _db = database,
       _units = units,
       _documents = documents,
       _clock = clock;

  final db.AppDatabase _db;
  final UnitRepository _units;
  final DocumentStore _documents;
  final Clock _clock;

  /// Export file name: `parley-export-YYYYMMDD.json` (SPEC 4.5).
  String exportFileName(DateTime now) {
    final DateTime utc = now.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'parley-export-${utc.year}${two(utc.month)}${two(utc.day)}.json';
  }

  /// Builds the full export document as a JSON string.
  Future<String> exportJson() async {
    final List<Unit> units = await _units.watchAll().first;
    final List<db.Review> reviews = await (_db.select(
      _db.reviews,
    )..orderBy([(t) => OrderingTerm(expression: t.id)])).get();
    final Map<int, String> textById = {
      for (final Unit unit in units) unit.id: unit.text,
    };
    return jsonEncode({
      'format': exportFormat,
      'version': exportVersion,
      'exported_at': _clock.now().toUtc().toIso8601String(),
      'units': [for (final Unit unit in units) _exportUnit(unit)],
      'reviews': [
        for (final db.Review review in reviews)
          if (textById.containsKey(review.unitId))
            {
              'unit_text': textById[review.unitId],
              'rating': review.rating,
              'reviewed_at': review.reviewedAt.toUtc().toIso8601String(),
              'source': review.source,
            },
      ],
      'rules': await _documents.read(DocumentKind.rules),
      'notes': await _documents.read(DocumentKind.notes),
    });
  }

  /// Parses and merges an export document, returning the summary.
  ///
  /// Throws [ExportFormatException] on invalid files.
  Future<ImportSummary> importJson(
    String source, {
    ImportOptions options = const ImportOptions(),
  }) async {
    final Map<String, dynamic> doc = _parseDocument(source);
    final List<dynamic> rawUnits = _listField(doc, 'units');
    final List<dynamic> rawReviews = _listField(doc, 'reviews');

    int added = 0;
    int skipped = 0;
    int overwritten = 0;
    final Map<String, Unit> byKey = {
      for (final Unit unit in await _units.watchAll().first) unit.textKey: unit,
    };
    for (final Object? entry in rawUnits) {
      final _UnitEntry unit = _parseUnit(entry);
      final Unit? existing = byKey[unit.key];
      if (existing == null) {
        final Unit created = await _units.add(
          text: unit.text,
          translationRu: unit.translationRu,
          description: unit.description,
          forms: unit.forms,
        );
        byKey[unit.key] = await _units.update(
          created.copyWith(
            knownManual: unit.knownManual,
            phase: unit.phase,
            due: unit.due,
            stability: unit.stability,
            fsrsJson: unit.fsrsJson,
            createdAt: unit.createdAt,
            lastReview: unit.lastReview,
          ),
        );
        added++;
      } else if (options.overwriteExisting) {
        byKey[unit.key] = await _units.update(
          existing.copyWith(
            text: unit.text,
            translationRu: unit.translationRu,
            description: unit.description,
            forms: unit.forms,
            knownManual: unit.knownManual,
            phase: unit.phase,
            due: unit.due,
            stability: unit.stability,
            fsrsJson: unit.fsrsJson,
            createdAt: unit.createdAt,
            lastReview: unit.lastReview,
          ),
        );
        overwritten++;
      } else {
        skipped++;
      }
    }

    int reviewsAdded = 0;
    for (final Object? entry in rawReviews) {
      final _ReviewEntry review = _parseReview(entry);
      final Unit? unit = byKey[review.key];
      if (unit == null) {
        continue;
      }
      await _db
          .into(_db.reviews)
          .insert(
            db.ReviewsCompanion.insert(
              unitId: unit.id,
              rating: review.rating.value,
              source: review.source.value,
              reviewedAt: review.reviewedAt,
            ),
          );
      reviewsAdded++;
    }

    bool docsReplaced = false;
    if (options.replaceDocs) {
      await _documents.write(DocumentKind.rules, _optionalString(doc, 'rules'));
      await _documents.write(DocumentKind.notes, _optionalString(doc, 'notes'));
      docsReplaced = true;
    }
    return ImportSummary(
      added: added,
      skipped: skipped,
      overwritten: overwritten,
      reviewsAdded: reviewsAdded,
      docsReplaced: docsReplaced,
    );
  }

  Map<String, dynamic> _exportUnit(Unit unit) {
    return {
      'text': unit.text,
      'forms': unit.forms,
      'translation_ru': unit.translationRu,
      'description': unit.description,
      'known_manual': unit.knownManual,
      'phase': unit.phase.value,
      'due': unit.due.toUtc().toIso8601String(),
      'fsrs': unit.fsrsJson,
      'created_at': unit.createdAt.toUtc().toIso8601String(),
      'last_review': unit.lastReview?.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> _parseDocument(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      throw const ExportFormatException('The file is not valid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ExportFormatException('The file is not a Parley export.');
    }
    if (decoded['format'] != exportFormat ||
        decoded['version'] != exportVersion) {
      throw const ExportFormatException(
        'Unsupported export format or version.',
      );
    }
    return decoded;
  }

  List<dynamic> _listField(Map<String, dynamic> doc, String key) {
    final Object? value = doc[key];
    if (value is! List) {
      throw ExportFormatException('The export has no valid "$key".');
    }
    return value;
  }

  _UnitEntry _parseUnit(Object? entry) {
    if (entry is! Map<String, dynamic>) {
      throw const ExportFormatException('The export has an invalid unit.');
    }
    final Object? rawText = entry['text'];
    if (rawText is! String || rawText.trim().isEmpty) {
      throw const ExportFormatException('The export has a unit without text.');
    }
    final String text = rawText.trim();
    final Object? rawForms = entry['forms'];
    final List<String> forms;
    if (rawForms == null) {
      forms = [];
    } else if (rawForms is List && rawForms.every((e) => e is String)) {
      forms = rawForms.cast<String>();
    } else {
      throw ExportFormatException('Unit "$text" has invalid forms.');
    }
    final Object? rawPhase = entry['phase'];
    if (rawPhase is! int) {
      throw ExportFormatException('Unit "$text" has an invalid phase.');
    }
    final CardPhase phase;
    try {
      phase = CardPhase.fromValue(rawPhase);
    } catch (_) {
      throw ExportFormatException('Unit "$text" has an invalid phase.');
    }
    final Object? rawFsrs = entry['fsrs'];
    if (rawFsrs is! String) {
      throw ExportFormatException('Unit "$text" has invalid SRS data.');
    }
    final SrsCard card;
    try {
      card = SrsCard.fromJson(rawFsrs);
    } catch (_) {
      throw ExportFormatException('Unit "$text" has invalid SRS data.');
    }
    return _UnitEntry(
      text: text,
      key: normalizeKey(text),
      forms: forms,
      translationRu: _optionalString(entry, 'translation_ru', text),
      description: _optionalDescription(entry, text),
      knownManual: _optionalBool(entry, 'known_manual', text),
      phase: phase,
      due: _requiredDate(entry, 'due', text),
      stability: card.stability,
      fsrsJson: rawFsrs,
      createdAt: _requiredDate(entry, 'created_at', text),
      lastReview: _optionalDate(entry, 'last_review', text),
    );
  }

  _ReviewEntry _parseReview(Object? entry) {
    if (entry is! Map<String, dynamic>) {
      throw const ExportFormatException('The export has an invalid review.');
    }
    const String label = 'review';
    final Object? rawText = entry['unit_text'];
    if (rawText is! String || normalizeKey(rawText).isEmpty) {
      throw const ExportFormatException(
        'The export has a review without a word.',
      );
    }
    final Object? rawRating = entry['rating'];
    if (rawRating is! int) {
      throw ExportFormatException('Invalid rating for "$rawText".');
    }
    final Rating rating;
    try {
      rating = Rating.fromValue(rawRating);
    } catch (_) {
      throw ExportFormatException('Invalid rating for "$rawText".');
    }
    final Object? rawSource = entry['source'];
    if (rawSource is! String) {
      throw ExportFormatException('Invalid source for "$rawText".');
    }
    final ReviewSource source;
    try {
      source = ReviewSource.fromValue(rawSource);
    } catch (_) {
      throw ExportFormatException('Invalid source for "$rawText".');
    }
    return _ReviewEntry(
      key: normalizeKey(rawText),
      rating: rating,
      source: source,
      reviewedAt: _requiredDate(entry, 'reviewed_at', label),
    );
  }

  String _optionalString(
    Map<String, dynamic> map,
    String key, [
    String label = '',
  ]) {
    final Object? value = map[key];
    if (value == null) {
      return '';
    }
    if (value is! String) {
      throw ExportFormatException(
        'Invalid "$key"${label.isEmpty ? '' : ' for "$label"'}.',
      );
    }
    return value;
  }

  String? _optionalDescription(Map<String, dynamic> map, String label) {
    final Object? value = map['description'];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw ExportFormatException('Unit "$label" has an invalid description.');
    }
    return value;
  }

  bool _optionalBool(Map<String, dynamic> map, String key, String label) {
    final Object? value = map[key];
    if (value == null) {
      return false;
    }
    if (value is! bool) {
      throw ExportFormatException('Unit "$label" has an invalid "$key".');
    }
    return value;
  }

  DateTime _requiredDate(Map<String, dynamic> map, String key, String label) {
    final Object? value = map[key];
    if (value is! String) {
      throw ExportFormatException('Invalid "$key" for "$label".');
    }
    try {
      return DateTime.parse(value).toUtc();
    } catch (_) {
      throw ExportFormatException('Invalid "$key" for "$label".');
    }
  }

  DateTime? _optionalDate(Map<String, dynamic> map, String key, String label) {
    final Object? value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw ExportFormatException('Invalid "$key" for "$label".');
    }
    try {
      return DateTime.parse(value).toUtc();
    } catch (_) {
      throw ExportFormatException('Invalid "$key" for "$label".');
    }
  }
}

/// Validated import payload for one unit.
class _UnitEntry {
  const _UnitEntry({
    required this.text,
    required this.key,
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

  final String text;
  final String key;
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
}

/// Validated import payload for one review.
class _ReviewEntry {
  const _ReviewEntry({
    required this.key,
    required this.rating,
    required this.source,
    required this.reviewedAt,
  });

  final String key;
  final Rating rating;
  final ReviewSource source;
  final DateTime reviewedAt;
}
