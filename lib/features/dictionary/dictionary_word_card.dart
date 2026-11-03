import 'package:flutter/material.dart';

import 'package:parley/data/models/unit.dart';
import 'dictionary_status.dart';
import 'relative_due.dart';
import 'word_meaning.dart';

/// Compact card row for one dictionary unit in the list.
class DictionaryWordCard extends StatelessWidget {
  const DictionaryWordCard({
    super.key,
    required this.unit,
    required this.status,
    required this.now,
    required this.onTap,
  });

  final Unit unit;
  final UnitStatus status;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color accent = statusColor(colors, status);
    final bool isKnown = status == UnitStatus.known;
    final bool largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final bool overdue =
        !isKnown &&
        unit.due.toUtc().isBefore(
          now.toUtc().subtract(const Duration(minutes: 1)),
        );
    final Color dueColor = overdue ? colors.error : colors.onSurfaceVariant;
    final String compactDue = formatCompactDue(unit.due, now);
    final String fullDue = formatRelativeDue(unit.due, now);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 34,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            unit.text,
                            maxLines: largeText ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                        if (!largeText) ...[
                          const SizedBox(width: 8),
                          if (!isKnown) ...[
                            _dueBadge(theme, dueColor, fullDue, compactDue),
                            const SizedBox(width: 6),
                          ],
                          _statusChip(
                            theme,
                            accent,
                            textColor: isKnown
                                ? colors.onSurfaceVariant
                                : accent,
                          ),
                        ],
                      ],
                    ),
                    if (largeText) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (!isKnown)
                            _dueBadge(theme, dueColor, fullDue, compactDue),
                          _statusChip(
                            theme,
                            accent,
                            textColor: isKnown
                                ? colors.onSurfaceVariant
                                : accent,
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 1),
                    WordMeaning(
                      textKey: unit.textKey,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip(
    ThemeData theme,
    Color accent, {
    required Color textColor,
  }) {
    return Chip(
      label: Text(
        statusLabel(status),
        style: theme.textTheme.labelSmall?.copyWith(
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      padding: EdgeInsets.zero,
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: accent.withValues(alpha: 0.14),
      side: BorderSide(color: accent.withValues(alpha: 0.35)),
    );
  }

  Widget _dueBadge(
    ThemeData theme,
    Color color,
    String fullDue,
    String compactDue,
  ) {
    return Tooltip(
      message: fullDue,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            compactDue,
            key: const Key('dictionaryDue'),
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              height: 1.1,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
