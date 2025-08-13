import 'package:flutter/material.dart';
import '../common/widgets/bottom_nav.dart';
import '../features/activate/view/activate_page.dart';
import '../features/boards/view/boards_page.dart';
import '../features/keys/view/keys_page.dart';
import '../features/profiles/view/profiles_page.dart';

enum TabItem { activate, boards, keys, profiles }

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _current = 0;

  // independent stacks for each tab
  final _navKeys = <TabItem, GlobalKey<NavigatorState>>{
    TabItem.activate: GlobalKey<NavigatorState>(),
    TabItem.boards:   GlobalKey<NavigatorState>(),
    TabItem.keys:     GlobalKey<NavigatorState>(),
    TabItem.profiles: GlobalKey<NavigatorState>(),
  };

  Future<bool> _onWillPop() async {
    final key = _navKeys[TabItem.values[_current]]!;
    if (key.currentState?.canPop() ?? false) {
      key.currentState!.pop();
      return false; // handled inside current tab
    }
    return true; // allow app to close
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        body: IndexedStack(
          index: _current,
          children: [
            _TabNavigator(navigatorKey: _navKeys[TabItem.activate]!, child: const ActivatePage()),
            _TabNavigator(navigatorKey: _navKeys[TabItem.boards]!,   child: const BoardsPage()),
            _TabNavigator(navigatorKey: _navKeys[TabItem.keys]!,     child: const KeysPage()),
            _TabNavigator(navigatorKey: _navKeys[TabItem.profiles]!, child: const ProfilesPage()),
          ],
        ),
        bottomNavigationBar: BottomNav(
          currentIndex: _current,
          onTap: (i) => setState(() => _current = i), // <- critical
        ),
      ),
    );
  }
}

class _TabNavigator extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  const _TabNavigator({required this.navigatorKey, required this.child});

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      onGenerateRoute: (settings) =>
          MaterialPageRoute(builder: (_) => child, settings: settings),
    );
  }
}
