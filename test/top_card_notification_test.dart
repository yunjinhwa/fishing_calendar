import 'dart:async';

import 'package:fishing_build/presentation/common/top_card_notification.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(TopCardNotification.dismissAll);

  testWidgets(
    'floats below the toolbar without moving the page or blocking it',
    (tester) async {
      var taps = 0;
      final context = await _mount(tester, onBodyTap: () => taps++);
      final body = find.byKey(const ValueKey('body-button'));
      final originalPosition = tester.getTopLeft(body);

      TopCardNotification.show(
        context,
        'Saved',
        type: TopCardNotificationType.success,
      );
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(TopCardNotification), findsOneWidget);
      expect(tester.getTopLeft(body), originalPosition);
      expect(tester.getTopLeft(_card).dy, greaterThanOrEqualTo(kToolbarHeight));
      expect(tester.getBottomRight(_card).dy, lessThan(300));
      await tester.tap(body);
      expect(taps, 1);
      await tester.pump(const Duration(seconds: 4));
      expect(_card, findsNothing);
    },
  );

  testWidgets(
    'new notices replace rather than queue and have their own timer',
    (tester) async {
      final context = await _mount(tester);
      TopCardNotification.show(context, 'First');
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      TopCardNotification.show(context, 'Latest');
      await tester.pump();
      expect(find.text('First'), findsNothing);
      expect(find.text('Latest'), findsOneWidget);
      expect(_card, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(_card, findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(_card, findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(_card, findsNothing);
    },
  );

  testWidgets('rapid replacement and manual closing leave no stale notice', (
    tester,
  ) async {
    final context = await _mount(tester);
    TopCardNotification.show(context, 'First');
    TopCardNotification.show(context, 'Second');
    TopCardNotification.show(context, 'Third');
    await tester.pump();
    expect(find.text('Third'), findsOneWidget);
    expect(_card, findsOneWidget);
    await tester.tap(find.byTooltip('알림 닫기'));
    await tester.pump();
    expect(_card, findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen-reader navigation keeps the live notice until closed', (
    tester,
  ) async {
    final context = await _mount(tester, accessible: true);
    TopCardNotification.show(context, 'Please check the input');
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(_card, findsOneWidget);
    expect(
      find.ancestor(
        of: _card,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('알림 닫기'));
    await tester.pump();
    expect(_card, findsNothing);
  });

  testWidgets(
    'long messages fit a narrow screen with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final context = await _mount(
        tester,
        media: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
          viewPadding: EdgeInsets.only(top: 24),
          viewInsets: EdgeInsets.only(bottom: 300),
        ),
      );
      TopCardNotification.show(
        context,
        List.filled(30, '오프라인 저장 요청을 확인하세요.').join(' '),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(_card);
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(304));
      expect(rect.bottom, lessThanOrEqualTo(340));
      await tester.drag(
        find.descendant(
          of: _card,
          matching: find.byType(SingleChildScrollView),
        ),
        const Offset(0, -200),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('알림 닫기'));
      await tester.pump();
      expect(_card, findsNothing);
    },
  );

  testWidgets('route push, pop, replace and remove clear normal notices', (
    tester,
  ) async {
    final context = await _mount(tester);
    final navigator = Navigator.of(context);
    TopCardNotification.show(context, 'Home notice');
    await tester.pump();
    final route = _page();
    unawaited(navigator.push(route));
    await tester.pumpAndSettle();
    expect(_card, findsNothing);

    var current = tester.element(find.text('Other page'));
    TopCardNotification.show(current, 'Other notice');
    await tester.pump();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(_card, findsNothing);

    unawaited(navigator.push(_page()));
    await tester.pumpAndSettle();
    current = tester.element(find.text('Other page'));
    TopCardNotification.show(current, 'Before replacement');
    await tester.pump();
    final replacement = _page();
    unawaited(navigator.pushReplacement(replacement));
    await tester.pumpAndSettle();
    expect(_card, findsNothing);
    current = tester.element(find.text('Other page'));
    TopCardNotification.show(current, 'Before removal');
    await tester.pump();
    navigator.removeRoute(replacement);
    await tester.pumpAndSettle();
    expect(_card, findsNothing);
  });

  testWidgets(
    'success survives its immediate pop once, including nested routes',
    (tester) async {
      final rootObserver = TopCardNotificationObserver();
      final nestedObserver = TopCardNotificationObserver();
      final nested = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [rootObserver],
          home: Navigator(
            key: nested,
            observers: [nestedObserver],
            onGenerateRoute: (_) => _page(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(nested.currentState!.push(_page('Editing')));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Editing'));
      TopCardNotification.show(
        context,
        'Saved',
        type: TopCardNotificationType.success,
        persistAfterPop: true,
      );
      // A typical save callback shows and pops in the same frame.
      nested.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsOneWidget);
      unawaited(nested.currentState!.push(_page('Next page')));
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
    },
  );

  testWidgets('standalone callers preserve completion notices after pop', (
    tester,
  ) async {
    final context = await _mount(tester, observer: false);
    unawaited(Navigator.of(context).push(_page()));
    await tester.pumpAndSettle();
    final other = tester.element(find.text('Other page'));
    TopCardNotification.show(other, 'Deleted', persistAfterPop: true);
    await tester.pump();
    Navigator.of(other).pop();
    await tester.pumpAndSettle();
    expect(find.text('Deleted'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(_card, findsNothing);
  });

  testWidgets('inactive tabs and covered tab routes reject delayed notices', (
    tester,
  ) async {
    late BuildContext scopeContext;
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TopCardNotificationObserver()],
        home: Builder(
          builder: (root) => ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, value, _) => TopCardNotificationScope(
              enabled: value,
              route: ModalRoute.of(root),
              child: Builder(
                builder: (context) {
                  scopeContext = context;
                  return const Scaffold(body: Text('Tab'));
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    enabled.value = false;
    await tester.pump();
    TopCardNotification.show(scopeContext, 'From an inactive tab');
    await tester.pump();
    expect(_card, findsNothing);
    enabled.value = true;
    await tester.pump();
    unawaited(Navigator.of(scopeContext).push(_page()));
    await tester.pumpAndSettle();
    TopCardNotification.show(scopeContext, 'From a covered tab');
    await tester.pump();
    expect(_card, findsNothing);
  });

  testWidgets(
    'backgrounding clears notices and blocks new background notices',
    (tester) async {
      final context = await _mount(tester);
      TopCardNotification.show(context, 'Private notice');
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(_card, findsNothing);
      TopCardNotification.show(context, 'Late result');
      await tester.pump();
      expect(_card, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_card, findsNothing);
    },
  );

  testWidgets('disposing the app cancels timers and allows a fresh overlay', (
    tester,
  ) async {
    var context = await _mount(tester);
    TopCardNotification.show(context, 'Old app');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
    context = await _mount(tester);
    TopCardNotification.show(context, 'Fresh app');
    await tester.pump();
    expect(find.text('Fresh app'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(_card, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

final _card = find.byKey(const ValueKey('top-card-notification'));

Future<BuildContext> _mount(
  WidgetTester tester, {
  VoidCallback? onBodyTap,
  bool observer = true,
  bool accessible = false,
  MediaQueryData? media,
}) async {
  late BuildContext pageContext;
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: observer ? [TopCardNotificationObserver()] : [],
      builder: (context, child) => MediaQuery(
        data: (media ?? MediaQuery.of(context)).copyWith(
          accessibleNavigation: accessible,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          pageContext = context;
          return Scaffold(
            appBar: AppBar(title: const Text('Page')),
            body: Center(
              child: TextButton(
                key: const ValueKey('body-button'),
                onPressed: onBodyTap ?? () {},
                child: const Text('Body'),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return pageContext;
}

MaterialPageRoute<void> _page([String label = 'Other page']) =>
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(label)),
        body: const SizedBox.expand(),
      ),
    );
