import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/dictionary/dictionary_initializer.dart';
import 'package:path/path.dart' as p;

class FakeDictionaryLoader implements DictionaryAssetLoader {
  FakeDictionaryLoader(this.bytes);

  final Uint8List bytes;
  int calls = 0;

  @override
  Future<ByteData> load() async {
    calls++;
    return ByteData.sublistView(bytes);
  }
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('parley_dictionary_test');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('first call copies the bundled file', () async {
    final FakeDictionaryLoader loader = FakeDictionaryLoader(
      Uint8List.fromList(<int>[1, 2, 3]),
    );

    final File file = await ensureDictionaryFile(
      loader: loader,
      documentsDir: temp,
    );

    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), <int>[1, 2, 3]);
    expect(loader.calls, 1);
  });

  test('an existing non-empty copy is never overwritten', () async {
    final FakeDictionaryLoader first = FakeDictionaryLoader(
      Uint8List.fromList(<int>[1]),
    );
    final File file = await ensureDictionaryFile(
      loader: first,
      documentsDir: temp,
    );
    await file.writeAsBytes(<int>[7, 7, 7]);

    final FakeDictionaryLoader second = FakeDictionaryLoader(
      Uint8List.fromList(<int>[9]),
    );
    final File again = await ensureDictionaryFile(
      loader: second,
      documentsDir: temp,
    );

    expect(await again.readAsBytes(), <int>[7, 7, 7]);
    expect(second.calls, 0);
  });

  test('an older asset version replaces the existing copy', () async {
    final File target = File(
      p.join(temp.path, 'parley', 'dictionary', 'en_ru.sqlite3'),
    );
    await target.create(recursive: true);
    await target.writeAsBytes(<int>[7, 7, 7]);
    final File marker = File(
      p.join(temp.path, 'parley', 'dictionary', 'asset_version'),
    );
    await marker.writeAsString('${dictionaryAssetVersion - 1}');

    final FakeDictionaryLoader loader = FakeDictionaryLoader(
      Uint8List.fromList(<int>[9]),
    );
    final File again = await ensureDictionaryFile(
      loader: loader,
      documentsDir: temp,
    );

    expect(await again.readAsBytes(), <int>[9]);
    expect(loader.calls, 1);
    expect((await marker.readAsString()).trim(), '$dictionaryAssetVersion');
  });

  test('a legacy copy without a version marker is refreshed', () async {
    final File target = File(
      p.join(temp.path, 'parley', 'dictionary', 'en_ru.sqlite3'),
    );
    await target.create(recursive: true);
    await target.writeAsBytes(<int>[7, 7, 7]);

    final FakeDictionaryLoader loader = FakeDictionaryLoader(
      Uint8List.fromList(<int>[9]),
    );
    final File again = await ensureDictionaryFile(
      loader: loader,
      documentsDir: temp,
    );

    expect(await again.readAsBytes(), <int>[9]);
    expect(loader.calls, 1);
  });
}
