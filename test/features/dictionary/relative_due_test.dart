import 'package:flutter_test/flutter_test.dart';
import 'package:parley/features/dictionary/relative_due.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 1, 10, 12);

  test('due now', () {
    expect(formatRelativeDue(now, now), 'Due now');
    expect(
      formatRelativeDue(now.add(const Duration(seconds: 30)), now),
      'Due now',
    );
  });

  test('future dates', () {
    expect(
      formatRelativeDue(now.add(const Duration(minutes: 5)), now),
      'Due in 5 mins',
    );
    expect(
      formatRelativeDue(now.add(const Duration(hours: 3)), now),
      'Due in 3 hours',
    );
    expect(
      formatRelativeDue(now.add(const Duration(days: 2)), now),
      'Due in 2 days',
    );
    expect(
      formatRelativeDue(now.add(const Duration(days: 40)), now),
      startsWith('Due '),
    );
  });

  test('overdue dates', () {
    expect(
      formatRelativeDue(now.subtract(const Duration(minutes: 5)), now),
      'Overdue by 5 mins',
    );
    expect(
      formatRelativeDue(now.subtract(const Duration(hours: 2)), now),
      'Overdue by 2 hours',
    );
    expect(
      formatRelativeDue(now.subtract(const Duration(days: 3)), now),
      'Overdue by 3 days',
    );
    expect(
      formatRelativeDue(now.subtract(const Duration(days: 40)), now),
      startsWith('Overdue since '),
    );
  });
}
