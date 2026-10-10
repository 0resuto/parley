import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Asset path of the bundled dictionary (SPEC 5.11).
const String dictionaryAssetPath = 'assets/dictionary/en_ru.sqlite3';

/// Loads the bundled dictionary bytes (testable seam).
abstract class DictionaryAssetLoader {
  Future<ByteData> load();
}

/// Loads the dictionary from the Flutter asset bundle.
class RootBundleDictionaryLoader implements DictionaryAssetLoader {
  RootBundleDictionaryLoader({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  @override
  Future<ByteData> load() => _bundle.load(dictionaryAssetPath);
}

/// Copies the bundled dictionary into `<app docs>/parley/dictionary/` once.
///
/// An existing non-empty copy is never overwritten (SPEC 5.11).
Future<File> ensureDictionaryFile({
  required DictionaryAssetLoader loader,
  Directory? documentsDir,
}) async {
  final Directory docs =
      documentsDir ?? await getApplicationDocumentsDirectory();
  final File target = File(
    p.join(docs.path, 'parley', 'dictionary', 'en_ru.sqlite3'),
  );
  if (await target.exists() && await target.length() > 0) {
    return target;
  }
  final ByteData data = await loader.load();
  await target.parent.create(recursive: true);
  await target.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    flush: true,
  );
  return target;
}
