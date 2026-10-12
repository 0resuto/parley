import 'dart:convert';
import 'dart:typed_data';

/// Field types whose payload carries a 4-byte big-endian length prefix.
const String _lengthPrefixedTypes = 'WP';

/// Types whose text carries markup that must be stripped for display.
const String _markupTypes = 'gxwh';

/// One parsed StarDict entry (SPEC 5.12).
class StarDictEntryContent {
  const StarDictEntryContent({
    required this.text,
    this.transcription,
    this.examples = const [],
  });

  /// Display meaning.
  final String text;

  /// Phonetic transcription from a `t` field, when present.
  final String? transcription;

  /// Example sentences from an xdxf `x` field, when present.
  final List<String> examples;
}

/// Extracts the display content from one StarDict entry.
///
/// [sametypesequence] lists the field types in storage order (SPEC 5.12);
/// when it is null every field is prefixed with its type byte. Returns null
/// when the entry has no text field.
StarDictEntryContent? parseStarDictEntry(
  Uint8List data,
  String? sametypesequence,
) {
  final Map<String, Uint8List> fields = {};
  if (sametypesequence != null && sametypesequence.isNotEmpty) {
    int position = 0;
    for (int i = 0; i < sametypesequence.length; i++) {
      final String type = sametypesequence[i];
      final bool isLast = i == sametypesequence.length - 1;
      position = _readField(
        data,
        position,
        type,
        terminate: !isLast,
        fields: fields,
      );
      if (position >= data.length) {
        break;
      }
    }
  } else {
    int position = 0;
    while (position < data.length) {
      final String type = String.fromCharCode(data[position]);
      position++;
      position = _readField(
        data,
        position,
        type,
        terminate: true,
        fields: fields,
      );
    }
  }
  String? text;
  for (final String type in 'mlhxgwyk'.split('')) {
    final Uint8List? bytes = fields[type];
    if (bytes == null || bytes.isEmpty) {
      continue;
    }
    final String raw = utf8.decode(bytes, allowMalformed: true);
    final String cleaned = type == 'x'
        ? _xdxfText(raw)
        : _clean(raw, markup: _markupTypes.contains(type));
    if (cleaned.isNotEmpty) {
      text = cleaned;
      break;
    }
  }
  if (text == null) {
    return null;
  }
  final Uint8List? transcriptionBytes = fields['t'];
  final String transcription = transcriptionBytes == null
      ? ''
      : _clean(
          utf8.decode(transcriptionBytes, allowMalformed: true),
          markup: false,
        );
  final Uint8List? xdxfBytes = fields['x'];
  final List<String> examples = xdxfBytes == null
      ? const []
      : _xdxfExamples(utf8.decode(xdxfBytes, allowMalformed: true));
  return StarDictEntryContent(
    text: text,
    transcription: transcription.isEmpty ? null : transcription,
    examples: examples,
  );
}

/// Prefers the xdxf `<tr>` translations over the whole stripped document.
String _xdxfText(String raw) {
  final Iterable<RegExpMatch> matches = RegExp(
    r'<tr[^>]*>(.*?)</tr>',
    dotAll: true,
  ).allMatches(raw);
  final List<String> parts = [
    for (final RegExpMatch match in matches)
      if (_clean(
        _withoutExamples(match.group(1) ?? ''),
        markup: true,
      ).isNotEmpty)
        _clean(_withoutExamples(match.group(1) ?? ''), markup: true),
  ];
  if (parts.isNotEmpty) {
    return parts.join('; ');
  }
  // The document itself is the last resort; its `<k>` headword is not a
  // meaning (A-44).
  return _clean(_withoutHeadword(raw), markup: true);
}

/// Strips `<ex>...</ex>` blocks; their text is surfaced as examples.
String _withoutExamples(String text) {
  return text.replaceAll(RegExp(r'<ex[^>]*>.*?</ex>', dotAll: true), ' ');
}

/// Strips the `<k>...</k>` headword block.
String _withoutHeadword(String text) {
  return text.replaceAll(RegExp(r'<k[^>]*>.*?</k>', dotAll: true), ' ');
}

List<String> _xdxfExamples(String raw) {
  final Iterable<RegExpMatch> matches = RegExp(
    r'<ex[^>]*>(.*?)</ex>',
    dotAll: true,
  ).allMatches(raw);
  final List<String> examples = [];
  for (final RegExpMatch match in matches) {
    final String example = _clean(match.group(1) ?? '', markup: true);
    if (example.isNotEmpty) {
      examples.add(example);
    }
  }
  return examples;
}

int _readField(
  Uint8List data,
  int position,
  String type, {
  required bool terminate,
  required Map<String, Uint8List> fields,
}) {
  if (position >= data.length) {
    return position;
  }
  if (_lengthPrefixedTypes.contains(type)) {
    // Binary payloads (WAV, pictures) carry a 4-byte big-endian length.
    if (position + 4 > data.length) {
      return data.length;
    }
    final int length =
        (data[position] << 24) |
        (data[position + 1] << 16) |
        (data[position + 2] << 8) |
        data[position + 3];
    position += 4;
    final int end = position + length > data.length
        ? data.length
        : position + length;
    fields[type] = data.sublist(position, end);
    return end;
  }
  // Every other type — known text types and unknown ones alike — is a
  // null-terminated string (A-47); only `W` and `P` are length-prefixed.
  if (terminate) {
    final int zero = data.indexOf(0, position);
    final int end = zero < 0 ? data.length : zero;
    fields[type] = data.sublist(position, end);
    return zero < 0 ? data.length : zero + 1;
  }
  fields[type] = data.sublist(position);
  return data.length;
}

String _clean(String text, {required bool markup}) {
  String result = text;
  if (markup) {
    result = result.replaceAll(RegExp(r'<[^>]*>'), ' ');
    result = result
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
  }
  return result.replaceAll(RegExp(r'\s+'), ' ').trim();
}
