import 'dart:async';

import 'package:fishing_build/data/fish/fish_api_configuration.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fish_species_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/presentation/fish_dictionary/fish_dictionary_page.dart';
import 'package:fishing_build/presentation/fish_dictionary/fish_species_detail_page.dart';
import 'package:fishing_build/presentation/fish_dictionary/fish_species_photo.dart';
import 'package:fishing_build/presentation/fish_dictionary/fish_thumbnail_loader.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

const _seaFish = FishSpecies(
  id: 'sea-1',
  name: '감성돔',
  category: FishCategory.sea,
  family: '도미과',
  scientificName: 'Acanthopagrus schlegelii',
  aliases: ['감숭어'],
);
const _freshwaterFish = FishSpecies(
  id: 'fresh-1',
  name: '붕어',
  category: FishCategory.freshwater,
  scientificName: 'Carassius auratus',
);
const _unknownFish = FishSpecies(id: 'unknown-1', name: '미확인어');
const _fish = [_seaFish, _freshwaterFish, _unknownFish];
const _enrichedSeaFish = FishSpecies(
  id: 'sea-1',
  name: '감성돔',
  category: FishCategory.sea,
  family: '갱신된 분류',
  scientificName: 'Acanthopagrus schlegelii',
  feature: '새로 받은 상세 정보입니다.',
);

FishCatalogSnapshot _snapshot({
  List<FishSpecies> items = _fish,
  bool isFromCache = false,
  bool isStale = false,
  FishCatalogFailure? failure,
  bool isBundled = false,
  DateTime? dataUpdatedAt,
}) => FishCatalogSnapshot(
  items: items,
  fetchedAt: DateTime.utc(2026, 11, 1),
  isFromCache: isFromCache,
  isStale: isStale,
  failure: failure,
  isBundled: isBundled,
  dataUpdatedAt: dataUpdatedAt,
);

