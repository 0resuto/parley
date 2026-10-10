import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// A picked JSON file with its content already read.
class PickedJsonFile {
  const PickedJsonFile({required this.path, required this.content});

  final String path;
  final String content;
}

/// A picked CSV file with its content already read.
class PickedCsvFile {
  const PickedCsvFile({required this.path, required this.content});

  final String path;
  final String content;
}

/// Picks the import files. Behind an interface for tests.
abstract class FilePickerService {
  /// Returns the picked `.json` file, or null when the user cancels.
  ///
  /// Throws when the file cannot be read.
  Future<PickedJsonFile?> pickJsonFile();

  /// Returns the picked `.csv` file, or null when the user cancels.
  ///
  /// Throws when the file cannot be read.
  Future<PickedCsvFile?> pickCsvFile();
}

/// System file picker limited to `.json` / `.csv` files.
class SystemFilePickerService implements FilePickerService {
  @override
  Future<PickedJsonFile?> pickJsonFile() async {
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (files.isEmpty) {
      return null;
    }
    final String? path = files.single.path;
    if (path == null) {
      return null;
    }
    return PickedJsonFile(path: path, content: await File(path).readAsString());
  }

  @override
  Future<PickedCsvFile?> pickCsvFile() async {
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (files.isEmpty) {
      return null;
    }
    final String? path = files.single.path;
    if (path == null) {
      return null;
    }
    return PickedCsvFile(path: path, content: await File(path).readAsString());
  }
}
