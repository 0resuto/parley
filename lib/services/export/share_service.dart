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

/// Opens the system share sheet with [files].
typedef ShareFilesCallback = Future<void> Function(List<XFile> files);

/// Writes the export to the temp dir and shares it via `share_plus`.
///
/// The file name is reduced to its base name (it can never escape the
/// temp directory) and the file is deleted again after sharing, so the
/// full data dump does not linger in the cache (A-37).
class TempFileShareService implements ShareService {
  TempFileShareService({
    Future<Directory> Function()? tempDirectory,
    ShareFilesCallback? share,
  }) : _tempDirectory = tempDirectory ?? getTemporaryDirectory,
       _share = share ?? _shareViaPlugin;

  final Future<Directory> Function() _tempDirectory;
  final ShareFilesCallback _share;

  static Future<void> _shareViaPlugin(List<XFile> files) async {
    await SharePlus.instance.share(ShareParams(files: files));
  }

  @override
  Future<void> shareJsonFile(String fileName, String content) async {
    final Directory temp = await _tempDirectory();
    final File file = File(p.join(temp.path, p.basename(fileName)));
    await file.writeAsString(content, encoding: utf8);
    try {
      await _share([XFile(file.path)]);
    } finally {
      // Best-effort: a missing file needs no cleanup.
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
