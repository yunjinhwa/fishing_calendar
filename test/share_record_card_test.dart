import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/personal_best_record.dart';
import 'package:fishing_build/data/models/share_record_data.dart';
import 'package:fishing_build/presentation/share/share_record_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'default card shows catch values and keeps extra details private',
    (tester) async {
      await _pumpCard(tester, _data());

      expect(find.text('최고 크기 기록'), findsOneWidget);
      expect(find.text('갈치'), findsOneWidget);
      expect(find.text('바다낚시인'), findsOneWidget);
      expect(find.text('50.0 cm'), findsOneWidget);
      expect(find.text('1000 g'), findsOneWidget);
      expect(find.text('출조 사진'), findsOneWidget);
      expect(find.text('사진 없음'), findsOneWidget);
      expect(find.text('FishingBuild'), findsOneWidget);
      expect(find.text('2026.11.08'), findsNothing);
      expect(find.text('제주항'), findsNothing);
      expect(find.textContaining('private-record-id'), findsNothing);
      final background = tester.widget<Image>(_backgroundImage());
      expect(background.excludeFromSemantics, isTrue);
      expect(background.fit, BoxFit.cover);
      expect(
        find.ancestor(
          of: _backgroundImage(),
          matching: find.byWidgetPredicate(
            (widget) => widget is IgnorePointer && widget.ignoring,
          ),
        ),
        findsOneWidget,
      );
      final provider = background.image as ResizeImage;
      expect(provider.width, 1080);
      expect(provider.height, 1080);
      expect(provider.policy, ResizeImagePolicy.fit);
      expect(provider.allowUpscaling, isFalse);
      final size = tester.getSize(find.byType(ShareRecordCard));
      expect(size.width, 360);
      expect(size.height, inInclusiveRange(500, 650));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('visibility options control each field and details are opt-in', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      _data(),
      options: const ShareRecordOptions(
        showNickname: false,
        showPhoto: false,
        showLength: false,
        showWeight: false,
        showDate: true,
        showLocation: true,
      ),
    );

    expect(find.text('바다낚시인'), findsNothing);
    expect(find.text('출조 사진'), findsNothing);
    expect(_photoImage(), findsNothing);
    expect(_backgroundImage(), findsOneWidget);
    expect(find.text('크기'), findsNothing);
    expect(find.text('무게'), findsNothing);
    expect(find.text('50.0 cm'), findsNothing);
    expect(find.text('1000 g'), findsNothing);
    expect(find.text('2026.11.08'), findsOneWidget);
    expect(find.text('제주항'), findsOneWidget);
    expect(tester.getSize(find.byType(ShareRecordCard)).height, 500);
    expect(tester.takeException(), isNull);

    await _pumpCard(
      tester,
      _data(),
      options: const ShareRecordOptions(showLength: false),
    );
    expect(find.text('크기'), findsNothing);
    expect(find.text('무게'), findsOneWidget);
    expect(find.text('1000 g'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both measurements always belong to the selected catch', (
    tester,
  ) async {
    final trip = FishingRecord(
      id: 'private-record-id',
      location: '제주항',
      startAt: DateTime(2026, 11, 8),
      endAt: DateTime(2026, 11, 8, 2),
      genreName: '바다낚시',
      catches: const [
        CatchRecord(speciesName: '갈치', lengthCm: 90, weightG: 500),
        CatchRecord(speciesName: '갈치', lengthCm: 60, weightG: 900),
      ],
    );
    for (final criterion in [
      PersonalBestSortType.length,
      PersonalBestSortType.weight,
    ]) {
      final record = PersonalBestRecord(
        speciesName: '갈치',
        lengthBest: PersonalBestEvidence(
          record: trip,
          catchRecord: trip.catches[0],
          catchIndex: 0,
        ),
        weightBest: PersonalBestEvidence(
          record: trip,
          catchRecord: trip.catches[1],
          catchIndex: 1,
        ),
        sortType: criterion,
      );
      await _pumpCard(
        tester,
        ShareRecordData.fromPersonalBest(record, nickname: '바다낚시인'),
      );
      final byLength = criterion == PersonalBestSortType.length;
      expect(find.text(byLength ? '최고 크기 기록' : '최고 무게 기록'), findsOneWidget);
      expect(find.text(byLength ? '90.0 cm' : '60.0 cm'), findsOneWidget);
      expect(find.text(byLength ? '500 g' : '900 g'), findsOneWidget);
      expect(find.text(byLength ? '900 g' : '90.0 cm'), findsNothing);
    }
  });

  testWidgets('missing measurements stay unmeasured and long text fits', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      _data(
        species: '아주 긴 어종 이름\n${'갈치' * 100}',
        nickname: '\u202E바다\n${'낚시인' * 100}',
        location: '제주\n${'긴 항구 이름 ' * 100}',
        length: double.nan,
        weight: 0,
      ),
      options: const ShareRecordOptions(showDate: true, showLocation: true),
    );

    expect(find.text('미측정'), findsNWidgets(2));
    expect(find.textContaining('NaN'), findsNothing);
    final texts = tester.widgetList<Text>(find.byType(Text));
    for (final text in texts) {
      expect(text.data, isNot(contains('\n')));
      expect(text.data, isNot(contains('\u202E')));
      expect(text.data!.runes.length, lessThanOrEqualTo(121));
    }
    final size = tester.getSize(find.byType(ShareRecordCard));
    expect(size.width, 360);
    expect(size.height, inInclusiveRange(500, 650));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'photo uses the supplied bytes with bounded proportional decode',
    (tester) async {
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(4, 2);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          return png!.buffer.asUint8List();
        } finally {
          image.dispose();
          picture.dispose();
        }
      });
      final data = _data(photo: bytes);
      await _pumpCard(tester, data);
      await tester.runAsync(
        () => precacheImage(
          ShareRecordCard.photoProvider(data.photoBytes!),
          tester.element(find.byType(ShareRecordCard)),
        ),
      );
      await tester.pump();

      final photo = tester.widget<Image>(_photoImage());
      final provider = photo.image as ResizeImage;
      expect(
        (provider.imageProvider as MemoryImage).bytes,
        same(data.photoBytes),
      );
      expect(provider.width, 1080);
      expect(provider.height, 1080);
      expect(provider.policy, ResizeImagePolicy.fit);
      expect(provider.allowUpscaling, isFalse);
      expect(photo.fit, BoxFit.contain);
      expect(find.text('사진 없음'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid photo has a neutral placeholder', (tester) async {
    final data = _data(photo: Uint8List.fromList([0, 1, 2, 3]));
    await _pumpCard(tester, data);
    await tester.runAsync(
      () => precacheImage(
        ShareRecordCard.photoProvider(data.photoBytes!),
        tester.element(find.byType(ShareRecordCard)),
        onError: (error, stackTrace) {},
      ),
    );
    await tester.pump();

    expect(find.text('사진 없음'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpCard(
  WidgetTester tester,
  ShareRecordData data, {
  ShareRecordOptions options = const ShareRecordOptions(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Center(
            child: ShareRecordCard(data: data, options: options),
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
  await tester.pump();
}

Finder _backgroundImage() => find.byWidgetPredicate(
  (widget) =>
      widget is Image && widget.image == ShareRecordCard.backgroundProvider,
);

Finder _photoImage() => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is ResizeImage &&
      (widget.image as ResizeImage).imageProvider is MemoryImage,
);

ShareRecordData _data({
  String species = '갈치',
  String nickname = '바다낚시인',
  String location = '제주항',
  double? length = 50,
  int? weight = 1000,
  Uint8List? photo,
}) => ShareRecordData(
  recordId: 'private-record-id',
  catchIndex: 3,
  speciesName: species,
  nickname: nickname,
  caughtAt: DateTime(2026, 11, 8),
  location: location,
  criterion: PersonalBestSortType.length,
  lengthCm: length,
  weightG: weight,
  photoBytes: photo,
);
