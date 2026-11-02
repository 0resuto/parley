import 'package:flutter/material.dart';

import 'package:parley/data/models/unit.dart';
import 'package:parley/services/srs/srs_service.dart';

/// The active flashcard: word on the front, meaning and ratings on the back.
class CardsStudyCard extends StatelessWidget {
  const CardsStudyCard({
    super.key,
    required this.unit,
    required this.revealed,
    required this.resolving,
    required this.meaning,
    required this.busy,
    required this.onReveal,
    required this.onRate,
    required this.onMarkKnown,
  });

  static const Color _againBackground = Color(0xFF7C4A4A);
  static const Color _againForeground = Color(0xFFF6DEDE);
  static const Color _hardBackground = Color(0xFF4A4E56);
  static const Color _hardForeground = Color(0xFFE4E6EA);
  static const Color _goodBackground = Color(0xFF46664F);
  static const Color _goodForeground = Color(0xFFDDEDE1);
  static const Color _easyBackground = Color(0xFF455E78);
  static const Color _easyForeground = Color(0xFFDCE8F5);

  final Unit unit;
  final bool revealed;
  final bool resolving;
  final String? meaning;
  final bool busy;
  final VoidCallback onReveal;
  final ValueChanged<Rating> onRate;
  final VoidCallback onMarkKnown;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.style_outlined,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'WORD',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'More',
                  onSelected: (String value) {
                    if (value == 'markKnown') {
                      onMarkKnown();
                    }
                  },
                  itemBuilder: (BuildContext context) {
                    return [
                      PopupMenuItem<String>(
                        value: 'markKnown',
                        enabled: !busy,
                        child: const Text('Mark as known'),
                      ),
                    ];
                  },
                ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 132),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 20,
                  ),
                  child: Text(
                    unit.text,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _answer(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _answer(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    if (!revealed) {
      return SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: onReveal,
          icon: const Icon(Icons.visibility_outlined),
          label: const Text('Show answer'),
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(color: colors.outlineVariant.withValues(alpha: 0.4)),
        const SizedBox(height: 6),
        Text(
          'MEANING',
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (resolving)
          const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                key: Key('cardMeaningSpinner'),
              ),
            ),
          )
        else
          Text(
            meaning ?? '(no meaning)',
            key: const Key('cardMeaning'),
            style: theme.textTheme.titleLarge?.copyWith(height: 1.25),
          ),
        const SizedBox(height: 20),
        if (!resolving) _ratings(context),
      ],
    );
  }

  Widget _ratings(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ratingButton(
            context,
            Rating.again,
            'Again',
            background: _againBackground,
            foreground: _againForeground,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ratingButton(
            context,
            Rating.hard,
            'Hard',
            background: _hardBackground,
            foreground: _hardForeground,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ratingButton(
            context,
            Rating.good,
            'Good',
            background: _goodBackground,
            foreground: _goodForeground,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ratingButton(
            context,
            Rating.easy,
            'Easy',
            background: _easyBackground,
            foreground: _easyForeground,
          ),
        ),
      ],
    );
  }

  Widget _ratingButton(
    BuildContext context,
    Rating rating,
    String label, {
    required Color background,
    required Color foreground,
  }) {
    return SizedBox(
      height: 46,
      child: ElevatedButton(
        onPressed: busy ? null : () => onRate(rating),
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background.withValues(alpha: 0.38),
          disabledForegroundColor: foreground.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
