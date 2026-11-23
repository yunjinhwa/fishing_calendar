import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/record_sync_service.dart';
import '../auth/auth_access_guard.dart';
import '../calendar/calendar_page.dart';
import '../common/top_card_notification.dart';
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
  final authSession = AuthSessionRepository.instance;
  late int selectedIndex;
  int calendarRefreshKey = 0;
  final calendarNavigatorKey = GlobalKey<NavigatorState>();
  final _calendarNoticeObserver = TopCardNotificationObserver();

  @override
  void initState() {
    super.initState();
    selectedIndex = _initialTabIndex(widget.initialIndex);
    authSession.addListener(_handleSessionChange);
  }

  @override
  void dispose() {
    authSession.removeListener(_handleSessionChange);
    super.dispose();
  }

  void _handleSessionChange() {
    if (!mounted) {
      return;
    }

    if (authSession.hasPendingAccountDeletion && selectedIndex != 4) {
      TopCardNotification.dismissAll();
      setState(() {
        selectedIndex = 4;
      });
      return;
    }

    if (!authSession.isGuest || !_isMemberOnlyTab(selectedIndex)) {
      return;
    }

    TopCardNotification.dismissAll();
    setState(() {
      selectedIndex = 1;
    });
  }

  List<Widget> get pages {
    return [
      _TabNavigator(
        navigatorKey: calendarNavigatorKey,
        noticeObserver: _calendarNoticeObserver,
        child: CalendarPage(
          key: ValueKey('calendar-$calendarRefreshKey'),
          isActive: selectedIndex == 0,
        ),
      ),
      MapPage(isActive: selectedIndex == 1),
      RecordPage(isActive: selectedIndex == 2),
      FishDictionaryPage(isActive: selectedIndex == 3),
      const MyPage(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final tabPages = pages;
    final noticeGeneration = authSession.sessionGeneration;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Builder(
        builder: (bodyContext) => IndexedStack(
          index: selectedIndex,
          children: [
            for (var index = 0; index < tabPages.length; index++)
              MediaQuery.removeViewInsets(
                // Use the Scaffold padding to avoid reserving the bottom inset
                // again inside tabs when the navigation bar already uses it.
                context: bodyContext,
                removeBottom: index != selectedIndex,
                child: TopCardNotificationScope(
                  enabled: index == selectedIndex,
                  route: ModalRoute.of(context),
                  isActive: () =>
                      mounted &&
                      index == selectedIndex &&
                      authSession.sessionGeneration == noticeGeneration,
                  child: tabPages[index],
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar:
          isKeyboardVisible || authSession.isAccountDeletedRemotely
          ? null
          : DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.border)),
              ),
              child: NavigationBar(
                selectedIndex: selectedIndex,
                onDestinationSelected: (index) async {
                  if (authSession.hasPendingAccountDeletion && index != 4) {
                    if (mounted) {
                      TopCardNotification.show(
                        context,
                        authSession.isAccountDeletedRemotely
                            ? '탈퇴된 계정입니다. 로그아웃해 주세요.'
                            : '회원 탈퇴 처리를 먼저 완료해 주세요.',
                        type: TopCardNotificationType.warning,
                      );
                    }
                    return;
                  }
                  if (_isMemberOnlyTab(index) &&
                      !authSession.canManageRecords) {
                    final allowed = await requireMemberAccess(
                      context,
                      message: '출조 기록과 내 정보 관리는 로그인 후 사용할 수 있습니다.',
                    );

                    if (!allowed || !mounted) {
                      return;
                    }
                  }

                  final isTabChange = index != selectedIndex;
                  if (isTabChange || index == 0) {
                    TopCardNotification.dismissAll();
                  }
                  if (index == 0) {
                    calendarNavigatorKey.currentState?.popUntil(
                      (route) => route.isFirst,
                    );
                  }

                  if (isTabChange || index == 0) {
                    setState(() {
                      selectedIndex = index;
                      if (index == 0) {
                        calendarRefreshKey++;
                      }
                    });
                  }

                  if (isTabChange) {
                    unawaited(RecordSyncService.instance.syncNow());
                  }
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
                    icon: SizedBox.square(
                      dimension: 42,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.add, color: Colors.white, size: 26),
                      ),
                    ),
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

  int _initialTabIndex(int index) {
    final normalizedIndex = _normalizeTabIndex(index);
    if (authSession.isGuest && _isMemberOnlyTab(normalizedIndex)) {
      return 1;
    }

    return normalizedIndex;
  }
}

class _TabNavigator extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final NavigatorObserver noticeObserver;
  final Widget child;

  const _TabNavigator({
    required this.navigatorKey,
    required this.child,
    required this.noticeObserver,
  });

  @override
  Widget build(BuildContext context) {
    return _TabPage(
      page: child,
      child: Navigator(
        key: navigatorKey,
        observers: [noticeObserver],
        onGenerateRoute: (settings) {
          return MaterialPageRoute(
            builder: (context) =>
                context.dependOnInheritedWidgetOfExactType<_TabPage>()!.page,
          );
        },
      ),
    );
  }
}

class _TabPage extends InheritedWidget {
  const _TabPage({required this.page, required super.child});

  final Widget page;

  @override
  bool updateShouldNotify(_TabPage oldWidget) => page != oldWidget.page;
}
