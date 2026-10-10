import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/data/models/unit.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';

/// Words match `[A-Za-z]+(?:['’-][A-Za-z]+)*` (SPEC 5.4).
///
/// The class covers `'`, `’` (U+2019) and `-`.
final RegExp wordRegExp = RegExp("([A-Za-z]+(?:['’\\-][A-Za-z]+)*)");

/// `[[word]]` markers are stripped from display (and TTS).
final RegExp markerRegExp = RegExp(r'\[\[([^\[\]]+?)\]\]');

/// Lookup index for chat rendering (PLAN 6.5).
///
/// Maps normalized keys to units, including `forms`. Phrase units (keys
/// with spaces) are also kept in [phrases] for token-sequence matching.
class UnitIndex {
  UnitIndex._(this.byKey, this.phrases, this.maxPhraseWords);

  /// Builds the index from a unit list (e.g. from `watchAll`).
  factory UnitIndex.fromUnits(List<Unit> units) {
    final Map<String, Unit> byKey = <String, Unit>{};
    final Map<String, Unit> phrases = <String, Unit>{};
    int maxWords = 1;
    for (final Unit unit in units) {
      byKey.putIfAbsent(unit.textKey, () => unit);
      if (unit.textKey.contains(' ')) {
        phrases.putIfAbsent(unit.textKey, () => unit);
        maxWords = max(maxWords, _wordCount(unit.textKey));
      }
      for (final String form in unit.forms) {
        byKey.putIfAbsent(form, () => unit);
        if (form.contains(' ')) {
          phrases.putIfAbsent(form, () => unit);
          maxWords = max(maxWords, _wordCount(form));
        }
      }
    }
    return UnitIndex._(byKey, phrases, maxWords);
  }

  /// Empty index (no dictionary units).
  factory UnitIndex.empty() {
    return UnitIndex._(<String, Unit>{}, <String, Unit>{}, 1);
  }

  /// All single and phrase keys to units (`text_key` wins over `forms`).
  final Map<String, Unit> byKey;

  /// Only phrase keys (contain a space) to units, longest match first.
  final Map<String, Unit> phrases;

  /// Longest phrase length in words (1 when there are no phrases).
  final int maxPhraseWords;

  /// Single-key lookup (`text_key` or `forms`).
  Unit? lookup(String key) => byKey[key];

  /// Phrase lookup by joined normalized keys (e.g. `ice cream`).
  Unit? lookupPhrase(String phraseKey) => phrases[phraseKey];
}

/// Index built from the live units stream for chat rendering.
final unitIndexProvider = StreamProvider<UnitIndex>((ref) {
  final repo = ref.watch(unitRepositoryProvider);
  return repo.watchAll().map(UnitIndex.fromUnits);
});

int _wordCount(String phrase) {
  return phrase.split(' ').where((s) => s.isNotEmpty).length;
}

/// One word found in the display text.
class WordToken {
  const WordToken({
    required this.surface,
    required this.key,
    required this.start,
    required this.end,
    required this.isAiNew,
  });

  /// Surface form as shown.
  final String surface;

  /// Normalized lookup key ([normalizeKey]).
  final String key;

  /// Offsets in the stripped display text.
  final int start;
  final int end;

  /// True when the word was inside a `[[...]]` marker.
  final bool isAiNew;
}

/// One render span: plain text (`surface == null`) or a tappable word.
class ChatSpan {
  const ChatSpan({
    required this.text,
    required this.start,
    required this.end,
    this.surface,
    this.key,
    this.sentence = '',
    this.unit,
    this.isAiNew = false,
  });

  /// Display substring.
  final String text;
  final int start;
  final int end;

  /// Null for plain (non-tappable) gaps.
  final String? surface;

  /// Normalized key (single word) or joined phrase key.
  final String? key;

  /// Sentence containing the word (for the popup in 6.6).
  final String sentence;

  /// Matching dictionary unit, if any.
  final Unit? unit;

  /// True when inside a `[[...]]` marker.
  final bool isAiNew;

  /// True for tappable word/phrase spans.
  bool get isWord => surface != null;
}

class AiRange {
  const AiRange(this.start, this.end);
  final int start;
  final int end;
}

/// Strips `[[...]]` markers, keeping the inner text.
String stripMarkers(String raw) {
  return raw.replaceAllMapped(markerRegExp, (m) => m.group(1)!);
}