void main() {
  testWidgets(
    'transient partial detail preserves valid fields and retries only on request',
    (tester) async {
      const partial = FishSpecies(
        id: 'partial',
        name: '일부 정보 확인 어종',
        category: FishCategory.sea,
        scientificName: 'Acanthopagrus schlegelii',
        family: '도미과',
        habitat: '연안 바다',
        feature: '이미 확인된 특징입니다.',
        detailNeedsRetry: true,
      );
      final repository = _Repository()..onDetail = (_, _, _) async => partial;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: partial,
            repository: repository,
            networkStatus: network,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('일부 정보를 불러오지 못했습니다.'), findsOneWidget);
      expect(find.text('사진을 불러오지 못했습니다.'), findsOneWidget);
      expect(find.text('사진이 없습니다.'), findsNothing);
      expect(find.text(partial.feature), findsOneWidget);
      expect(find.text(partial.scientificName), findsOneWidget);
      // An unknown size is still unknown; do not label every empty field as a
      // communication failure merely because the photo lookup was transient.
      expect(find.text('제공되지 않음'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(repository.detailCalls, hasLength(1));

      final pending = Completer<FishSpecies>();
      repository.onDetail = (_, _, _) => pending.future;
      await tester.tap(find.text('상세 정보 다시 시도'));
      await tester.pump();
      expect(repository.detailCalls, hasLength(2));
      expect(repository.detailCalls.last.forceRefresh, isTrue);
      expect(repository.detailCalls.last.allowNetwork, isTrue);
      expect(find.text(partial.feature), findsOneWidget);
      expect(find.text('일부 정보를 불러오지 못했습니다.'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      pending.complete(
        FishSpecies.fromJson({...partial.toJson(), 'detailNeedsRetry': false}),
      );
      await tester.pumpAndSettle();
      expect(find.text('일부 정보를 불러오지 못했습니다.'), findsNothing);
      expect(find.text('사진을 불러오지 못했습니다.'), findsNothing);
      expect(find.text('상세 정보 다시 시도'), findsNothing);
      expect(find.text('사진이 없습니다.'), findsOneWidget);
      expect(find.text(partial.feature), findsOneWidget);
    },
  );

  testWidgets(
    'failed prose is temporary while the verified photo and basic data stay available',
    (tester) async {
      const partial = FishSpecies(
        id: 'partial-prose',
        name: '특징 조회 확인 어종',
        category: FishCategory.sea,
        scientificName: 'Acanthopagrus schlegelii',
        family: '도미과',
        habitat: '연안 바다',
        maxSize: '몸길이는 약 20cm이다.',
        imageUrl: 'https://example.org/fish.jpg',
        detailNeedsRetry: true,
      );
      final repository = _Repository()..onDetail = (_, _, _) async => partial;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: partial,
            repository: repository,
            networkStatus: network,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('일부 정보를 불러오지 못했습니다.'), findsOneWidget);
      expect(find.text('특징을 불러오지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
      expect(find.text('제공되지 않음'), findsNothing);
      expect(find.text('사진이 없습니다.'), findsNothing);
      expect(find.text(partial.maxSize), findsOneWidget);
      expect(
        tester
            .widget<FishSpeciesPhoto>(find.byType(FishSpeciesPhoto))
            .fish
            .imageUrl,
        partial.imageUrl,
      );
      expect(repository.detailCalls, hasLength(1));

      final pending = Completer<FishSpecies>();
      repository.onDetail = (_, _, _) => pending.future;
      await tester.tap(find.text('상세 정보 다시 시도'));
      await tester.pump();
      expect(find.text('특징을 불러오지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
      expect(find.text('제공되지 않음'), findsNothing);
      pending.complete(
        FishSpecies.fromJson({
          ...partial.toJson(),
          'feature': '새로 확인된 특징입니다.',
          'detailNeedsRetry': false,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('새로 확인된 특징입니다.'), findsOneWidget);
      expect(find.text('일부 정보를 불러오지 못했습니다.'), findsNothing);
      expect(find.text('특징을 불러오지 못했습니다. 다시 시도해 주세요.'), findsNothing);
    },
  );

  testWidgets('offline partial photos use the offline explanation', (
    tester,
  ) async {
    const partial = FishSpecies(
      id: 'offline-partial',
      name: '오프라인 확인 어종',
      detailNeedsRetry: true,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FishSpeciesPhoto(fish: partial, allowNetwork: false),
        ),
      ),
    );
    expect(find.text('오프라인에서는 사진을 불러올 수 없습니다.'), findsOneWidget);
    expect(find.text('사진이 없습니다.'), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('detail size is derived from cached prose while offline', (
    tester,
  ) async {
    const fish = FishSpecies(
      id: 'sized-fish',
      name: '크기 확인 어종',
      feature: '몸은 은빛이다. 수컷의 최대 전장은 약 10cm이다.',
    );
    final repository = _Repository();
    repository.onDetail = (_, _, _) async =>
        throw const FishCatalogException(FishCatalogFailure.network);
    final network = _NetworkStatus(disconnected: true);
    addTearDown(network.dispose);
    _largeView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: FishSpeciesDetailPage(
          fish: fish,
          repository: repository,
          networkStatus: network,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final infoCard = find
        .ancestor(of: find.text('크기'), matching: find.byType(Card))
        .first;
    expect(
      find.descendant(of: infoCard, matching: find.textContaining('10cm')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: infoCard, matching: find.textContaining('수컷')),
      findsOneWidget,
    );
    expect(find.text(fish.feature), findsOneWidget);
    expect(repository.detailCalls.single.allowNetwork, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached drawing is hidden and replaced by a list photo request', (
    tester,
  ) async {
    final illustrated = FishSpecies.fromJson({
      ..._seaFish.toJson(),
      'imageUrl': 'https://upload.wikimedia.org/fish.jpeg',
      'photoSourceUrl':
          'https://commons.wikimedia.org/wiki/File:Fish_pencil_drawing.jpeg',
    });
    final pending = Completer<FishSpecies>();
    final repository = _Repository();
    repository.onLoad = (_, _) async => _snapshot(items: [illustrated]);
    repository.onThumbnail = (_, _, _) => pending.future;
    final network = _NetworkStatus();
    addTearDown(network.dispose);
    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();
    expect(repository.thumbnailCalls, hasLength(1));
    expect(find.byType(Image), findsNothing);
    pending.complete(_withThumbnail(_seaFish));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FishSpeciesPhoto>(find.byType(FishSpeciesPhoto))
          .fish
          .imageUrl,
      _withThumbnail(_seaFish).imageUrl,
    );
    expect(find.byType(Image), findsOneWidget);
  });

  test(
    'thumbnail owner replacement respects name changes and ignores invalid photos',
    () async {
      final names = <String>[];
      final loader = FishThumbnailLoader(
        request: (fish, {bool forceRefresh = false}) async {
          names.add(fish.name);
          return fish;
        },
      );
      addTearDown(loader.dispose);
      final owner = Object();
      loader.attach(
        owner: owner,
        fish: _seaFish,
        isVisible: () => true,
        onResult: (_) {},
      );
      final renamed = FishSpecies(
        id: _seaFish.id,
        name: '갱신된 어종명',
        scientificName: _seaFish.scientificName,
        imageUrl: 'https://user:secret@example.org/fish.jpg',
      );
      expect(hasFishThumbnail(renamed), isFalse);
      loader.attach(
        owner: owner,
        fish: renamed,
        isVisible: () => true,
        onResult: (_) {},
      );
      loader.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(names, ['갱신된 어종명']);
    },
  );

  testWidgets(
    'visible thumbnails load before detail with two lookups and pause on navigation',
    (tester) async {
      final items = _thumbnailItems(30);
      final pending = <String, Completer<FishSpecies>>{};
      final repository = _Repository();
      repository.onLoad = (_, _) async => _snapshot(items: items);
      repository.onThumbnail = (fish, _, _) =>
          (pending[fish.id] ??= Completer<FishSpecies>()).future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(2));
      expect(repository.detailCalls, isEmpty);

      final first = items.first;
      pending[first.id]!.complete(_withThumbnail(first));
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(3));
      expect(repository.loadCalls, hasLength(1));
      expect(
        tester
            .widgetList<FishSpeciesPhoto>(find.byType(FishSpeciesPhoto))
            .firstWhere((photo) => photo.fish.id == first.id)
            .fish
            .imageUrl,
        _withThumbnail(first).imageUrl,
      );
      expect(repository.detailCalls, isEmpty);

      await tester.tap(find.text(first.name));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FishSpeciesDetailPage>(find.byType(FishSpeciesDetailPage))
            .fish
            .imageUrl,
        _withThumbnail(first).imageUrl,
      );
      for (final request in repository.thumbnailCalls.skip(1).toList()) {
        pending[request.id]!.complete(
          _withThumbnail(items.firstWhere((fish) => fish.id == request.id)),
        );
      }
      await tester.pumpAndSettle();
      expect(
        repository.thumbnailCalls,
        hasLength(3),
        reason: 'Covered list must not start queued rows.',
      );
    },
  );

  testWidgets(
    'filtering cancels queued rows and disposed thumbnail callbacks are ignored',
    (tester) async {
      final items = _thumbnailItems(30);
      final pending = <String, Completer<FishSpecies>>{};
      final repository = _Repository();
      repository.onLoad = (_, _) async => _snapshot(items: items);
      repository.onThumbnail = (fish, _, _) =>
          (pending[fish.id] ??= Completer<FishSpecies>()).future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(2));
      await tester.enterText(find.byType(TextField), items.last.scientificName);
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(2));
      for (final request in repository.thumbnailCalls.toList()) {
        pending[request.id]!.complete(
          _withThumbnail(items.firstWhere((fish) => fish.id == request.id)),
        );
      }
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls.map((call) => call.id), [
        items[0].id,
        items[1].id,
        items.last.id,
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      pending[items.last.id]!.complete(_withThumbnail(items.last));
      await tester.pump();
      expect(repository.thumbnailCalls, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inactive and offline rows avoid lookup and cached URLs avoid metadata',
    (tester) async {
      final items = _thumbnailItems(3);
      items[0] = _withThumbnail(items[0]);
      final repository = _Repository()
        ..onLoad = (_, _) async => _snapshot(items: items);
      final network = _NetworkStatus(disconnected: true);
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network, isActive: false),
      );
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, isEmpty);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, isEmpty);
      expect(
        tester
            .widgetList<FishSpeciesPhoto>(find.byType(FishSpeciesPhoto))
            .firstWhere((photo) => photo.fish.id == items.first.id)
            .fish
            .imageUrl,
        items.first.imageUrl,
      );
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(2));
      expect(
        repository.thumbnailCalls.map((call) => call.id),
        isNot(contains(items.first.id)),
      );
    },
  );

  testWidgets(
    'thumbnail failure retries once on recovery and can be forced by refresh',
    (tester) async {
      final fish = _thumbnailItems(1).single;
      var attempt = 0;
      final repository = _Repository();
      repository.onLoad = (_, _) async => _snapshot(items: [fish]);
      repository.onThumbnail = (fish, _, _) async {
        if (++attempt < 3) {
          throw const FishCatalogException(FishCatalogFailure.network);
        }
        return _withThumbnail(fish);
      };
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(1));
      expect(find.text(fish.name), findsOneWidget);
      network.setDisconnected(true);
      await tester.pumpAndSettle();
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(2));
      network.setDisconnected(true);
      await tester.pumpAndSettle();
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(2));
      await tester.tap(find.byTooltip('새로고침'));
      await tester.pumpAndSettle();
      expect(repository.thumbnailCalls, hasLength(3));
      expect(repository.thumbnailCalls.last.forceRefresh, isTrue);
      expect(
        tester
            .widget<FishSpeciesPhoto>(find.byType(FishSpeciesPhoto))
            .fish
            .imageUrl,
        _withThumbnail(fish).imageUrl,
      );
      expect(repository.detailCalls, isEmpty);
    },
  );

  testWidgets(
    'cold offline start shows all 800 real bundled species without keys',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      expect(const FishApiConfiguration().isCatalogConfigured, isFalse);
      expect(const FishApiConfiguration().isDetailConfigured, isFalse);
      final repository = FishSpeciesRepository();
      final network = _NetworkStatus(disconnected: true);
      addTearDown(network.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: FishDictionaryPage(
            repository: repository,
            networkStatus: network,
          ),
        ),
      );
      // Allow the real asset's isolate and platform I/O to finish between frames.
      await tester.runAsync(() async {
        for (var frame = 0; frame < 250; frame++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('기본 어종 자료 800종'), findsOneWidget);
      expect(find.text('출처: 국립수산과학원'), findsNothing);
      expect(find.text('오프라인입니다. 앱에 포함된 기본 자료를 표시합니다.'), findsOneWidget);
      expect(find.text('가고시마샛멸'), findsOneWidget);
      expect(
        tester.widget<ListView>(find.byType(ListView)).semanticChildCount,
        800,
      );
      expect(find.textContaining('연결 설정'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.enterText(
        find.byType(TextField),
        'Acanthopagrus schlegelii',
      );
      await tester.pump();
      expect(find.text('감성돔'), findsOneWidget);
      expect(
        tester.widget<ListView>(find.byType(ListView)).semanticChildCount,
        1,
      );
    },
  );

  testWidgets(
    'bundled notice uses the data date and keeps setup errors out of usable data',
    (tester) async {
      final repository = _Repository()
        ..onLoad = (_, _) async => _snapshot(
          isBundled: true,
          dataUpdatedAt: DateTime.utc(2025, 5, 23),
          failure: FishCatalogFailure.configuration,
        );
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();

      expect(find.text('기본 어종 자료 3종 · 2025.05.23 기준'), findsOneWidget);
      expect(find.text('최신 자료를 확인하지 못해 앱에 포함된 기본 자료를 표시합니다.'), findsOneWidget);
      expect(find.textContaining('연결 설정'), findsNothing);
      expect(find.text(_seaFish.name), findsOneWidget);
    },
  );

  testWidgets(
    'local bundle remains usable when connectivity drops during load',
    (tester) async {
      final pending = Completer<FishCatalogSnapshot>();
      final repository = _Repository()..onLoad = (_, _) => pending.future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );

      network.setDisconnected(true);
      await tester.pump();
      pending.complete(_snapshot(isBundled: true));
      await tester.pumpAndSettle();

      expect(find.text(_seaFish.name), findsOneWidget);
      expect(find.textContaining('기본 어종 자료 3종'), findsOneWidget);
      expect(find.text('오프라인입니다. 앱에 포함된 기본 자료를 표시합니다.'), findsOneWidget);
      expect(repository.loadCalls, hasLength(1));
      expect(repository.detailCalls, isEmpty);
    },
  );

  testWidgets(
    'bundled catalog fits a small screen with keyboard and large text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = _Repository()
        ..onLoad = (_, _) async => _snapshot(isBundled: true);
      final network = _NetworkStatus(disconnected: true);
      addTearDown(network.dispose);

      for (final scale in [1.0, 2.0]) {
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: FishDictionaryPage(
              repository: repository,
              networkStatus: network,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('기본 어종 자료'), findsOneWidget);
        expect(tester.takeException(), isNull);

        tester.view.viewInsets = const FakeViewPadding(bottom: 360);
        await tester.tap(find.byType(TextField));
        await tester.enterText(find.byType(TextField), '감성');
        await tester.pumpAndSettle();

        expect(find.textContaining('기본 어종 자료'), findsNothing);
        expect(find.text(_seaFish.name), findsOneWidget);
        expect(find.byType(ListView), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'text scale $scale');
      }
    },
  );

  testWidgets(
    'detail keeps photo and description while source metadata stays hidden',
    (tester) async {
      const photoSource =
          'https://commons.wikimedia.org/wiki/File:Black_seabream.jpg';
      const photoLicense = 'https://creativecommons.org/licenses/by/4.0/';
      const descriptionSource =
          'https://en.wikipedia.org/wiki/Blackhead_seabream';
      const fish = FishSpecies(
        id: 'credited-fish',
        name: '감성돔',
        scientificName: 'Acanthopagrus schlegelii',
        imageUrl: 'https://upload.wikimedia.org/black-seabream.jpg',
        photoAttribution: 'Example photographer · CC BY 4.0',
        photoSourceUrl: photoSource,
        photoLicenseUrl: photoLicense,
        feature: '연안에 서식하는 어종입니다.',
        descriptionAttribution: 'Wikipedia contributors · CC BY-SA 4.0',
        descriptionSourceUrl: descriptionSource,
        sourceName: '국립수산과학원',
        sourceUrl: 'https://www.nifs.go.kr/openApi/actionOpenapiInfoList.do',
      );
      final network = _NetworkStatus(disconnected: true);
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: fish,
            repository: _Repository(),
            networkStatus: network,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Example photographer · CC BY 4.0'), findsNothing);
      expect(find.widgetWithText(SelectableText, photoSource), findsNothing);
      expect(find.widgetWithText(SelectableText, photoLicense), findsNothing);
      expect(find.text('Wikipedia contributors · CC BY-SA 4.0'), findsNothing);
      expect(
        find.widgetWithText(SelectableText, descriptionSource),
        findsNothing,
      );
      expect(find.text(fish.sourceName), findsNothing);
      expect(find.text(fish.sourceUrl!), findsNothing);
      expect(find.text('자료 출처'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text(fish.feature), findsOneWidget);
      expect(find.text('이 어종으로 기록 작성하기'), findsOneWidget);
      expect(
        tester
            .widget<FishSpeciesPhoto>(find.byType(FishSpeciesPhoto))
            .fish
            .imageUrl,
        fish.imageUrl,
      );
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('NARIS'), findsNothing);
    },
  );

  testWidgets(
    'missing photo and description do not display unrelated credits',
    (tester) async {
      const fish = FishSpecies(
        id: 'unavailable-fish',
        name: '미확인어',
        photoAttribution: 'unrelated photo author',
        photoSourceUrl: 'https://commons.wikimedia.org/wiki/File:Unrelated.jpg',
        photoLicenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
        descriptionAttribution: 'unrelated description author',
        descriptionSourceUrl: 'https://en.wikipedia.org/wiki/Unrelated',
      );
      final network = _NetworkStatus(disconnected: true);
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: fish,
            repository: _Repository(),
            networkStatus: network,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('사진이 없습니다.'), findsOneWidget);
      expect(find.textContaining('unrelated'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('제공되지 않음'), findsWidgets);
    },
  );

  testWidgets(
    'guest can read detail and sees the record authentication guard',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final auth = AuthSessionRepository.instance;
      auth.resetAuthGatewayForTesting();
      addTearDown(auth.resetAuthGatewayForTesting);
      await auth.setSessionForTesting(plan: UserPlan.guest);
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: _seaFish,
            repository: _Repository(),
            networkStatus: network,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('도미과'), findsOneWidget);

      await tester.tap(find.text('이 어종으로 기록 작성하기'));
      await tester.pumpAndSettle();
      expect(find.text('로그인이 필요합니다'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(RecordFormPage), findsNothing);
      await tester.tap(find.text('나중에'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('member record form receives the selected official fish name', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    final auth = AuthSessionRepository.instance;
    auth.resetAuthGatewayForTesting();
    addTearDown(auth.resetAuthGatewayForTesting);
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'fish-dictionary-flow@example.com',
    );
    final network = _NetworkStatus();
    addTearDown(network.dispose);
    _largeView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: FishSpeciesDetailPage(
          fish: _seaFish,
          repository: _Repository(),
          networkStatus: network,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('이 어종으로 기록 작성하기'));
    await tester.pumpAndSettle();

    final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
    expect(form.initialFishName, _seaFish.name);
    final fishField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '어종',
    );
    await tester.scrollUntilVisible(
      fishField,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<TextField>(fishField).controller?.text, _seaFish.name);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'inactive dictionary loads lazily and rechecks freshness on return',
    (tester) async {
      final repository = _Repository();
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network, isActive: false),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, isEmpty);

      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, hasLength(1));
      expect(find.text(_seaFish.name), findsOneWidget);

      await tester.pumpWidget(
        _dictionary(repository: repository, network: network, isActive: false),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, [
        (forceRefresh: false, allowNetwork: true),
        (forceRefresh: false, allowNetwork: true),
      ]);
    },
  );

  testWidgets(
    'hidden pending catalog settles and waits to retry until active',
    (tester) async {
      final pending = Completer<FishCatalogSnapshot>();
      final repository = _Repository()..onLoad = (_, _) => pending.future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      expect(repository.loadCalls, hasLength(1));

      await tester.pumpWidget(
        _dictionary(repository: repository, network: network, isActive: false),
      );
      await tester.pumpAndSettle();
      network.setDisconnected(true);
      await tester.pumpAndSettle();
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(repository.loadCalls, hasLength(1));

      pending.completeError(
        const FishCatalogException(FishCatalogFailure.timedOut),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, hasLength(1));

      repository.onLoad = (_, _) async => _snapshot();
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, hasLength(2));
      expect(repository.loadCalls.last.forceRefresh, isTrue);
      expect(find.text(_seaFish.name), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reactivating a catalog delegates TTL checks to the repository', (
    tester,
  ) async {
    final repository = _Repository();
    var attempts = 0;
    repository.onLoad = (_, _) async =>
        _snapshot(isFromCache: attempts == 0, isStale: attempts++ == 0);
    final network = _NetworkStatus();
    addTearDown(network.dispose);
    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();
    expect(repository.loadCalls, hasLength(1));

    await tester.pumpWidget(
      _dictionary(repository: repository, network: network, isActive: false),
    );
    await tester.pumpAndSettle();
    expect(repository.loadCalls, hasLength(1));
    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();
    expect(repository.loadCalls, hasLength(2));
    expect(repository.loadCalls.last.forceRefresh, isFalse);

    await tester.pumpWidget(
      _dictionary(repository: repository, network: network, isActive: false),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();
    expect(repository.loadCalls, hasLength(3));
    expect(repository.loadCalls.every((call) => !call.forceRefresh), isTrue);
  });

  testWidgets('photos reject insecure and credential-bearing URLs', (
    tester,
  ) async {
    for (final url in [
      'http://example.invalid/fish.jpg',
      'https://name:password@example.invalid/fish.jpg',
      'file:///fish.jpg',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FishSpeciesPhoto(
              fish: FishSpecies(id: 'photo-fish', name: '사진 어종', imageUrl: url),
            ),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing, reason: url);
      expect(find.text('사진이 없습니다.'), findsOneWidget, reason: url);
    }
  });

  testWidgets(
    'photos preserve the complete image and bound decoded dimensions',
    (tester) async {
      const withPhoto = FishSpecies(
        id: 'photo-fish',
        name: '사진 어종',
        imageUrl: 'https://example.invalid/fish.jpg',
      );
      for (final compact in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FishSpeciesPhoto(
                fish: withPhoto,
                height: 220,
                compact: compact,
              ),
            ),
          ),
        );
        final photo = tester.widget<Image>(find.byType(Image));
        expect(photo.fit, BoxFit.contain);
        expect(photo.semanticLabel, '사진 어종 사진');
        final resized = photo.image as ResizeImage;
        final bound = compact ? 160 : 1200;
        expect(resized.policy, ResizeImagePolicy.fit);
        expect(resized.width, inInclusiveRange(1, bound));
        expect(resized.height, inInclusiveRange(1, bound));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('photos offer an offline placeholder without a network image', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FishSpeciesPhoto(
            fish: FishSpecies(
              id: 'photo-fish',
              name: '사진 어종',
              imageUrl: 'https://example.invalid/fish.jpg',
            ),
            allowNetwork: false,
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('오프라인에서는 사진을 불러올 수 없습니다.'), findsOneWidget);
  });

  testWidgets(
    'shows loading before the catalog and never requests item details',
    (tester) async {
      final pending = Completer<FishCatalogSnapshot>();
      final repository = _Repository()..onLoad = (_, _) => pending.future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);

      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(_seaFish.name), findsNothing);

      pending.complete(_snapshot());
      await tester.pumpAndSettle();

      expect(find.text(_seaFish.name), findsOneWidget);
      expect(find.text(_freshwaterFish.name), findsOneWidget);
      expect(find.text(_unknownFish.name), findsOneWidget);
      expect(repository.loadCalls, hasLength(1));
      expect(repository.detailCalls, isEmpty);
    },
  );

  testWidgets('Korean, scientific names, and aliases are searched locally', (
    tester,
  ) async {
    final repository = _Repository();
    final network = _NetworkStatus();
    addTearDown(network.dispose);
    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();

    for (final query in ['감성', 'ACANTHOPAGRUS', '감숭어']) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.text(_seaFish.name), findsOneWidget, reason: query);
      expect(find.text(_freshwaterFish.name), findsNothing, reason: query);
      expect(find.text(_unknownFish.name), findsNothing, reason: query);
    }

    await tester.enterText(find.byType(TextField), '없는 어종');
    await tester.pump();
    expect(find.text(_seaFish.name), findsNothing);
    expect(find.textContaining('검색 결과'), findsOneWidget);
    expect(repository.loadCalls, hasLength(1));
    expect(repository.detailCalls, isEmpty);
  });

  testWidgets('sea and freshwater filters exclude unclassified species', (
    tester,
  ) async {
    final repository = _Repository();
    final network = _NetworkStatus();
    addTearDown(network.dispose);
    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '바다'));
    await tester.pump();
    expect(find.text(_seaFish.name), findsOneWidget);
    expect(find.text(_freshwaterFish.name), findsNothing);
    expect(find.text(_unknownFish.name), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '민물'));
    await tester.pump();
    expect(find.text(_seaFish.name), findsNothing);
    expect(find.text(_freshwaterFish.name), findsOneWidget);
    expect(find.text(_unknownFish.name), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '전체'));
    await tester.pump();
    expect(find.text(_unknownFish.name), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '금어기'), findsNothing);
    expect(repository.loadCalls, hasLength(1));
    expect(repository.detailCalls, isEmpty);
  });

  testWidgets('catalog failure can be retried with a forced request', (
    tester,
  ) async {
    final repository = _Repository();
    var attempt = 0;
    repository.onLoad = (_, _) async {
      if (attempt++ == 0) {
        throw const FishCatalogException(FishCatalogFailure.unauthorized);
      }
      return _snapshot();
    };
    final network = _NetworkStatus();
    addTearDown(network.dispose);

    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();
    expect(find.text(_seaFish.name), findsNothing);
    expect(find.text('다시 시도'), findsOneWidget);

    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text(_seaFish.name), findsOneWidget);
    expect(repository.loadCalls, [
      (forceRefresh: false, allowNetwork: true),
      (forceRefresh: true, allowNetwork: true),
    ]);
  });

  testWidgets('offline catalog requests cached data and explains its age', (
    tester,
  ) async {
    final repository = _Repository()
      ..onLoad = (_, _) async => _snapshot(isFromCache: true, isStale: true);
    final network = _NetworkStatus(disconnected: true);
    addTearDown(network.dispose);

    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();

    expect(find.text(_seaFish.name), findsOneWidget);
    expect(find.textContaining('저장된 어종 정보'), findsOneWidget);
    expect(repository.loadCalls.single.allowNetwork, isFalse);
    expect(repository.detailCalls, isEmpty);
  });

  testWidgets('opening a species requests only that species detail once', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onDetail = (_, _, _) async {
      repository.onLoad = (_, _) async => _snapshot(
        items: [_enrichedSeaFish, _freshwaterFish, _unknownFish],
        isFromCache: true,
      );
      return _enrichedSeaFish;
    };
    final network = _NetworkStatus();
    addTearDown(network.dispose);
    await tester.pumpWidget(
      _dictionary(repository: repository, network: network),
    );
    await tester.pumpAndSettle();

    expect(repository.detailCalls, isEmpty);
    await tester.tap(find.text(_seaFish.name));
    await tester.pumpAndSettle();

    expect(find.byType(FishSpeciesDetailPage), findsOneWidget);
    expect(repository.detailCalls, hasLength(1));
    expect(repository.detailCalls.single.id, _seaFish.id);
    expect(repository.loadCalls, hasLength(1));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(repository.loadCalls, [
      (forceRefresh: false, allowNetwork: true),
      (forceRefresh: false, allowNetwork: false),
    ]);
    expect(repository.detailCalls, hasLength(1));
    expect(find.textContaining('갱신된 분류'), findsOneWidget);
  });

  testWidgets(
    'catalog ignores a disconnected request and retries on reconnect',
    (tester) async {
      final pending = Completer<FishCatalogSnapshot>();
      final repository = _Repository()..onLoad = (_, _) => pending.future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );

      network.setDisconnected(true);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('다시 시도'), findsOneWidget);
      network.setDisconnected(true);
      await tester.pump();
      expect(repository.loadCalls, hasLength(1));

      pending.complete(_snapshot());
      await tester.pumpAndSettle();
      expect(find.text(_seaFish.name), findsNothing);
      expect(find.text('다시 시도'), findsOneWidget);

      repository.onLoad = (_, _) async => _snapshot();
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(find.text(_seaFish.name), findsOneWidget);
      expect(repository.loadCalls, [
        (forceRefresh: false, allowNetwork: true),
        (forceRefresh: true, allowNetwork: true),
      ]);
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(repository.loadCalls, hasLength(2));
    },
  );

  testWidgets(
    'detail ignores a disconnected response and retries on reconnect',
    (tester) async {
      final pending = Completer<FishSpecies>();
      final repository = _Repository()..onDetail = (_, _, _) => pending.future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: _seaFish,
            repository: repository,
            networkStatus: network,
          ),
        ),
      );

      network.setDisconnected(true);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('도미과'), findsOneWidget);
      expect(find.text('상세 정보 다시 시도'), findsOneWidget);
      network.setDisconnected(true);
      await tester.pump();
      expect(repository.detailCalls, hasLength(1));

      pending.complete(_enrichedSeaFish);
      await tester.pumpAndSettle();
      expect(find.text(_enrichedSeaFish.feature), findsNothing);
      expect(find.text('도미과'), findsOneWidget);

      repository.onDetail = (_, _, _) async => _enrichedSeaFish;
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(find.text(_enrichedSeaFish.feature), findsOneWidget);
      expect(repository.detailCalls, hasLength(2));
      expect(repository.detailCalls.last.forceRefresh, isTrue);
      expect(repository.detailCalls.last.allowNetwork, isTrue);
      network.setDisconnected(false);
      await tester.pumpAndSettle();
      expect(repository.detailCalls, hasLength(2));
    },
  );

  testWidgets(
    'partial detail can be refreshed without losing valid content on failure',
    (tester) async {
      const partial = FishSpecies(
        id: 'sea-1',
        name: '감성돔',
        category: FishCategory.sea,
        family: '도미과',
        scientificName: 'Acanthopagrus schlegelii',
        feature: '이미 제공된 설명입니다.',
      );
      final repository = _Repository()..onDetail = (_, _, _) async => partial;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: _seaFish,
            repository: repository,
            networkStatus: network,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(partial.feature), findsOneWidget);
      expect(find.text('상세 정보 다시 시도'), findsNothing);

      final pending = Completer<FishSpecies>();
      repository.onDetail = (_, _, _) => pending.future;
      final refreshButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '상세 정보 새로고침',
      );
      await tester.tap(refreshButton);
      await tester.pump();

      expect(repository.detailCalls, hasLength(2));
      expect(repository.detailCalls.last.forceRefresh, isTrue);
      expect(repository.detailCalls.last.allowNetwork, isTrue);
      expect(find.text(partial.feature), findsOneWidget);
      expect(find.text('도미과'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(tester.widget<IconButton>(refreshButton).onPressed, isNull);

      pending.completeError(
        const FishCatalogException(FishCatalogFailure.network),
      );
      await tester.pumpAndSettle();

      expect(find.text(partial.feature), findsOneWidget);
      expect(find.text('도미과'), findsOneWidget);
      expect(find.text('상세 정보 다시 시도'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.widget<IconButton>(refreshButton).onPressed, isNotNull);
      expect(find.text('이 어종으로 기록 작성하기'), findsOneWidget);
      expect(find.text('자료 출처'), findsNothing);
    },
  );

  testWidgets(
    'detail keeps base information on failure and enriches on retry',
    (tester) async {
      final pending = Completer<FishSpecies>();
      final repository = _Repository()..onDetail = (_, _, _) => pending.future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: _seaFish,
            repository: repository,
            networkStatus: network,
          ),
        ),
      );

      expect(find.text('도미과'), findsOneWidget);
      expect(find.textContaining('기록 작성'), findsOneWidget);
      pending.completeError(
        const FishCatalogException(FishCatalogFailure.timedOut),
      );
      await tester.pumpAndSettle();
      expect(find.text('도미과'), findsOneWidget);
      expect(find.text('상세 정보 다시 시도'), findsOneWidget);
      expect(find.text('제공되지 않음'), findsWidgets);

      repository.onDetail = (_, _, _) async => const FishSpecies(
        id: 'sea-1',
        name: '감성돔',
        category: FishCategory.sea,
        family: '도미과',
        scientificName: 'Acanthopagrus schlegelii',
        feature: '연안에 서식하는 어종입니다.',
        sourceName: '국립생물자원관 NARIS',
      );
      await tester.tap(find.text('상세 정보 다시 시도'));
      await tester.pumpAndSettle();

      expect(find.text('연안에 서식하는 어종입니다.'), findsOneWidget);
      expect(find.text('상세 정보 다시 시도'), findsNothing);
      expect(repository.detailCalls, hasLength(2));
      expect(repository.detailCalls.last.forceRefresh, isTrue);
    },
  );

  testWidgets(
    'catalog request completing after disposal does not update state',
    (tester) async {
      final pending = Completer<FishCatalogSnapshot>();
      final repository = _Repository()..onLoad = (_, _) => pending.future;
      final network = _NetworkStatus();
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _dictionary(repository: repository, network: network),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete(_snapshot());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline detail keeps unknown habitat and missing data truthful',
    (tester) async {
      final repository = _Repository()
        ..onDetail = (_, _, _) async {
          throw const FishCatalogException(FishCatalogFailure.network);
        };
      final network = _NetworkStatus(disconnected: true);
      addTearDown(network.dispose);
      _largeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: FishSpeciesDetailPage(
            fish: _unknownFish,
            repository: repository,
            networkStatus: network,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(repository.detailCalls.single.allowNetwork, isFalse);
      expect(find.text('서식 수역 정보 없음'), findsOneWidget);
      expect(find.text('제공되지 않음'), findsWidgets);
      expect(find.text('금어기 없음'), findsNothing);
      expect(find.text('연중 포획 가능'), findsNothing);
    },
  );

  testWidgets('detail request failing after disposal does not update state', (
    tester,
  ) async {
    final pending = Completer<FishSpecies>();
    final repository = _Repository()..onDetail = (_, _, _) => pending.future;
    final network = _NetworkStatus();
    addTearDown(network.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FishSpeciesDetailPage(
          fish: _seaFish,
          repository: repository,
          networkStatus: network,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(
      const FishCatalogException(FishCatalogFailure.network),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Widget _dictionary({
  required FishSpeciesRepository repository,
  required NetworkStatusService network,
  bool isActive = true,
}) => MaterialApp(
  home: FishDictionaryPage(
    repository: repository,
    networkStatus: network,
    isActive: isActive,
  ),
);

List<FishSpecies> _thumbnailItems(int count) => [
  for (var index = 0; index < count; index++)
    FishSpecies(
      id: 'thumbnail-$index',
      name: '대상어종 $index',
      scientificName: 'Testus fish$index',
    ),
];

FishSpecies _withThumbnail(FishSpecies fish) => FishSpecies.fromJson({
  ...fish.toJson(),
  'imageUrl': 'https://upload.wikimedia.org/${fish.id}.jpg',
});

void _largeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Repository extends FishSpeciesRepository {
  Future<FishCatalogSnapshot> Function(bool forceRefresh, bool allowNetwork)
  onLoad = (_, _) async => _snapshot();
  Future<FishSpecies> Function(
    FishSpecies fish,
    bool forceRefresh,
    bool allowNetwork,
  )
  onDetail = (fish, _, _) async => fish;
  Future<FishSpecies> Function(
    FishSpecies fish,
    bool forceRefresh,
    bool allowNetwork,
  )
  onThumbnail = (fish, _, _) async => fish;

  final loadCalls = <({bool forceRefresh, bool allowNetwork})>[];
  final detailCalls = <({String id, bool forceRefresh, bool allowNetwork})>[];
  final thumbnailCalls =
      <({String id, bool forceRefresh, bool allowNetwork})>[];

  @override
  Future<FishSpecies> thumbnail(
    FishSpecies fish, {
    bool forceRefresh = false,
    bool allowNetwork = true,
  }) {
    thumbnailCalls.add((
      id: fish.id,
      forceRefresh: forceRefresh,
      allowNetwork: allowNetwork,
    ));
    return onThumbnail(fish, forceRefresh, allowNetwork);
  }

  @override
  Future<FishCatalogSnapshot> load({
    bool forceRefresh = false,
    bool allowNetwork = true,
  }) {
    loadCalls.add((forceRefresh: forceRefresh, allowNetwork: allowNetwork));
    return onLoad(forceRefresh, allowNetwork);
  }

  @override
  Future<FishSpecies> detail(
    FishSpecies fish, {
    bool forceRefresh = false,
    bool allowNetwork = true,
  }) {
    detailCalls.add((
      id: fish.id,
      forceRefresh: forceRefresh,
      allowNetwork: allowNetwork,
    ));
    return onDetail(fish, forceRefresh, allowNetwork);
  }
}

class _NetworkStatus extends NetworkStatusService {
  _NetworkStatus({this.disconnected = false});
  bool disconnected;

  void setDisconnected(bool value) {
    disconnected = value;
    notifyListeners();
  }

  @override
  bool get isDisconnected => disconnected;
}
