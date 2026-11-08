import 'dart:io';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/personal_best_repository.dart';
import 'package:fishing_build/presentation/personal_best/personal_best_detail_page.dart';
import 'package:fishing_build/presentation/personal_best/personal_best_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final auth = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    auth.resetAuthGatewayForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'personal-best@example.com',
    );
  });

  testWidgets(
    'list keeps independent maxima and changes the source with sort',
    (tester) async {
      _useTallSurface(tester);
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      var records = [_lengthRecord(), _weightRecord()];
      var reads = 0;
      final repository = PersonalBestRepository(
        recordsGetter: () {
          reads++;
          return records;
        },
      );
      Widget page() => MaterialApp(
        home: PersonalBestPage(repository: repository, recordChanges: changes),
      );
      await tester.pumpWidget(page());
      await tester.pump();

      expect(
        find.textContaining('최고 크기 60.0 cm · 최고 무게 1200 g'),
        findsOneWidget,
      );
      expect(
        find.textContaining('크기 기록 · 2026.11.01 | Length pier'),
        findsOneWidget,
      );
      expect(_photoPath(tester), _lengthPhoto);
      expect(reads, 1);

      await tester.pumpWidget(page());
      await tester.pump();
      expect(
        reads,
        1,
        reason: 'An unrelated widget rebuild must not aggregate again.',
      );

      await tester.enterText(find.byType(TextField), '  rOcK  ');
      await tester.pump();
      expect(find.text('Rockfish'), findsOneWidget);
      expect(
        reads,
        1,
        reason: 'Search filters cached bests without reading records again.',
      );
      await tester.enterText(find.byType(TextField), 'not-a-species');
      await tester.pump();
      expect(find.text('검색 결과가 없습니다.'), findsOneWidget);
      expect(find.text('Rockfish'), findsNothing);
      await tester.tap(find.byTooltip('검색어 지우기'));
      await tester.pump();
      expect(find.text('Rockfish'), findsOneWidget);
      expect(reads, 1);
      await tester.enterText(find.byType(TextField), 'rock');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      await tester.tap(find.text('무게순'));
      await tester.pump();
      expect(
        find.textContaining('최고 크기 60.0 cm · 최고 무게 1200 g'),
        findsOneWidget,
      );
      expect(
        find.textContaining('무게 기록 · 2026.11.02 | Weight harbor'),
        findsOneWidget,
      );
      expect(_photoPath(tester), _weightPhoto);

      await tester.tap(find.text('이름순'));
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '이름순'))
            .selected,
        isTrue,
      );
      expect(
        find.textContaining('최고 크기 60.0 cm · 최고 무게 1200 g'),
        findsOneWidget,
      );
      expect(_photoPath(tester), _lengthPhoto);
      await tester.tap(find.text('무게순'));
      await tester.pump();

      records = [_lengthRecord(length: 75), _weightRecord()];
      changes.notifyListeners();
      await tester.pump();
      expect(
        find.textContaining('최고 크기 75.0 cm · 최고 무게 1200 g'),
        findsOneWidget,
      );

      records = [];
      changes.notifyListeners();
      await tester.pump();
      expect(find.text('아직 기록어가 없습니다.'), findsOneWidget);
      expect(find.text('Rockfish'), findsNothing);
    },
  );

  testWidgets(
    'detail follows each maximum and re-resolves edits and deletion',
    (tester) async {
      _useTallSurface(tester);
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      var records = [_lengthRecord(), _weightRecord()];
      final repository = PersonalBestRepository(recordsGetter: () => records);
      final initial = repository.getPersonalBests().single;
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalBestDetailPage(
            record: initial,
            repository: repository,
            recordChanges: changes,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('60.0 cm'), findsOneWidget);
      expect(find.text('1200 g'), findsOneWidget);
      expect(find.text('2026.11.01 · Length pier · 1번째 조과'), findsOneWidget);
      expect(find.text('2026.11.02 · Weight harbor · 1번째 조과'), findsOneWidget);
      expect(find.text('Length pier'), findsOneWidget);
      expect(_photoPath(tester), _lengthPhoto);

      await tester.tap(find.text('무게 기록'));
      await tester.pump();
      expect(find.text('Weight harbor'), findsOneWidget);
      expect(find.text('Length pier'), findsNothing);
      expect(find.text('2026.11.02 08:00 - 2026.11.02 10:00'), findsOneWidget);
      expect(_photoPath(tester), _weightPhoto);

      records = [_lengthRecord(length: 75), _weightRecord(weight: 1500)];
      changes.notifyListeners();
      await tester.pump();
      expect(find.text('75.0 cm'), findsOneWidget);
      expect(find.text('1500 g'), findsOneWidget);
      expect(find.text('60.0 cm'), findsNothing);
      expect(find.text('1200 g'), findsNothing);

      records = [_lengthRecord(weight: null)];
      changes.notifyListeners();
      await tester.pump();
      expect(find.text('측정 기록이 없습니다.'), findsOneWidget);
      expect(find.text('1500 g'), findsNothing);
      expect(_photoPath(tester), _lengthPhoto);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '크기 기록'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '무게 기록'))
            .onSelected,
        isNull,
      );

      records = [];
      changes.notifyListeners();
      await tester.pump();
      expect(find.text('이 어종의 크기·무게 기록이 없거나 삭제되었습니다.'), findsOneWidget);
      expect(find.text('60.0 cm'), findsNothing);
      expect(find.byType(Image), findsNothing);
    },
  );

  for (final signOut in [false, true]) {
    testWidgets(
      'detail hides all evidence after ${signOut ? 'logout' : 'account change'}',
      (tester) async {
        _useTallSurface(tester);
        final changes = ChangeNotifier();
        addTearDown(changes.dispose);
        var records = [_lengthRecord()];
        final repository = PersonalBestRepository(recordsGetter: () => records);
        await tester.pumpWidget(
          MaterialApp(
            home: PersonalBestDetailPage(
              record: repository.getPersonalBests().single,
              repository: repository,
              recordChanges: changes,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('60.0 cm'), findsOneWidget);

        records = [_weightRecord(weight: 9999)];
        await auth.setSessionForTesting(
          plan: signOut ? UserPlan.guest : UserPlan.free,
          email: signOut ? null : 'another-account@example.com',
        );
        changes.notifyListeners();
        await tester.pump();

        expect(find.text('계정이 변경되어 이 기록을 표시할 수 없습니다.'), findsOneWidget);
        expect(find.text('60.0 cm'), findsNothing);
        expect(find.text('9999 g'), findsNothing);
        expect(find.text('Length pier'), findsNothing);
        expect(find.text('Weight harbor'), findsNothing);
        expect(find.byType(Image), findsNothing);
      },
    );
  }

  testWidgets(
    'list replaces its cached results immediately on account change',
    (tester) async {
      final originalOwner = auth.dataOwnerKey;
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      final repository = PersonalBestRepository(
        recordsGetter: () => auth.dataOwnerKey == originalOwner
            ? [_lengthRecord()]
            : <FishingRecord>[],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalBestPage(
            repository: repository,
            recordChanges: changes,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Rockfish'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'rock');
      await tester.pump();
      await auth.setSessionForTesting(plan: UserPlan.guest);
      await tester.pump();
      expect(find.text('기록어는 로그인 후 확인할 수 있습니다.'), findsOneWidget);
      expect(find.text('Rockfish'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('missing local photos show a fallback without a remote image', (
    tester,
  ) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    final missingPhoto = File(
      '${Directory.systemTemp.path}/personal-best-photo-does-not-exist.jpg',
    );
    final repository = PersonalBestRepository(
      recordsGetter: () => [
        _record(
          id: 'missing-photo',
          location: 'Pier',
          day: 1,
          length: 60,
          weight: 100,
          photo: missingPhoto.path,
        ),
      ],
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalBestPage(
            repository: repository,
            recordChanges: changes,
          ),
        ),
      );
      // Start FileImage in the real async zone so its IO can finish.
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    final provider =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.imageProvider, isA<FileImage>());
    expect(provider.width, lessThanOrEqualTo(1200));
    expect(provider.height, lessThanOrEqualTo(1200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct guest routes never read or display personal best data', (
    tester,
  ) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var reads = 0;
    final repository = PersonalBestRepository(
      recordsGetter: () {
        reads++;
        return [_lengthRecord()];
      },
    );
    final staleRecord = repository.getPersonalBests().single;
    reads = 0;
    await auth.setSessionForTesting(plan: UserPlan.guest);
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalBestPage(repository: repository, recordChanges: changes),
      ),
    );
    await tester.pump();
    expect(find.text('기록어는 로그인 후 확인할 수 있습니다.'), findsOneWidget);
    expect(find.text('Rockfish'), findsNothing);
    expect(reads, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: PersonalBestDetailPage(
          record: staleRecord,
          repository: repository,
          recordChanges: changes,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('기록어는 로그인 후 확인할 수 있습니다.'), findsOneWidget);
    expect(find.text('Rockfish'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(reads, 0);
  });
}

const _lengthPhoto = 'C:/missing/personal-best-length.jpg';
const _weightPhoto = 'C:/missing/personal-best-weight.jpg';

String _photoPath(WidgetTester tester) =>
    ((tester.widget<Image>(find.byType(Image)).image as ResizeImage)
                .imageProvider
            as FileImage)
        .file
        .path;

void _useTallSurface(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
}

FishingRecord _lengthRecord({double length = 60, int? weight = 400}) => _record(
  id: 'length',
  location: 'Length pier',
  day: 1,
  length: length,
  weight: weight,
  photo: _lengthPhoto,
);

FishingRecord _weightRecord({int weight = 1200}) => _record(
  id: 'weight',
  location: 'Weight harbor',
  day: 2,
  length: 40,
  weight: weight,
  photo: _weightPhoto,
);

FishingRecord _record({
  required String id,
  required String location,
  required int day,
  required double length,
  required int? weight,
  required String photo,
}) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 11, day, 8),
  endAt: DateTime(2026, 11, day, 10),
  genreName: 'Lure',
  catches: [
    CatchRecord(speciesName: 'Rockfish', lengthCm: length, weightG: weight),
  ],
  photos: [RecordPhoto(id: '$id-photo', localPath: photo)],
);
