import 'dart:convert';
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

  /// Returns the picked StarDict file paths of one dictionary (the `.ifo`
  /// plus its siblings), or null when the user cancels.
  ///
  /// Throws when the files cannot be read.
  Future<List<String>?> pickDictionaryFiles();
}

/// Extensions accepted by the dictionary picker (SPEC 5.12): the files of
/// one StarDict dictionary, a single `.zip` archive with them, or a `.dsl`.
const List<String> _dictionaryExtensions = [
  'ifo',
  'idx',
  'dict',
  'dz',
  'syn',
  'zip',
  'dsl',
];

/// System file picker limited to `.json` / `.csv` files.
class SystemFilePickerService implements FilePickerService {
  @override
  Future<PickedJsonFile?> pickJsonFile() async {
    // (A-60) pickFile() is the single-file API; pickFiles() is multi-select.
    final PlatformFile? file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final String? path = file?.path;
    if (path == null) {
      return null;
    }
    return PickedJsonFile(path: path, content: await _readTextFile(path));
  }

  @override
  Future<PickedCsvFile?> pickCsvFile() async {
    // (A-60) pickFile() is the single-file API; pickFiles() is multi-select.
    final PlatformFile? file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    final String? path = file?.path;
    if (path == null) {
      return null;
    }
    return PickedCsvFile(path: path, content: await _readTextFile(path));
  }

  @override
  Future<List<String>?> pickDictionaryFiles() async {
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _dictionaryExtensions,
    );
    final List<String> paths = [
      for (final PlatformFile file in files)
        if (file.path != null) file.path!,
    ];
    if (paths.isEmpty) {
      return null;
    }
    return paths;
  }
}

// (A-61)
/// Reads [path] as text, trying UTF-8 first and falling back to Windows-1251
/// for files exported with a legacy Russian encoding.
Future<String> _readTextFile(String path) async {
  final List<int> bytes = await File(path).readAsBytes();
  final List<int> content = _stripUtf8Bom(bytes);
  try {
    return utf8.decode(content);
  } on FormatException {
    return _decodeWindows1251(content);
  }
}

/// Drops a leading UTF-8 byte order mark so it does not leak into the text.
List<int> _stripUtf8Bom(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return bytes.sublist(3);
  }
  return bytes;
}

/// Decodes [bytes] as Windows-1251.
///
/// Bytes 0x00-0x7F are ASCII and 0xC0-0xFF map linearly to U+0410-U+044F
/// (the Russian А-я block); the remaining positions use [_cp1251Specials].
String _decodeWindows1251(List<int> bytes) {
  final StringBuffer text = StringBuffer();
  for (final int byte in bytes) {
    if (byte < 0x80) {
      text.writeCharCode(byte);
    } else if (byte >= 0xC0) {
      text.writeCharCode(0x0410 + byte - 0xC0);
    } else {
      text.writeCharCode(_cp1251Specials[byte]!);
    }
  }
  return text.toString();
}

/// Windows-1251 code points for bytes 0x80-0xBF. Byte 0x98 is undefined in
/// the standard, so it maps to U+0098 like most decoders do.
const Map<int, int> _cp1251Specials = {
  0x80: 0x0402, // Ђ
  0x81: 0x0403, // Ѓ
  0x82: 0x201A, // ‚
  0x83: 0x0453, // ѓ
  0x84: 0x201E, // „
  0x85: 0x2026, // …
  0x86: 0x2020, // †
  0x87: 0x2021, // ‡
  0x88: 0x20AC, // €
  0x89: 0x2030, // ‰
  0x8A: 0x0409, // Љ
  0x8B: 0x2039, // ‹
  0x8C: 0x040A, // Њ
  0x8D: 0x040C, // Ќ
  0x8E: 0x040B, // Ћ
  0x8F: 0x040F, // Џ
  0x90: 0x0452, // ђ
  0x91: 0x2018, // ‘
  0x92: 0x2019, // ’
  0x93: 0x201C, // “
  0x94: 0x201D, // ”
  0x95: 0x2022, // •
  0x96: 0x2013, // –
  0x97: 0x2014, // —
  0x98: 0x0098,
  0x99: 0x2122, // ™
  0x9A: 0x0459, // љ
  0x9B: 0x203A, // ›
  0x9C: 0x045A, // њ
  0x9D: 0x045C, // ќ
  0x9E: 0x045B, // ћ
  0x9F: 0x045F, // џ
  0xA0: 0x00A0,
  0xA1: 0x040E, // Ў
  0xA2: 0x045E, // ў
  0xA3: 0x0408, // Ј
  0xA4: 0x00A4, // ¤
  0xA5: 0x0490, // Ґ
  0xA6: 0x00A6, // ¦
  0xA7: 0x00A7, // §
  0xA8: 0x0401, // Ё
  0xA9: 0x00A9, // ©
  0xAA: 0x0404, // Є
  0xAB: 0x00AB, // «
  0xAC: 0x00AC, // ¬
  0xAD: 0x00AD,
  0xAE: 0x00AE, // ®
  0xAF: 0x0407, // Ї
  0xB0: 0x00B0, // °
  0xB1: 0x00B1, // ±
  0xB2: 0x0406, // І
  0xB3: 0x0456, // і
  0xB4: 0x0491, // ґ
  0xB5: 0x00B5, // µ
  0xB6: 0x00B6, // ¶
  0xB7: 0x00B7, // ·
  0xB8: 0x0451, // ё
  0xB9: 0x2116, // №
  0xBA: 0x0454, // є
  0xBB: 0x00BB, // »
  0xBC: 0x0458, // ј
  0xBD: 0x0405, // Ѕ
  0xBE: 0x0455, // ѕ
  0xBF: 0x00BF, // ¿
};
