import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';

/// Tutor documents (SPEC 4.4): rules and notes.
enum DocumentKind {
  /// Tutor rules, edited only by the user.
  rules,

  /// Tutor memory, updated automatically.
  notes;

  /// File name under the app documents dir (SPEC 4.4).
  String get fileName {
    switch (this) {
      case DocumentKind.rules:
        return 'rules.md';
      case DocumentKind.notes:
        return 'notes.md';
    }
  }

  /// History file prefix, e.g. `rules_` for `history/rules_<ts>.md`.
  String get historyPrefix {
    switch (this) {
      case DocumentKind.rules:
        return 'rules_';
      case DocumentKind.notes:
        return 'notes_';
    }
  }
}

/// One saved previous version of a document.
class DocumentVersion {
  const DocumentVersion({
    required this.id,
    required this.createdAt,
    required this.text,
  });

  /// File name in `history/`, also used as the version id.
  final String id;

  /// When the version was saved (from [Clock], UTC).
  final DateTime createdAt;

  /// Full previous document text.
  final String text;

  /// Short single-line preview for history lists.
  String get preview {
    final String single = text.replaceAll('\n', ' ').trim();
    if (single.length <= 120) {
      return single;
    }
    return single.substring(0, 120);
  }
}

/// Reads and writes tutor documents with version history.
abstract class DocumentStore {
  /// Returns the current document text (empty when missing).
  Future<String> read(DocumentKind kind);

  /// Replaces the document text, saving the previous content to
  /// `history/` first (when a previous file exists).
  Future<void> write(DocumentKind kind, String text);

  /// Previous versions, newest first.
  Future<List<DocumentVersion>> versions(DocumentKind kind);

  /// Restores a version by [DocumentVersion.id].
  ///
  /// The current text is versioned first, so restore is itself undoable.
  /// Throws [ArgumentError] when the version does not exist.
  Future<void> restore(DocumentKind kind, String versionId);

  /// Character limit for the document (SPEC 4.4).
  int limitFor(DocumentKind kind);
}

/// In-memory documents.
///
/// Used in tests, and as the production stand-in until the file
/// implementation is wired in. Mirrors [FileDocumentStore] behaviour:
/// the first write creates no version; later writes version the
/// previous text; only the last 20 versions are kept.
class MemoryDocumentStore implements DocumentStore {
  MemoryDocumentStore({String rules = '', String notes = '', Clock? clock})
    : _clock = clock ?? const SystemClock(),
      _texts = {DocumentKind.rules: rules, DocumentKind.notes: notes},
      _exists = {
        if (rules.isNotEmpty) DocumentKind.rules,
        if (notes.isNotEmpty) DocumentKind.notes,
      },
      _history = {
        DocumentKind.rules: <DocumentVersion>[],
        DocumentKind.notes: <DocumentVersion>[],
      };

  final Clock _clock;
  final Map<DocumentKind, String> _texts;
  final Set<DocumentKind> _exists;
  final Map<DocumentKind, List<DocumentVersion>> _history;

  @override
  Future<String> read(DocumentKind kind) async => _texts[kind] ?? '';

  @override
  Future<void> write(DocumentKind kind, String text) async {
    if (_exists.contains(kind)) {
      final DateTime now = _clock.now().toUtc();
      _history[kind]!.insert(
        0,
        DocumentVersion(
          id: _uniqueId(kind, now),
          createdAt: now,
          text: _texts[kind] ?? '',
        ),
      );
      while (_history[kind]!.length > historyVersionsKept) {
        _history[kind]!.removeLast();
      }
    }
    _texts[kind] = text;
    _exists.add(kind);
  }

  @override
  Future<List<DocumentVersion>> versions(DocumentKind kind) async =>
      List<DocumentVersion>.unmodifiable(_history[kind]!);

  @override
  Future<void> restore(DocumentKind kind, String versionId) async {
    final List<DocumentVersion> list = _history[kind]!;
    final int index = list.indexWhere((v) => v.id == versionId);
    if (index < 0) {
      throw ArgumentError('Version not found: $versionId');
    }
    await write(kind, list[index].text);
  }

  @override
  int limitFor(DocumentKind kind) {
    switch (kind) {
      case DocumentKind.rules:
        return rulesLimit;
      case DocumentKind.notes:
        return notesLimit;
    }
  }

  String _uniqueId(DocumentKind kind, DateTime now) {
    final int millis = now.millisecondsSinceEpoch;
    String candidate = '${kind.historyPrefix}$millis.md';
    final Set<String> taken = {for (final v in _history[kind]!) v.id};
    int counter = 1;
    while (taken.contains(candidate)) {
      candidate = '${kind.historyPrefix}${millis}_$counter.md';
      counter++;
    }
    return candidate;
  }
}
