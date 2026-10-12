import 'dart:io';

import 'package:parley/services/dictionary/dictionary_file_store.dart';

/// A [DictionaryFileStore] rooted at a test temporary directory.
class TempDictionaryFileStore implements DictionaryFileStore {
  TempDictionaryFileStore(this.rootDir);

  final Directory rootDir;

  @override
  Future<Directory> root() async => rootDir;
}
