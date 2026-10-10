import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Shares the export JSON file. Behind an interface for tests.
abstract class ShareService {
  /// Writes [content] to [fileName] in temp storage and opens the share sheet.
  Future<void> shareJsonFile(String fileName, String content);
}

/// Writes the export to the temp dir and shares it via `share_plus`.
class TempFileShareService implements ShareService {
  @override
  Future<void> shareJsonFile(String fileName, String content) async {
    final Directory temp = await getTemporaryDirectory();
    final File file = File(p.join(temp.path, fileName));
    await file.writeAsString(content, encoding: utf8);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }
}
