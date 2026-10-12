import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/export/share_service.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  late Directory root;
  late Directory temp;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('parley_share_root_');
    temp = Directory('${root.path}${Platform.pathSeparator}share')
      ..createSync();
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // Best effort cleanup.
    }
  });

  group('TempFileShareService (A-37)', () {
    test('shares the file and deletes it afterwards', () async {
      String? sharedPath;
      String? contentAtShareTime;
      final TempFileShareService service = TempFileShareService(
        tempDirectory: () async => temp,
        share: (List<XFile> files) async {
          sharedPath = files.single.path;
          contentAtShareTime = await File(sharedPath!).readAsString();
        },
      );

      await service.shareJsonFile('parley-export.json', '{"a":1}');

      expect(
        sharedPath,
        '${temp.path}${Platform.pathSeparator}parley-export.json',
      );
      expect(contentAtShareTime, '{"a":1}');
      // The dump does not linger in the cache.
      expect(File(sharedPath!).existsSync(), isFalse);
    });

    test('a crafted name cannot escape the temp directory', () async {
      String? sharedPath;
      final TempFileShareService service = TempFileShareService(
        tempDirectory: () async => temp,
        share: (List<XFile> files) async {
          sharedPath = files.single.path;
        },
      );

      await service.shareJsonFile('../evil.json', 'x');

      expect(sharedPath, '${temp.path}${Platform.pathSeparator}evil.json');
      // A fresh root per test: nothing may land next to the share dir.
      expect(
        File('${root.path}${Platform.pathSeparator}evil.json').existsSync(),
        isFalse,
      );
    });

    test('the file is deleted even when sharing fails', () async {
      final TempFileShareService service = TempFileShareService(
        tempDirectory: () async => temp,
        share: (List<XFile> files) async {
          throw StateError('share sheet failed');
        },
      );

      await expectLater(
        service.shareJsonFile('parley-export.json', 'x'),
        throwsA(isA<StateError>()),
      );

      expect(temp.listSync(), isEmpty);
    });
  });
}
