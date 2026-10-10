import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/services/documents/document_store.dart';

/// File-backed documents in `<app docs>/parley/` (SPEC 4.4).
///
/// Layout: `rules.md`, `notes.md`, `history/rules_<ts>.md`,
/// `history/notes_<ts>.md`. Timestamps come from [Clock], never
/// `DateTime.now()`, so tests stay deterministic.
class FileDocumentStore implements DocumentStore {
  FileDocumentStore({required Directory baseDir, required Clock clock})
    : _baseDir = baseDir,
      _clock = clock;

  final Directory _baseDir;
  final Clock _clock;

  File _file(DocumentKind kind) => File(p.join(_baseDir.path, kind.fileName));

  Directory get _historyDir => Directory(p.join(_baseDir.path, 'history'));

  @override
  Future<String> read(DocumentKind kind) async {
    final File file = _file(kind);
    if (!await file.exists()) {
      return '';
    }
    return file.readAsString();
  }

  @override
  Future<void> write(DocumentKind kind, String text) async {
    final File file = _file(kind);
    if (await file.exists()) {
      final String previous = await file.readAsString();
      await _historyDir.create(recursive: true);
      final DateTime now = _clock.now().toUtc();
      final File target = await _uniqueHistoryFile(kind, now);
      await target.writeAsString(previous);
      await _prune(kind);
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  @override
  Future<List<DocumentVersion>> versions(DocumentKind kind) async {
    final Directory dir = _historyDir;
    if (!await dir.exists()) {
      return [];
    }
    final List<FileSystemEntity> entries = await dir.list().toList();
    final List<DocumentVersion> out = [];
    for (final FileSystemEntity entry in entries) {
      if (entry is! File) {
        continue;
      }
      final String name = p.basename(entry.path);
      if (!name.startsWith(kind.historyPrefix) || !name.endsWith('.md')) {
        continue;
      }
      final DateTime createdAt =
          _parseTimestamp(kind, name) ?? await _fallbackModified(entry);
      out.add(
        DocumentVersion(
          id: name,
          createdAt: createdAt,
          text: await entry.readAsString(),
        ),
      );
    }
    out.sort((a, b) {
      final int byTime = b.createdAt.compareTo(a.createdAt);
      if (byTime != 0) {
        return byTime;
      }
      return b.id.compareTo(a.id);
    });
    return out;
  }

  @override
  Future<void> restore(DocumentKind kind, String versionId) async {
    if (!versionId.startsWith(kind.historyPrefix)) {
      throw ArgumentError('Version not found: $versionId');
    }
    final File source = File(p.join(_historyDir.path, versionId));
    if (!await source.exists()) {
      throw ArgumentError('Version not found: $versionId');
    }
    await write(kind, await source.readAsString());
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

  Future<File> _uniqueHistoryFile(DocumentKind kind, DateTime now) async {
    final int millis = now.millisecondsSinceEpoch;
    File candidate = File(
      p.join(_historyDir.path, '${kind.historyPrefix}$millis.md'),
    );
    int counter = 1;
    while (await candidate.exists()) {
      candidate = File(
        p.join(_historyDir.path, '${kind.historyPrefix}${millis}_$counter.md'),
      );
      counter++;
    }
    return candidate;
  }

  DateTime? _parseTimestamp(DocumentKind kind, String fileName) {
    try {
      String core = fileName.substring(
        kind.historyPrefix.length,
        fileName.length - '.md'.length,
      );
      final int cut = core.indexOf('_');
      if (cut >= 0) {
        core = core.substring(0, cut);
      }
      final int? millis = int.tryParse(core);
      if (millis == null) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  Future<DateTime> _fallbackModified(File file) async {
    try {
      return (await file.stat()).modified.toUtc();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }

  Future<void> _prune(DocumentKind kind) async {
    final List<DocumentVersion> all = await versions(kind);
    if (all.length <= historyVersionsKept) {
      return;
    }
    for (final DocumentVersion version in all.skip(historyVersionsKept)) {
      try {
        await File(p.join(_historyDir.path, version.id)).delete();
      } catch (_) {
        // Best effort: a missing file needs no cleanup.
      }
    }
  }
}

/// Creates a file store in `<app documents>/parley/` (SPEC 4.4).
Future<FileDocumentStore> createFileDocumentStore(Clock clock) async {
  final Directory docs = await getApplicationDocumentsDirectory();
  return FileDocumentStore(
    baseDir: Directory(p.join(docs.path, 'parley')),
    clock: clock,
  );
}
