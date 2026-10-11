import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/presentation/record/record_detail_page.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('detail renders a device-local photo preview', (
    WidgetTester tester,
  ) async {
    _useTallSurface(tester);

    await tester.pumpWidget(
      MaterialApp(home: RecordDetailPage(record: _recordWithLocalPhoto())),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsNothing);
  });

  testWidgets('edit form keeps a device-local photo in its photo list', (
    WidgetTester tester,
  ) async {
    _useTallSurface(tester);

    await tester.pumpWidget(
      MaterialApp(home: RecordFormPage(editingRecord: _recordWithLocalPhoto())),
    );
    await tester.scrollUntilVisible(
      find.text('사진 추가 (1/10)'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('사진 추가 (1/10)'), findsOneWidget);
  });

  testWidgets('photo add offers album and camera without changing the list', (
    WidgetTester tester,
  ) async {
    _useTallSurface(tester);

    await tester.pumpWidget(
      MaterialApp(home: RecordFormPage(editingRecord: _recordWithLocalPhoto())),
    );
    await tester.scrollUntilVisible(
      find.text('사진 추가 (1/10)'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('사진 추가 (1/10)'));
    await tester.pumpAndSettle();

    expect(find.text('앨범에서 선택'), findsOneWidget);
    expect(find.text('카메라로 촬영'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('사진 추가 (1/10)'), findsOneWidget);
  });
}

void _useTallSurface(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
}

FishingRecord _recordWithLocalPhoto() {
  return FishingRecord(
    id: 'record_photo_ui',
    location: '테스트 방파제',
    startAt: DateTime(2026, 10, 4, 8),
    endAt: DateTime(2026, 10, 4, 10),
    genreName: '루어',
    tide: '3물',
    weather: '맑음',
    airTemperature: 20,
    waterTemperature: 18,
    photos: const <RecordPhoto>[
      RecordPhoto(
        id: 'local_photo',
        localPath: 'C:/missing/record_photo_ui.jpg',
        contentType: 'image/jpeg',
        sizeBytes: 1024,
        checksum:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    ],
  );
}
