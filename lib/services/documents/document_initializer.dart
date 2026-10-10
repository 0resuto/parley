import 'package:flutter/services.dart';

import 'package:parley/services/documents/document_store.dart';

/// Loads the bundled template text for a document kind.
abstract class TemplateLoader {
  Future<String> load(DocumentKind kind);
}

/// Loads `assets/templates/rules.md` and `notes.md` via an [AssetBundle].
class AssetTemplateLoader implements TemplateLoader {
  AssetTemplateLoader({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  @override
  Future<String> load(DocumentKind kind) {
    return _bundle.loadString('assets/templates/${kind.fileName}');
  }
}

/// Copies bundled templates into the store on first launch (SPEC 4.4).
///
/// Each kind is copied only when the store currently reads empty;
/// existing (non-empty) files are never overwritten.
Future<void> ensureDefaultDocuments({
  required DocumentStore store,
  required TemplateLoader templates,
}) async {
  for (final DocumentKind kind in DocumentKind.values) {
    final String current = await store.read(kind);
    if (current.isNotEmpty) {
      continue;
    }
    final String template = await templates.load(kind);
    if (template.isEmpty) {
      continue;
    }
    await store.write(kind, template);
  }
}
