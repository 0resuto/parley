import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One DSL card (SPEC 5.12).
class DslEntry {
  const DslEntry({
    required this.word,
    required this.translation,
    this.transcription,
  });

  final String word;
  final String translation;
  final String? transcription;
}

/// Streams the cards of an ABBYY Lingvo `.dsl` file.
///
/// Handles UTF-16LE/BE and UTF-8 (BOM-detected, UTF-8 assumed otherwise);
/// only the first card per headword is stored by the caller, so later cards
/// are still streamed but ignored on insert. [onProgress] receives the
/// fraction of bytes read.
Stream<DslEntry> parseDsl(
  File file, {
  void Function(double fraction)? onProgress,
}) async* {
  final RandomAccessFile handle = await file.open();
  final int length = await handle.length();
  try {
    final Uint8List head = await handle.read(3);
    bool utf16le = false;
    bool utf16be = false;
    int offset = 0;
    if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xFE) {
      utf16le = true;
      offset = 2;
    } else if (head.length >= 2 && head[0] == 0xFE && head[1] == 0xFF) {
      utf16be = true;
      offset = 2;
    } else if (head.length >= 3 &&
        head[0] == 0xEF &&
        head[1] == 0xBB &&
        head[2] == 0xBF) {
      offset = 3;
    }
    final _DslState state = _DslState();
    if (utf16le || utf16be) {
      await handle.setPosition(offset);
      final List<int> carry = [];
      int processed = offset;
      int pendingHigh = -1;
      while (true) {
        final Uint8List chunk = await handle.read(1 << 16);
        if (chunk.isEmpty) {
          break;
        }
        carry.addAll(chunk);
        int i = 0;
        while (i + 1 < carry.length) {
          final int unit = utf16le
              ? carry[i] | (carry[i + 1] << 8)
              : (carry[i] << 8) | carry[i + 1];
          i += 2;
          if (pendingHigh >= 0) {
            if (unit >= 0xDC00 && unit <= 0xDFFF) {
              final DslEntry? entry = state.acceptCharacter(
                String.fromCharCodes([pendingHigh, unit]),
              );
              pendingHigh = -1;
              if (entry != null) {
                yield entry;
              }
              continue;
            }
            final DslEntry? entry = state.acceptCharacter(
              String.fromCharCode(pendingHigh),
            );
            pendingHigh = -1;
            if (entry != null) {
              yield entry;
            }
          }
          if (unit >= 0xD800 && unit <= 0xDBFF) {
            pendingHigh = unit;
            continue;
          }
          final DslEntry? entry = state.acceptCharacter(
            String.fromCharCode(unit),
          );
          if (entry != null) {
            yield entry;
          }
        }
        carry.removeRange(0, i);
        processed += chunk.length;
        onProgress?.call(length == 0 ? 1 : processed / length);
      }
    } else {
      await for (final String chunk
          in file.openRead(offset).transform(utf8.decoder)) {
        for (int i = 0; i < chunk.length; i++) {
          final DslEntry? entry = state.acceptCharacter(
            chunk.substring(i, i + 1),
          );
          if (entry != null) {
            yield entry;
          }
        }
      }
      onProgress?.call(1);
    }
    final DslEntry? last = state.finish();
    if (last != null) {
      yield last;
    }
  } finally {
    await handle.close();
  }
}

/// Line-oriented card state machine.
class _DslState {
  final StringBuffer _line = StringBuffer();
  final StringBuffer _definition = StringBuffer();
  String? _word;
  String? _transcription;
  bool _inCard = false;
  bool _pendingCr = false; // A \r may pair with \n or end a line (T-10).

  DslEntry? acceptCharacter(String character) {
    if (_pendingCr) {
      _pendingCr = false;
      final DslEntry? entry = _endLine();
      if (character == '\r') {
        _pendingCr = true;
      } else if (character != '\n') {
        _line.write(character);
      }
      return entry;
    }
    if (character == '\r') {
      _pendingCr = true;
      return null;
    }
    if (character == '\n') {
      return _endLine();
    }
    _line.write(character);
    return null;
  }

  DslEntry? finish() {
    if (!_pendingCr) {
      return _finishCard();
    }
    _pendingCr = false;
    return _endLine() ?? _finishCard();
  }

  DslEntry? _endLine() {
    final String line = _line.toString();
    _line.clear();
    return _acceptLine(line);
  }

  DslEntry? _acceptLine(String line) {
    if (line.startsWith('#')) {
      return null;
    }
    if (line.trim().isEmpty) {
      return _finishCard();
    }
    // Definitions are indented; accept a tab or spaces (A-42).
    final String indented = line.trimLeft();
    if (indented != line) {
      if (!_inCard) {
        return null;
      }
      final String cleaned = cleanDslText(indented);
      if (cleaned.isNotEmpty) {
        if (_definition.isNotEmpty) {
          _definition.write(' ');
        }
        _definition.write(cleaned);
      }
      return null;
    }
    final DslEntry? previous = _finishCard();
    final ({String word, String? transcription}) head = parseDslHeadword(line);
    _word = head.word.isEmpty ? null : head.word;
    _transcription = head.transcription;
    _inCard = _word != null;
    return previous;
  }

  DslEntry? _finishCard() {
    final String? word = _word;
    final String? transcription = _transcription;
    final String definition = _definition.toString().trim();
    _inCard = false;
    _word = null;
    _transcription = null;
    _definition.clear();
    if (word == null || definition.isEmpty) {
      return null;
    }
    return DslEntry(
      word: word,
      translation: definition,
      transcription: transcription,
    );
  }
}

/// Splits a headword line into the word and its `[transcription]`.
({String word, String? transcription}) parseDslHeadword(String line) {
  final RegExpMatch? match = RegExp(r'\[([^\]]+)\]').firstMatch(line);
  final String transcription = match?.group(1)?.trim() ?? '';
  String word = line.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  word = word.replaceAll(RegExp(r'\{[^}]*\}'), ' ');
  word = word.replaceAll('<<', ' ').replaceAll('>>', ' ');
  word = word.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (
    word: word,
    transcription: transcription.isEmpty ? null : transcription,
  );
}

/// Strips DSL markup from a definition line.
String cleanDslText(String text) {
  String result = text;
  result = result.replaceAll(RegExp(r'\{[^}]*\}'), ' ');
  result = result.replaceAll(RegExp(r'\[com\][\s\S]*?\[/com\]'), ' ');
  result = result.replaceAllMapped(
    RegExp(
      r'\[(?:ex|ref|url|trs|!trs|lang|s)\]([\s\S]*?)\[/(?:ex|ref|url|trs|!trs|lang|s)\]',
    ),
    (Match m) => m[1]!,
  );
  result = result.replaceAll(RegExp(r'\[trn\][\s\S]*?\[/trn\]'), ' ');
  result = result.replaceAll(RegExp(r'\[/?(?:m|f|p|c|i|b|u|\*|t)\]'), ' ');
  result = result.replaceAllMapped(
    RegExp(r'<<([\s\S]*?)>>'),
    (Match m) => m[1]!,
  );
  result = result.replaceAll(RegExp(r'\[[a-z!*]{1,10}\]'), ' ');
  result = result.replaceAllMapped(RegExp(r'\\(.)'), (Match m) => m[1]!);
  return result.replaceAll(RegExp(r'\s+'), ' ').trim();
}
