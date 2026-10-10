import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parley/app.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/shell/shell_screen.dart';

import 'helpers/fake_chat_repository.dart';
import 'helpers/fake_clock.dart';
import 'helpers/fake_unit_repository.dart';

void main() {
  late FakeUnitRepository repo;
  late FakeClock clock;
  late FakeChatRepository chats;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    repo = FakeUnitRepository(clock: clock);
    chats = FakeChatRepository(clock: clock);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(repo),
          clockProvider.overrideWithValue(clock),
          chatRepositoryProvider.overrideWithValue(chats),
        ],
        child: const ParleyApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows four navigation destinations', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Cards'), findsOneWidget);
    expect(find.text('Dictionary'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('tapping each destination shows its screen', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('No messages yet. Say hello!'), findsOneWidget);

    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();
    expect(find.text('All caught up.'), findsOneWidget);

    await tester.tap(find.text('Dictionary'));
    await tester.pumpAndSettle();
    expect(find.text('Search dictionary'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    // AI provider section is at the top; Data is below it.
    expect(find.text('AI provider'), findsOneWidget);
    await tester.ensureVisible(find.text('Export JSON'));
    await tester.pumpAndSettle();
    expect(find.text('Export JSON'), findsOneWidget);
    expect(find.text('Import JSON'), findsOneWidget);

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.text('No messages yet. Say hello!'), findsOneWidget);
  });

  testWidgets('theme brightness is dark', (WidgetTester tester) async {
    await pumpApp(tester);

    final BuildContext context = tester.element(find.byType(ShellScreen));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(Theme.of(context).colorScheme.brightness, Brightness.dark);
  });
}
