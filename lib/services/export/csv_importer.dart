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
/// (translation optional and ignored: meanings resolve live, PLAN 19.1).
/// Empty lines and existing duplicates are skipped. An optional first-line
/// header whose first column is `word` or `text` (trimmed, case-insensitive)
/// is ignored, whatever other columns it has. No quoting support: lines are
/// split on `;` and only the first two columns are used.
///
/// The whole file is parsed first, then all new words are added in one
/// transaction (A-13): keys are preloaded with a single query instead of
/// scanning the table per line.
class CsvImporter {
  CsvImporter({required UnitRepository units}) : _units = units;

  final UnitRepository _units;

  /// Parses [content] and adds missing units.
  Future<CsvImportSummary> importCsv(String content) async {
    final String withoutBom = content.startsWith('\uFEFF')
        ? content.substring(1)
        : content;
    final List<String> lines = withoutBom.split(RegExp(r'\r\n|\r|\n'));

    final Set<String> known = await _units.allKeys();
    final List<String> toAdd = [];
    int skipped = 0;
    bool isFirstLine = true;
    for (final String rawLine in lines) {
      final String line = rawLine.trim();
      if (isFirstLine) {
        isFirstLine = false;
        // (A-58) The header is recognized by its first column name only, so
        // extra columns (`word;translation;note`) do not leak in as a word.
        final String firstColumn = line.split(';').first.trim().toLowerCase();
        if (firstColumn == 'word' || firstColumn == 'text') {
          continue;
        }
      }
      if (line.isEmpty) {
        continue;
      }
      final List<String> parts = rawLine.split(';');
      final String word = parts.first.trim();
      if (word.isEmpty || normalizeKey(word).isEmpty) {
        continue;
      }
      final String key = normalizeKey(word);
      if (known.contains(key)) {
        skipped++;
        continue;
      }
      known.add(key);
      toAdd.add(word);
    }
    await _units.addAll(toAdd);
    return CsvImportSummary(added: toAdd.length, skipped: skipped);
  }
}
