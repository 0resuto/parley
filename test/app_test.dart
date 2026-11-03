import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parley/app.dart';
import 'package:parley/data/db/database.dart' hide Conversation;
import 'package:parley/data/models/chat.dart';
import 'package:parley/data/repositories/chat_repository.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/features/settings/stt_models_controller.dart';
import 'package:parley/features/shell/shell_screen.dart';
import 'package:parley/services/stt/stt_engine.dart';
import 'package:parley/services/stt/stt_model_manager.dart';
import 'package:parley/services/stt/stt_providers.dart';

import 'helpers/fake_chat_repository.dart';
import 'helpers/fake_clock.dart';
import 'helpers/fake_stt_service.dart';
import 'helpers/fake_unit_repository.dart';

class ReadyModelsController extends SttModelsController {
  @override
  SttModelsState build() {
    return const SttModelsState(<SttEngineKind, SttModelStatus>{
      SttEngineKind.moonshine: SttModelStatus(),
      SttEngineKind.whisper: SttModelStatus(
        phase: SttModelPhase.ready,
        progress: 1,
      ),
    });
  }

  @override
  Future<void> ensureRequired() async {}
}

void main() {
  late AppDatabase db;
  late FakeUnitRepository repo;
  late FakeClock clock;
  late FakeChatRepository chats;

  setUp(() {
    // (T-20) In-memory database; close streams synchronously so no drift
    // timer stays pending when the widget tree is disposed.
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    clock = FakeClock(DateTime.utc(2026, 1, 10, 12));
    repo = FakeUnitRepository(clock: clock);
    chats = FakeChatRepository(clock: clock);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          unitRepositoryProvider.overrideWithValue(repo),
          clockProvider.overrideWithValue(clock),
          chatRepositoryProvider.overrideWithValue(chats),
          sttModelsControllerProvider.overrideWith(
            () => ReadyModelsController(),
          ),
          sttServiceProvider.overrideWithValue(FakeSttService()),
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

  testWidgets('switching tabs drops composer focus', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    final TextField input = tester.widget(find.byKey(const Key('chatInput')));
    final FocusNode focus = input.focusNode!;
    await tester.tap(find.byKey(const Key('chatInput')));
    await tester.pump();
    expect(focus.hasFocus, isTrue);

    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();

    expect(focus.hasFocus, isFalse);
  });

  testWidgets('theme brightness is dark', (WidgetTester tester) async {
    await pumpApp(tester);

    final BuildContext context = tester.element(find.byType(ShellScreen));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(Theme.of(context).colorScheme.brightness, Brightness.dark);
  });

  testWidgets('keyboard keeps the composer and newest message visible', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.resetViewInsets);
    final Conversation conversation = await chats.createConversation();
    for (int i = 0; i < 20; i++) {
      await chats.addMessage(
        conversationId: conversation.id,
        role: i.isEven ? ChatRole.user : ChatRole.assistant,
        content:
            'message $i\n'
            '${List<String>.generate(5, (int j) => 'line $j').join('\n')}',
      );
    }
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('chatInput')));
    await tester.pump();
    final double dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    await tester.pumpAndSettle();

    final double screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final double inputBottom = tester
        .getBottomLeft(find.byKey(const Key('chatInput')))
        .dy;
    expect(inputBottom, lessThanOrEqualTo(screenHeight - 300 + 1));
    expect(inputBottom, greaterThan(screenHeight - 300 - 60));

    final ListView list = tester.widget(find.byKey(const Key('chatList')));
    final ScrollController controller = list.controller!;
    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1),
    );
    expect(find.textContaining('message 19'), findsOneWidget);
  });

  testWidgets('keyboard keeps a short chat in place', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.resetViewInsets);
    final Conversation conversation = await chats.createConversation();
    await chats.addMessage(
      conversationId: conversation.id,
      role: ChatRole.user,
      content: 'Only message',
    );
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('chatInput')));
    await tester.pump();
    final double dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    await tester.pumpAndSettle();

    final double screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final double inputBottom = tester
        .getBottomLeft(find.byKey(const Key('chatInput')))
        .dy;
    expect(inputBottom, lessThanOrEqualTo(screenHeight - 300 + 1));
    expect(inputBottom, greaterThan(screenHeight - 300 - 60));

    final ListView list = tester.widget(find.byKey(const Key('chatList')));
    expect(list.controller!.position.maxScrollExtent, 0);
    expect(find.text('Only message'), findsWidgets);
  });

  testWidgets('keyboard does not jump when reading older messages', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.resetViewInsets);
    final Conversation conversation = await chats.createConversation();
    for (int i = 0; i < 20; i++) {
      await chats.addMessage(
        conversationId: conversation.id,
        role: i.isEven ? ChatRole.user : ChatRole.assistant,
        content:
            'message $i\n'
            '${List<String>.generate(5, (int j) => 'line $j').join('\n')}',
      );
    }
    await pumpApp(tester);

    final ListView list = tester.widget(find.byKey(const Key('chatList')));
    final ScrollController controller = list.controller!;
    await tester.drag(find.byKey(const Key('chatList')), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(controller.position.pixels, greaterThan(0));

    await tester.tap(find.byKey(const Key('chatInput')));
    await tester.pump();
    final double dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    await tester.pumpAndSettle();

    expect(
      controller.position.pixels,
      lessThan(controller.position.maxScrollExtent),
    );
  });

  testWidgets('scrolling with the keyboard open keeps it open', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.resetViewInsets);
    final Conversation conversation = await chats.createConversation();
    for (int i = 0; i < 20; i++) {
      await chats.addMessage(
        conversationId: conversation.id,
        role: i.isEven ? ChatRole.user : ChatRole.assistant,
        content:
            'message $i\n'
            '${List<String>.generate(5, (int j) => 'line $j').join('\n')}',
      );
    }
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('chatInput')));
    await tester.pump();
    final double dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    await tester.pumpAndSettle();

    final TextField input = tester.widget(find.byKey(const Key('chatInput')));
    final FocusNode focus = input.focusNode!;
    expect(focus.hasFocus, isTrue);

    final ListView list = tester.widget(find.byKey(const Key('chatList')));
    final ScrollController controller = list.controller!;
    final double before = controller.position.pixels;
    await tester.drag(find.byKey(const Key('chatList')), const Offset(0, 300));
    await tester.pump();
    final double after = controller.position.pixels;
    expect(after, lessThan(before));

    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.position.pixels, closeTo(after, 1));
    expect(focus.hasFocus, isTrue);
  });
}
