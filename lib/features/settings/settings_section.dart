import 'package:flutter/material.dart';

/// Visual card around one Settings section.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      elevation: 0,
      color: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: child,
    );
  }
}

/// Muted supporting text used for Settings item descriptions.
///
/// Follows the AndroidX preference pattern: a smaller text appearance than the
/// title, painted with the secondary text color.
class SettingsDescription extends StatelessWidget {
  const SettingsDescription(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
      ),
    );
  }
}
