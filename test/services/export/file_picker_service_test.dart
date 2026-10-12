import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/export/file_picker_service.dart';

base class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile(this.name, this.path);

  @override
  final String name;

  @override
  final String? path;

  @override
  Uri get uri => Uri.file(path ?? name);

  @override
  Never get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => null;

  @override
  Future<int?> length() async => null;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}

class _FakeFilePicker extends FilePickerPlatform {
  FileType? lastType;
  List<String>? lastAllowedExtensions;
  List<PlatformFile> nextFiles = const [];

  void _record(FileType type, List<String>? allowedExtensions) {
    lastType = type;
    lastAllowedExtensions = allowedExtensions;
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    _record(type, allowedExtensions);
    return nextFiles.isEmpty ? null : nextFiles.first;
  }

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    _record(type, allowedExtensions);
    return nextFiles;
  }
}

Future<File> _writeTempFile(String name, List<int> bytes) async {
  final Directory dir = await Directory.systemTemp.createTemp('parley_picker_');
  final File file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  late FilePickerPlatform original;
  late _FakeFilePicker picker;

  setUp(() {
    original = FilePickerPlatform.instance;
    picker = _FakeFilePicker();
    FilePickerPlatform.instance = picker;
  });

  tearDown(() {
    FilePickerPlatform.instance = original;
  });

  group('SystemFilePickerService dictionary picker', () {
    test('offers every supported dictionary format', () async {
      final List<String>? paths = await SystemFilePickerService()
          .pickDictionaryFiles();

      expect(paths, isNull);
      expect(picker.lastType, FileType.custom);
      expect(
        picker.lastAllowedExtensions,
        unorderedEquals(<String>[
          'ifo',
          'idx',
          'dict',
          'dz',
          'syn',
          'zip',
          'dsl',
        ]),
      );
    });

    test('returns the picked file paths', () async {
      picker.nextFiles = [
        _FakePlatformFile('testdict.ifo', '/dicts/testdict.ifo'),
        _FakePlatformFile('testdict.idx', '/dicts/testdict.idx'),
        _FakePlatformFile('testdict.dict', '/dicts/testdict.dict'),
      ];

      final List<String>? paths = await SystemFilePickerService()
          .pickDictionaryFiles();

      expect(paths, [
        '/dicts/testdict.ifo',
        '/dicts/testdict.idx',
        '/dicts/testdict.dict',
      ]);
    });

    test('drops picked files without a local path', () async {
      picker.nextFiles = [
        _FakePlatformFile('testdict.ifo', '/dicts/testdict.ifo'),
        _FakePlatformFile('remote.ifo', null),
        _FakePlatformFile('testdict.dict', '/dicts/testdict.dict'),
      ];

      expect(await SystemFilePickerService().pickDictionaryFiles(), [
        '/dicts/testdict.ifo',
        '/dicts/testdict.dict',
      ]);
    });
  });

  group('SystemFilePickerService import picker', () {
    test('uses the first file when the platform lists several', () async {
      final File first = await _writeTempFile('first.json', const [0x61]);
      addTearDown(() => first.parent.delete(recursive: true));
      picker.nextFiles = [
        _FakePlatformFile('first.json', first.path),
        _FakePlatformFile('second.json', '/missing/second.json'),
      ];

      final PickedJsonFile? picked = await SystemFilePickerService()
          .pickJsonFile();

      expect(picked, isNotNull);
      expect(picked!.path, first.path);
      expect(picked.content, 'a');
    });

    test('decodes Windows-1251 CSV content', () async {
      final File file = await _writeTempFile('legacy.csv', const [
        0xF1, 0xEB, 0xEE, 0xE2, 0xEE, 0x3B, // слово;
        0xEF, 0xE5, 0xF0, 0xE5, 0xE2, 0xEE, 0xE4, // перевод
      ]);
      addTearDown(() => file.parent.delete(recursive: true));
      picker.nextFiles = [_FakePlatformFile('legacy.csv', file.path)];

      final PickedCsvFile? picked = await SystemFilePickerService()
          .pickCsvFile();

      expect(picked, isNotNull);
      expect(picked!.content, 'слово;перевод');
    });

    test('decodes Windows-1251 special letters', () async {
      final File file = await _writeTempFile('specials.csv', const [
        0xA8, 0x3B, 0xB8, // Ё;ё
      ]);
      addTearDown(() => file.parent.delete(recursive: true));
      picker.nextFiles = [_FakePlatformFile('specials.csv', file.path)];

      final PickedCsvFile? picked = await SystemFilePickerService()
          .pickCsvFile();

      expect(picked!.content, 'Ё;ё');
    });

    test('strips a UTF-8 BOM from UTF-8 content', () async {
      final File file = await _writeTempFile('bom.csv', const [
        0xEF, 0xBB, 0xBF, 0x61, 0x3B, 0x62, // BOM + a;b
      ]);
      addTearDown(() => file.parent.delete(recursive: true));
      picker.nextFiles = [_FakePlatformFile('bom.csv', file.path)];

      final PickedCsvFile? picked = await SystemFilePickerService()
          .pickCsvFile();

      expect(picked!.content, 'a;b');
    });
  });
}
