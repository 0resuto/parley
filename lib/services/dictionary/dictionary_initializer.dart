import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Asset path of the bundled dictionary (SPEC 5.11).
const String dictionaryAssetPath = 'assets/dictionary/en_ru.sqlite3';

/// Version of the bundled dictionary asset.
///
/// Bump this whenever `assets/dictionary/en_ru.sqlite3` is rebuilt so
/// installed apps replace their stale copy (SPEC 5.11).
const int dictionaryAssetVersion = 3;

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

/// Copies the bundled dictionary into `<app docs>/parley/dictionary/`.
///
/// The copy is refreshed when the shipped [dictionaryAssetVersion] changes
/// (or when no version marker exists yet); within one version an existing
/// non-empty copy is never overwritten (SPEC 5.11).
Future<File> ensureDictionaryFile({
  required DictionaryAssetLoader loader,
  Directory? documentsDir,
}) async {
  final Directory docs =
      documentsDir ?? await getApplicationDocumentsDirectory();
  final Directory dir = Directory(p.join(docs.path, 'parley', 'dictionary'));
  final File target = File(p.join(dir.path, 'en_ru.sqlite3'));
  final File marker = File(p.join(dir.path, 'asset_version'));
  if (await _isCurrentCopy(target, marker)) {
    return target;
  }
  final ByteData data = await loader.load();
  await dir.create(recursive: true);
  await target.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    flush: true,
  );
  await marker.writeAsString('$dictionaryAssetVersion', flush: true);
  return target;
}

Future<bool> _isCurrentCopy(File target, File marker) async {
  if (!await target.exists() || await target.length() == 0) {
    return false;
  }
  if (!await marker.exists()) {
    return false;
  }
  return (await marker.readAsString()).trim() == '$dictionaryAssetVersion';
}
