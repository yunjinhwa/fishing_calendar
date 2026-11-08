import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/personal_best_record.dart';
import 'package:fishing_build/data/models/share_record_data.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/personal_best_repository.dart';
import 'package:fishing_build/data/sharing/share_image_exporter.dart';
import 'package:fishing_build/presentation/personal_best/personal_best_detail_page.dart';
import 'package:fishing_build/presentation/share/share_image_capture.dart';
import 'package:fishing_build/presentation/share/share_record_card.dart';
import 'package:fishing_build/presentation/share/share_record_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  late ChangeNotifier changes;
  late List<FishingRecord> records;
  late PersonalBestRepository repository;
  late _Exporter exporter;
  var captures = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    auth.resetAuthGatewayForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'private@example.com',
    );
    changes = ChangeNotifier();
    records = [_record()];
    repository = PersonalBestRepository(recordsGetter: () => records);
    exporter = _Exporter();
    captures = 0;
  });
  tearDown(() => changes.dispose());

  Future<Uint8List> capture(GlobalKey key) async {
    captures++;
    return Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, captures]);
  }

  Widget page({
    ShareImageCapture? renderer,
    Future<Uint8List> Function(String)? reader,
  }) => ShareRecordPage(
    record: repository.getPersonalBests().single,
    repository: repository,
    recordChanges: changes,
    exporter: exporter,
    capture: renderer ?? capture,
    photoReader: reader,
  );

  testWidgets('preview is private; exports reuse PNG until options change', (
    tester,
  ) async {
    _surface(tester);
    await tester.pumpWidget(MaterialApp(home: page()));
    await _settleWithBackground(tester);
    expect(find.text('낚시인'), findsOneWidget);
    expect(find.textContaining('private@example.com'), findsNothing);
    expect(find.text('Secret pier'), findsNothing);
    expect(find.text('2026.11.01'), findsNothing);
    expect(exporter.saves, 0);
    expect(exporter.shares, 0);

    await tester.tap(find.text('이미지 저장'));
    await _settleWithBackground(tester);
    expect(exporter.saves, 1);
    expect(captures, 1);
    expect(find.text('이미지를 저장했습니다.'), findsOneWidget);
    expect(exporter.fileName, matches(RegExp(r'^FishingBuild_\d+\.png$')));

    await tester.tap(find.text('공유하기'));
    await _settleWithBackground(tester);
    expect(exporter.shares, 1);
    expect(exporter.origin?.isEmpty, isFalse);
    expect(captures, 1);
    expect(find.text('공유 앱을 선택했습니다.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '장소'));
    await _settleWithBackground(tester);
    expect(find.text('Secret pier'), findsOneWidget);
    await tester.tap(find.text('이미지 저장'));
    await _settleWithBackground(tester);
    expect(captures, 2);
    expect(exporter.saves, 2);
  });

  testWidgets('capture produces a decodable 1080px PNG of just the card', (
    tester,
  ) async {
    _surface(tester);
    final boundary = GlobalKey();
    final data = repository.getPersonalBests().single;
    // Exercise the production renderer, not the injectable fake used elsewhere.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.red,
          body: Center(
            child: RepaintBoundary(
              key: boundary,
              child: ShareRecordCard(data: _snapshot(data)),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        ShareRecordCard.backgroundProvider,
        tester.element(find.byType(ShareRecordCard)),
      ),
    );
    await _settleWithBackground(tester);
    await tester.runAsync(() async {
      final png = await captureShareImage(boundary);
      await File('.dart_tool/share_background_preview.png').writeAsBytes(png);
      expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await ui.instantiateImageCodec(png);
      try {
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, 1080);
          expect(frame.image.height, inInclusiveRange(1500, 1950));
          final pixels = await frame.image.toByteData();
          final rgba = pixels!.buffer.asUint8List();
          final bottomLeft = (frame.image.height - 1) * frame.image.width * 4;
          final sea = rgba.sublist(bottomLeft, bottomLeft + 4);
          expect(sea[3], 255);
          expect(sea[2], greaterThan(sea[0]));
          expect(sea, isNot([255, 255, 255, 255]));
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('photo finishes decoding before the first export is enabled', (
    tester,
  ) async {
    _surface(tester);
    records = [_record(photo: 'private/photo.png')];
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(4, 2);
      late Uint8List photo;
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        photo = bytes!.buffer.asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
      }
      await tester.pumpWidget(
        MaterialApp(home: page(reader: (_) async => photo)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await _settleWithBackground(tester);
    final card = tester.widget<ShareRecordCard>(find.byType(ShareRecordCard));
    expect(card.data.photoBytes, isNotNull);
    expect(find.text('사진 없음'), findsNothing);
    await tester.tap(find.text('이미지 저장'));
    await _settleWithBackground(tester);
    expect(exporter.saves, 1);
    expect(captures, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source edit during rendering blocks export and requires refresh',
    (tester) async {
      _surface(tester);
      final rendering = Completer<Uint8List>();
      await tester.pumpWidget(
        MaterialApp(home: page(renderer: (_) => rendering.future)),
      );
      await _settleWithBackground(tester);
      await tester.tap(find.text('이미지 저장'));
      await tester.pump();
      await tester.pump();
      records = [_record(length: 75)];
      changes.notifyListeners();
      await tester.pump();
      rendering.complete(Uint8List(9));
      await _settleWithBackground(tester);
      expect(exporter.saves, 0);
      expect(find.textContaining('기록이 변경되었거나 삭제되었습니다.'), findsOneWidget);
      expect(find.text('60.0 cm'), findsNothing);
      await tester.tap(find.text('최신 기록으로 새로고침'));
      await _settleWithBackground(tester);
      expect(find.text('75.0 cm'), findsOneWidget);
    },
  );

  testWidgets('back during capture cancels before the route is disposed', (
    tester,
  ) async {
    _surface(tester);
    final rendering = Completer<Uint8List>();
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => page(
                    renderer: (_) {
                      started = true;
                      return rendering.future;
                    },
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settleWithBackground(tester);
    await tester.tap(find.text('이미지 저장'));
    await tester.pump();
    await tester.pump();
    expect(started, isTrue);
    await tester.tap(find.byTooltip('Back'));
    rendering.complete(Uint8List(9));
    await _settleWithBackground(tester);
    expect(exporter.saves, 0);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'logout while a photo is loading hides the card and blocks export',
    (tester) async {
      _surface(tester);
      records = [_record(photo: 'private/photo.jpg')];
      final reading = Completer<Uint8List>();
      await tester.pumpWidget(
        MaterialApp(home: page(reader: (_) => reading.future)),
      );
      await tester.pump();
      await auth.setSessionForTesting(plan: UserPlan.guest);
      await tester.pump();
      reading.complete(Uint8List(0));
      await _settleWithBackground(tester);
      expect(find.text('계정 상태가 변경되어 공유를 중단했습니다.'), findsOneWidget);
      expect(find.text('Rockfish'), findsNothing);
      expect(find.text('공유하기'), findsNothing);
      expect(exporter.saves + exporter.shares, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed photo uses placeholder; export errors allow retry', (
    tester,
  ) async {
    _surface(tester);
    records = [_record(photo: 'private/missing.jpg')];
    await tester.pumpWidget(
      MaterialApp(
        home: page(reader: (_) async => throw StateError('private/path')),
      ),
    );
    await _settleWithBackground(tester);
    expect(find.text('사진 없음'), findsOneWidget);
    expect(find.textContaining('기본 표시로 대체'), findsOneWidget);
    exporter.failure = ShareImageExportFailure.permissionDenied;
    await tester.tap(find.text('이미지 저장'));
    await _settleWithBackground(tester);
    expect(find.textContaining('설정에서 권한을 허용'), findsOneWidget);
    expect(find.textContaining('private/path'), findsNothing);
    exporter.failure = null;
    exporter.result = ShareImageExportResult.cancelled;
    await tester.tap(find.text('이미지 저장'));
    await _settleWithBackground(tester);
    expect(find.text('저장을 취소했습니다.'), findsOneWidget);
    expect(find.text('이미지를 저장했습니다.'), findsNothing);
    expect(captures, 1);
    expect(exporter.saves, 2);
  });

  testWidgets('guest entry never reads repository or shows retained data', (
    tester,
  ) async {
    final retained = repository.getPersonalBests().single;
    await auth.setSessionForTesting(plan: UserPlan.guest);
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ShareRecordPage(
          record: retained,
          repository: PersonalBestRepository(
            recordsGetter: () {
              reads++;
              return records;
            },
          ),
          recordChanges: changes,
          exporter: exporter,
          capture: capture,
        ),
      ),
    );
    await _settleWithBackground(tester);
    expect(reads, 0);
    expect(find.text('Rockfish'), findsNothing);
    expect(exporter.saves + exporter.shares, 0);
  });

  testWidgets('detail opens the preview with the selected weight evidence', (
    tester,
  ) async {
    _surface(tester);
    records = [_record(), _record(id: 'weight', length: 40, weight: 1200)];
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalBestDetailPage(
          record: repository.getPersonalBests().single,
          repository: repository,
          recordChanges: changes,
        ),
      ),
    );
    await _settleWithBackground(tester);
    await tester.tap(find.text('무게 기록'));
    await _settleWithBackground(tester);
    await tester.ensureVisible(find.text('공유 이미지 미리보기'));
    await tester.tap(find.text('공유 이미지 미리보기'));
    await _settleWithBackground(tester);
    expect(find.byType(ShareRecordPage), findsOneWidget);
    expect(find.text('최고 무게 기록'), findsOneWidget);
    expect(find.text('40.0 cm'), findsOneWidget);
    expect(find.text('1200 g'), findsOneWidget);
    expect(find.text('60.0 cm'), findsNothing);
  });

  testWidgets('narrow screens and enlarged interface text have no overflow', (
    tester,
  ) async {
    _surface(tester, width: 320);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: page(),
      ),
    );
    await _settleWithBackground(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('이미지 저장'));
    await _settleWithBackground(tester);
    expect(exporter.saves, 1);
    expect(tester.takeException(), isNull);
  });
}

// Keep production snapshot construction in the actual PNG test as well.
ShareRecordData _snapshot(PersonalBestRecord record) =>
    ShareRecordData.fromPersonalBest(record, nickname: '낚시인');

Future<void> _settleWithBackground(WidgetTester tester) async {
  final card = find.byType(ShareRecordCard);
  if (card.evaluate().isNotEmpty) {
    await tester.runAsync(
      () => precacheImage(
        ShareRecordCard.backgroundProvider,
        tester.element(card),
      ),
    );
  }
  await tester.pumpAndSettle();
}

void _surface(WidgetTester tester, {double width = 900}) {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
}

FishingRecord _record({
  String id = 'length',
  double length = 60,
  int weight = 400,
  String? photo,
}) => FishingRecord(
  id: id,
  location: 'Secret pier',
  startAt: DateTime(2026, 11, 1, 8),
  endAt: DateTime(2026, 11, 1, 10),
  genreName: 'Lure',
  catches: [
    CatchRecord(speciesName: 'Rockfish', lengthCm: length, weightG: weight),
  ],
  photos: [if (photo != null) RecordPhoto(id: 'photo', localPath: photo)],
  memo: 'private@example.com',
);

class _Exporter implements ShareImageExporter {
  var saves = 0;
  var shares = 0;
  String? fileName;
  Rect? origin;
  ShareImageExportFailure? failure;
  ShareImageExportResult? result;

  @override
  Future<ShareImageExportResult> save(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
  }) async {
    expect(isCurrent?.call(), isTrue);
    saves++;
    this.fileName = fileName;
    if (failure != null) throw ShareImageExportException(failure!);
    return result ?? ShareImageExportResult.saved;
  }

  @override
  Future<ShareImageExportResult> share(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
    Rect? origin,
  }) async {
    expect(isCurrent?.call(), isTrue);
    shares++;
    this.origin = origin;
    this.fileName = fileName;
    if (failure != null) throw ShareImageExportException(failure!);
    return result ?? ShareImageExportResult.shared;
  }
}