/// Returns the sentence containing [offset] (delimited by `.` `!` `?`).
///
/// The returned sentence is trimmed. Newlines always break sentences.
String sentenceForOffset(String text, int offset) {
  if (text.isEmpty) {
    return '';
  }
  final int safe = offset.clamp(0, text.length - 1);
  int start = 0;
  for (int i = safe; i > 0; i--) {
    final String ch = text[i - 1];
    if (ch == '\n') {
      start = i;
      break;
    }
    if (ch == '.' || ch == '!' || ch == '?') {
      start = i;
      break;
    }
  }
  while (start < text.length &&
      (text[start] == ' ' || text[start] == '\t' || text[start] == '\n')) {
    if (start >= safe) {
      break;
    }
    start++;
  }
  int end = text.length;
  for (int i = safe; i < text.length; i++) {
    final String ch = text[i];
    if (ch == '\n') {
      end = i;
      break;
    }
    if (ch == '.' || ch == '!' || ch == '?') {
      end = i + 1;
      break;
    }
  }
  return text.substring(start, end).trim();
}

/// Finds word tokens in already-stripped [displayText].
List<WordToken> findWords(String displayText, List<AiRange> aiRanges) {
  final List<WordToken> tokens = [];
  for (final RegExpMatch m in wordRegExp.allMatches(displayText)) {
    final String surface = m.group(1)!;
    final int s = m.start;
    bool ai = false;
    for (final AiRange r in aiRanges) {
      if (s >= r.start && s < r.end) {
        ai = true;
        break;
      }
    }
    tokens.add(
      WordToken(
        surface: surface,
        key: normalizeKey(surface),
        start: s,
        end: m.end,
        isAiNew: ai,
      ),
    );
  }
  return tokens;
}

/// Parses [raw] (with `[[...]]` markers) into render spans.
///
/// Markers are stripped; inner words are flagged AI-new. Dictionary
/// matching is case-insensitive via [normalizeKey]; phrases match as
/// token sequences, longest first. Gaps between words become plain spans.
List<ChatSpan> parseMessage(String raw, UnitIndex index) {
  final StringBuffer display = StringBuffer();
  final List<AiRange> aiRanges = [];
  int lastRaw = 0;
  for (final RegExpMatch m in markerRegExp.allMatches(raw)) {
    display.write(raw.substring(lastRaw, m.start));
    final int dispStart = display.length;
    display.write(m.group(1)!);
    aiRanges.add(AiRange(dispStart, display.length));
    lastRaw = m.end;
  }
  display.write(raw.substring(lastRaw));
  final String displayText = display.toString();
  if (displayText.isEmpty) {
    return const [];
  }

  final List<WordToken> tokens = findWords(displayText, aiRanges);
  final List<ChatSpan> spans = [];
  int cursor = 0;
  int ti = 0;
  while (ti < tokens.length) {
    Unit? phraseUnit;
    int phraseLen = 0;
    final int maxTry = min(index.maxPhraseWords, tokens.length - ti);
    for (int len = maxTry; len >= 2; len--) {
      final String phraseKey = tokens
          .sublist(ti, ti + len)
          .map((t) => t.key)
          .join(' ');
      final Unit? found = index.lookupPhrase(phraseKey);
      if (found != null) {
        phraseUnit = found;
        phraseLen = len;
        break;
      }
    }
    if (phraseUnit != null) {
      final WordToken first = tokens[ti];
      final WordToken last = tokens[ti + phraseLen - 1];
      if (cursor < first.start) {
        spans.add(
          ChatSpan(
            text: displayText.substring(cursor, first.start),
            start: cursor,
            end: first.start,
          ),
        );
      }
      final String surf = displayText.substring(first.start, last.end);
      final String pkey = tokens
          .sublist(ti, ti + phraseLen)
          .map((t) => t.key)
          .join(' ');
      final bool ai = tokens.sublist(ti, ti + phraseLen).any((t) => t.isAiNew);
      spans.add(
        ChatSpan(
          text: surf,
          start: first.start,
          end: last.end,
          surface: surf,
          key: pkey,
          sentence: sentenceForOffset(displayText, first.start),
          unit: phraseUnit,
          isAiNew: ai,
        ),
      );
      cursor = last.end;
      ti += phraseLen;
    } else {
      final WordToken tok = tokens[ti];
      if (cursor < tok.start) {
        spans.add(
          ChatSpan(
            text: displayText.substring(cursor, tok.start),
            start: cursor,
            end: tok.start,
          ),
        );
      }
      spans.add(
        ChatSpan(
          text: tok.surface,
          start: tok.start,
          end: tok.end,
          surface: tok.surface,
          key: tok.key,
          sentence: sentenceForOffset(displayText, tok.start),
          unit: index.lookup(tok.key),
          isAiNew: tok.isAiNew,
        ),
      );
      cursor = tok.end;
      ti += 1;
    }
  }
  if (cursor < displayText.length) {
    spans.add(
      ChatSpan(
        text: displayText.substring(cursor),
        start: cursor,
        end: displayText.length,
      ),
    );
  }
  return spans;
}
