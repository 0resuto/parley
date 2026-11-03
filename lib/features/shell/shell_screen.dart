import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/features/cards/cards_controller.dart';
import 'package:parley/features/cards/cards_screen.dart';
import 'package:parley/features/chat/chat_screen.dart';
import 'package:parley/features/dictionary/dictionary_screen.dart';
import 'package:parley/features/settings/settings_screen.dart';

class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  int _index = 0;
  bool _wasKeyboardVisible = false;

  static const _screens = <Widget>[
    ChatScreen(),
    CardsScreen(),
    DictionaryScreen(),
    SettingsScreen(),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_wasKeyboardVisible && !visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    }
    _wasKeyboardVisible = visible;
  }

  @override
  Widget build(BuildContext context) {
    final bool keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      // The shell owns the keyboard inset for all tab screens, so nested
      // tab Scaffolds must not apply it again. Hiding the navigation bar
      // lets the body reach the keyboard without a gap.
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: keyboardVisible
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (int value) {
                FocusManager.instance.primaryFocus?.unfocus();
                if (value != 1) {
                  ref.read(cardsControllerProvider.notifier).clearUndo();
                }
                setState(() {
                  _index = value;
                });
              },
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.chat_outlined),
                  selectedIcon: Icon(Icons.chat),
                  label: 'Chat',
                ),
                NavigationDestination(
                  icon: Icon(Icons.style_outlined),
                  selectedIcon: Icon(Icons.style),
                  label: 'Cards',
                ),
                NavigationDestination(
                  icon: Icon(Icons.book_outlined),
                  selectedIcon: Icon(Icons.book),
                  label: 'Dictionary',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            ),
    );
  }
}
