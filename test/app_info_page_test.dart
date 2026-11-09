import 'package:fishing_build/data/app_info/app_info_gateway.dart';
import 'package:fishing_build/data/app_info/app_source_catalog.dart';
import 'package:fishing_build/data/app_info/fish_attribution_repository.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/presentation/app_info/app_info_page.dart';
import 'package:fishing_build/presentation/my_page/my_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final auth = AuthSessionRepository.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    auth.resetAuthGatewayForTesting();
    PackageInfo.setMockInitialValues(
      appName: '낚시 캘린더',
      packageName: 'example.fishing',
      version: '2.3.4',
      buildNumber: '56',
      buildSignature: '',
    );
  });

  tearDown(auth.resetAuthGatewayForTesting);

  testWidgets('version reads once and recovers from a safe error with retry', (
    tester,
  ) async {
    final gateway = _Gateway();
    await tester.pumpWidget(MaterialApp(home: AppInfoPage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('버전 정보를 불러오지 못했어요.'), findsOneWidget);
    expect(find.textContaining('private/platform'), findsNothing);

    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('버전 9.8.7 (123)'), findsOneWidget);
    expect(gateway.calls, 2);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AppInfoPage(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    expect(gateway.calls, 2);
  });

  testWidgets('source navigation launches only the selected public document', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AppInfoPage(
          linkLauncher: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('버전 2.3.4 (56)'), findsOneWidget);
    expect(find.text('어종별 사진·정보 출처'), findsNothing);
    expect(opened, isEmpty);
    await tester.tap(find.text('API·데이터·이미지 출처'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Firebase Authentication'));
    await tester.pumpAndSettle();
    expect(find.text('제공기관·제작자'), findsOneWidget);
    expect(find.text('라이선스'), findsOneWidget);
    for (final removed in ['사용 내용', '이용조건', '안내', '공식 출처']) {
      expect(find.text(removed), findsNothing);
    }
    expect(opened, isEmpty);
    final link = find.widgetWithText(
      TextButton,
      appSourceCatalog.first.provider,
    );
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(appSourceCatalog.first.sourceUrl!)]);
    await tester.tap(
      find.widgetWithText(TextButton, appSourceCatalog.first.licenseLabel!),
    );
    await tester.pumpAndSettle();
    expect(opened.last, Uri.parse(appSourceCatalog.first.licenseUrl!));
  });

  testWidgets('failed external links show an error and allow retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppSourceDetailPage(
          source: appSourceCatalog.first,
          linkLauncher: (_) async {
            calls++;
            return calls > 1;
          },
        ),
      ),
    );
    final link = find.widgetWithText(
      TextButton,
      appSourceCatalog.first.provider,
    );
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.textContaining('링크를 열지 못했어요'), findsOneWidget);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'licenses retain package notices and individual material copyright',
    (tester) async {
      await tester.runAsync(() => FishAttributionRepository().load());
      await tester.pumpWidget(const MaterialApp(home: AppInfoPage()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('오픈소스 라이선스'));
      // The real notice reads large asset strings in a decoding isolate.
      await tester.runAsync(() async {
        await tester.tap(find.text('오픈소스 라이선스'));
        await tester.pumpAndSettle();
      });
      expect(find.byType(LicensePage), findsOneWidget);
      for (final label in [
        'klc (Korean lunar calendar data)',
        'OpenFreeMap / OpenMapTiles / OpenStreetMap',
        'NIFS / Wikidata / Wikipedia / Wikimedia Commons / iNaturalist / GBIF',
        '어류 자료 저작권 고지',
      ]) {
        final tile = find.text(label);
        await tester.scrollUntilVisible(
          tile,
          200,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 50,
        );
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.byType(LicensePage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    },
  );

  for (final plan in UserPlan.values) {
    testWidgets('MyPage app info is accessible for ${plan.name}', (
      tester,
    ) async {
      await auth.setSessionForTesting(
        plan: plan,
        email: plan == UserPlan.guest ? null : 'info@example.com',
        nickname: plan == UserPlan.guest ? null : '앱정보',
      );
      final owner = auth.dataOwnerKey;
      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      final tile = find.widgetWithText(ListTile, '앱 정보');
      await tester.scrollUntilVisible(
        tile,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(AppInfoPage), findsOneWidget);
      expect(find.text('버전 2.3.4 (56)'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.plan, plan);
      expect(auth.dataOwnerKey, owner);
    });
  }

  testWidgets('source credits scroll on narrow large-text screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final page in <Widget>[
      const AppInfoPage(),
      const AppSourcesPage(),
      AppSourceDetailPage(source: appSourceCatalog.first),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: page,
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: page.runtimeType.toString(),
      );
    }
  });
}

class _Gateway implements AppInfoGateway {
  int calls = 0;

  @override
  Future<AppInfoDetails> load() async {
    if (++calls == 1) throw StateError('private/platform');
    return const AppInfoDetails(version: '9.8.7', buildNumber: '123');
  }
}
