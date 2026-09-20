import 'package:flutter/material.dart';

import '../../data/repositories/auth_session_repository.dart';
import '../auth/auth_access_guard.dart';
import '../calendar/calendar_page.dart';
import '../fish_dictionary/fish_dictionary_page.dart';
import '../map/map_page.dart';
import '../my_page/my_page.dart';
import '../record/record_page.dart';

class AppShell extends StatefulWidget {
  final int initialIndex;

  const AppShell({super.key, this.initialIndex = 0});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int selectedIndex;
  int calendarRefreshKey = 0;
  final calendarNavigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    selectedIndex = _normalizeTabIndex(widget.initialIndex);
  }

  List<Widget> get pages {
    return [
      _TabNavigator(
        navigatorKey: calendarNavigatorKey,
        child: CalendarPage(key: ValueKey('calendar-$calendarRefreshKey')),
      ),
      const MapPage(),
      const RecordPage(),
      const FishDictionaryPage(),
      const MyPage(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final tabPages = pages;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: IndexedStack(
        index: selectedIndex,
        children: [
          for (var index = 0; index < tabPages.length; index++)
            MediaQuery.removeViewInsets(
              context: context,
              removeBottom: index != selectedIndex,
              child: tabPages[index],
            ),
        ],
      ),
      bottomNavigationBar: isKeyboardVisible
          ? null
          : NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: (index) async {
                if (_isMemberOnlyTab(index) &&
                    !AuthSessionRepository.instance.canManageRecords) {
                  final allowed = await requireMemberAccess(
                    context,
                    message: '출조 기록과 내 정보 관리는 로그인 후 사용할 수 있습니다.',
                  );

                  if (!allowed || !mounted) {
                    return;
                  }
                }

                if (index == 0) {
                  calendarNavigatorKey.currentState?.popUntil(
                    (route) => route.isFirst,
                  );
                }

                setState(() {
                  selectedIndex = index;

                  if (index == 0) {
                    calendarRefreshKey++;
                  }
                });
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.calendar_month_outlined),
                  selectedIcon: Icon(Icons.calendar_month),
                  label: '캘린더',
                ),
                NavigationDestination(
                  icon: Icon(Icons.map_outlined),
                  selectedIcon: Icon(Icons.map),
                  label: '지도',
                ),
                NavigationDestination(
                  icon: Icon(Icons.add_circle_outline),
                  selectedIcon: Icon(Icons.add_circle),
                  label: '기록',
                ),
                NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined),
                  selectedIcon: Icon(Icons.menu_book),
                  label: '도감',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '내정보',
                ),
              ],
            ),
    );
  }

  bool _isMemberOnlyTab(int index) {
    return index == 0 || index == 2 || index == 4;
  }

  int _normalizeTabIndex(int index) {
    if (index < 0) {
      return 0;
    }

    if (index > 4) {
      return 4;
    }

    return index;
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
      onGenerateRoute: (settings) {
        return MaterialPageRoute(builder: (_) => child);
      },
    );
  }
}
