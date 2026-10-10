import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';

/// Result of a CSV import (SPEC 4.6).
class CsvImportSummary {
  const CsvImportSummary({required this.added, required this.skipped});

  /// Units created.
  final int added;

  /// Existing duplicates skipped.
  final int skipped;

  /// Multi-line English summary for the result dialog.
  String describe() {
    return 'Added: $added\nSkipped: $skipped';
  }
}

/// CSV import per SPEC 4.6.
///
/// Delimiter `;`, UTF-8, one unit per line: `word;translation`
/// (translation optional). Empty lines and existing duplicates are
/// skipped. An optional first-line header `word;translation` is
/// ignored. No quoting support: lines are split on `;` and only the
/// first two columns are used.
class CsvImporter {
  CsvImporter({required UnitRepository units}) : _units = units;

  final UnitRepository _units;

  /// Parses [content] and adds missing units.
  Future<CsvImportSummary> importCsv(String content) async {
    final String withoutBom = content.startsWith('\uFEFF')
        ? content.substring(1)
        : content;
    final List<String> lines = withoutBom.split(RegExp(r'\r\n|\r|\n'));

    int added = 0;
    int skipped = 0;
    bool isFirstLine = true;
    for (final String rawLine in lines) {
      final String line = rawLine.trim();
      if (isFirstLine) {
        isFirstLine = false;
        if (line.toLowerCase() == 'word;translation') {
          continue;
        }
      }
      if (line.isEmpty) {
        continue;
      }
      final List<String> parts = rawLine.split(';');
      final String word = parts.first.trim();
      final String translation = parts.length > 1 ? parts[1].trim() : '';
      if (word.isEmpty || normalizeKey(word).isEmpty) {
        continue;
      }
      final Unit? existing = await _units.findByKey(word);
      if (existing != null) {
        skipped++;
        continue;
      }
      await _units.add(text: word, translationRu: translation);
      added++;
    }
    return CsvImportSummary(added: added, skipped: skipped);
  }
}
