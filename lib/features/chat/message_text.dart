import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:parley/data/models/unit.dart';
import 'tokenizer.dart';

/// Tap callback for a word: surface form, normalized key, sentence.
typedef WordTapCallback =
    void Function(String surface, String key, String sentence);

/// Renders a chat message with tappable words (SPEC 5.4, PLAN 6.5).
///
/// Markers are stripped; dictionary units (not Known) get a thin solid
/// primary underline, AI-new words outside the dictionary get a thin
/// dotted tertiary underline, everything else has no styling. All words
/// (including Known units and plain words) are tappable; gaps are not.
class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.rawText,
    required this.index,
    this.onWordTap,
    this.style,
  });

  /// Raw message text, including `[[...]]` markers.
  final String rawText;

  /// Dictionary lookup index.
  final UnitIndex index;

  /// Called with `(surface, key, sentence)` on word tap.
  final WordTapCallback? onWordTap;

  /// Base text style (defaults to the ambient [DefaultTextStyle]).
  final TextStyle? style;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  List<ChatSpan> _spans = const [];
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(covariant MessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawText != widget.rawText ||
        !identical(oldWidget.index, widget.index)) {
      _rebuild();
    }
  }

  void _rebuild() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    _spans = parseMessage(widget.rawText, widget.index);
    for (final ChatSpan span in _spans) {
      if (!span.isWord) {
        continue;
      }
      final String surface = span.surface!;
      final String key = span.key!;
      final String sentence = span.sentence;
      final TapGestureRecognizer recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onWordTap?.call(surface, key, sentence);
      _recognizers.add(recognizer);
    }
  }

  @override
  void dispose() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle base = widget.style ?? DefaultTextStyle.of(context).style;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle dictionaryStyle = base.copyWith(
      color: colors.primary,
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.solid,
      decorationColor: colors.primary,
      decorationThickness: 1,
    );
    final TextStyle aiNewStyle = base.copyWith(
      color: colors.tertiary,
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: colors.tertiary,
      decorationThickness: 1,
    );

    int wordPos = 0;
    final List<InlineSpan> children = [];
    for (final ChatSpan span in _spans) {
      if (!span.isWord) {
        children.add(TextSpan(text: span.text, style: base));
        continue;
      }
      final TapGestureRecognizer recognizer = _recognizers[wordPos];
      wordPos++;
      children.add(
        TextSpan(
          text: span.text,
          style: _styleFor(span, base, dictionaryStyle, aiNewStyle),
          recognizer: recognizer,
        ),
      );
    }
    if (children.isEmpty) {
      return Text(stripMarkers(widget.rawText), style: base);
    }
    return Text.rich(TextSpan(children: children, style: base));
  }

  TextStyle _styleFor(
    ChatSpan span,
    TextStyle base,
    TextStyle dictionaryStyle,
    TextStyle aiNewStyle,
  ) {
    final Unit? unit = span.unit;
    if (unit != null && statusOf(unit) != UnitStatus.known) {
      return dictionaryStyle;
    }
    if (span.isAiNew && unit == null) {
      return aiNewStyle;
    }
    return base;
  }
}
