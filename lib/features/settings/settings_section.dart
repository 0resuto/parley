import 'package:flutter/material.dart';

/// Visual card around one Settings section.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
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
