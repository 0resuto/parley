/// Metadata from a StarDict `.ifo` file (SPEC 5.12).
class StarDictMetadata {
  const StarDictMetadata({
    required this.bookName,
    required this.wordCount,
    this.idxFileSize,
    this.sametypesequence,
    this.synWordCount,
  });

  final String bookName;

  final int wordCount;

  /// Expected size of the `.idx` file, when declared.
  final int? idxFileSize;

  /// Concatenated field types in which entries are stored; null means every
  /// entry starts with a type byte.
  final String? sametypesequence;

  final int? synWordCount;
}

/// Raised when a StarDict file is malformed or incomplete.
class StarDictFormatException implements Exception {
  const StarDictFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parses the text of a `.ifo` file.
///
/// Throws [StarDictFormatException] when the file is not a StarDict
/// metadata file or has no word count.
StarDictMetadata parseStarDictIfo(String content) {
  final List<String> lines = content.split(RegExp(r'\r\n|\r|\n'));
  if (lines.isEmpty || lines.first.trim() != "StarDict's dict ifo file") {
    throw const StarDictFormatException('Not a StarDict .ifo file.');
  }
  final Map<String, String> values = {};
  for (final String line in lines.skip(1)) {
    final int separator = line.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    // Keys are matched case-insensitively: some writers emit `WordCount`
    // or `BookName` (A-43).
    values[line.substring(0, separator).trim().toLowerCase()] = line
        .substring(separator + 1)
        .trim();
  }
  final int wordCount = int.tryParse(values['wordcount'] ?? '') ?? 0;
  if (wordCount <= 0) {
    throw const StarDictFormatException('The .ifo file has no word count.');
  }
  final String sample = values['sametypesequence'] ?? '';
  return StarDictMetadata(
    bookName: values['bookname'] ?? '',
    wordCount: wordCount,
    idxFileSize: int.tryParse(values['idxfilesize'] ?? ''),
    sametypesequence: sample.isEmpty ? null : sample,
    synWordCount: int.tryParse(values['synwordcount'] ?? ''),
  );
}
