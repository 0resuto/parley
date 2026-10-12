import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Root directory of the imported dictionary files (SPEC 5.12).
///
/// Behind an interface so tests can point at a temporary directory.
abstract class DictionaryFileStore {
  /// Returns `<app documents>/parley/dictionaries/` (created on demand by
  /// the importer, not by this call).
  Future<Directory> root();
}

/// App-documents implementation used on the device.
class AppDocumentsDictionaryFileStore implements DictionaryFileStore {
  @override
  Future<Directory> root() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return Directory(p.join(documents.path, 'parley', 'dictionaries'));
  }
}
