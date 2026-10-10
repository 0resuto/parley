import 'package:intl/intl.dart';

/// Formats a unit's due date relative to [now] (SPEC 4.3).
///
/// Past due dates read as overdue, future dates as due in.
/// Distant dates fall back to an absolute date via `intl`.
String formatRelativeDue(DateTime due, DateTime now) {
  final Duration diff = due.toUtc().difference(now.toUtc());
  if (diff.inMinutes.abs() < 1) {
    return 'Due now';
  }
  if (!diff.isNegative) {
    if (diff < const Duration(hours: 1)) {
      final int minutes = diff.inMinutes;
      return 'Due in $minutes min${minutes == 1 ? '' : 's'}';
    }
    if (diff < const Duration(hours: 24)) {
      final int hours = diff.inHours;
      return 'Due in $hours hour${hours == 1 ? '' : 's'}';
    }
    if (diff < const Duration(days: 30)) {
      final int days = diff.inDays;
      return 'Due in $days day${days == 1 ? '' : 's'}';
    }
    return 'Due ${DateFormat.yMMMd().format(due.toLocal())}';
  }
  final Duration overdue = -diff;
  if (overdue < const Duration(hours: 1)) {
    final int minutes = overdue.inMinutes;
    return 'Overdue by $minutes min${minutes == 1 ? '' : 's'}';
  }
  if (overdue < const Duration(hours: 24)) {
    final int hours = overdue.inHours;
    return 'Overdue by $hours hour${hours == 1 ? '' : 's'}';
  }
  if (overdue < const Duration(days: 30)) {
    final int days = overdue.inDays;
    return 'Overdue by $days day${days == 1 ? '' : 's'}';
  }
  return 'Overdue since ${DateFormat.yMMMd().format(due.toLocal())}';
}
