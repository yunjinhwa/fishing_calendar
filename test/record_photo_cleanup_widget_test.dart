import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

const _pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
const _discardTitle = '저장하지 않고 나가시겠습니까?';
const _saveFailure = '기록을 저장하지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final cleanup = RecordPhotoCleanupService.instance;
  late Directory temporaryDirectory;
  late File galleryOriginal;
  late _TrackingPhotoFileStore backend;
  late RecordPhotoFileStore photoStore;
  Future<String?> Function()? pickerResult;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    await cleanup.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'photo-cleanup-widget@example.com',
    );
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'photo-cleanup-widget-',
    );
    galleryOriginal = File('${temporaryDirectory.path}/gallery-original.png');
    await galleryOriginal.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jI9sAAAAASUVORK5CYII=',
      ),
      flush: true,
    );
    backend = _TrackingPhotoFileStore(
      RecordPhotoFileStore(
        supportPathProvider: () async => temporaryDirectory.path,
      ),
    );
    photoStore = RecordPhotoFileStore.withBackend(backend);
    await cleanup.configureForTesting(fileStore: photoStore);
    cleanup.enableAutomaticCleanup();
    pickerResult = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, (call) async {
          if (call.method != 'pickImage') {
            throw PlatformException(code: 'unexpected-test-picker-method');
          }
          return pickerResult == null
              ? galleryOriginal.path
              : await pickerResult!();
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, null);
    await cleanup.resetForTesting();
    await RecordSyncService.instance.resetForTesting();
    await AppDatabase.instance.close();
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  testWidgets('discarding a newly selected photo deletes only the app copy', (
    tester,
  ) async {
    await _openForm(tester, const RecordFormPage());
    final stored = await _pickPhoto(tester, backend);
    expect(File(stored.path).existsSync(), isTrue);

    await _discardAndLeave(tester);
    await _flush(tester, cleanup);

    expect(File(stored.path).existsSync(), isFalse);
    expect(galleryOriginal.existsSync(), isTrue);
    expect(await recordsForCurrentOwner(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing an unsaved selection reclaims it while editing', (
    tester,
  ) async {
    await _openForm(tester, const RecordFormPage());
    final stored = await _pickPhoto(tester, backend);

    await _removePhoto(tester);
    await _flush(tester, cleanup);

    expect(File(stored.path).existsSync(), isFalse);
    expect(galleryOriginal.existsSync(), isTrue);
    expect(find.text('사진 추가 (0/10)'), findsOneWidget);
    expect(find.byType(RecordFormPage), findsOneWidget);
    await _disposeForm(tester, cleanup);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discarding a removed persisted photo preserves the saved copy', (
    tester,
  ) async {
    final original = await _seedPhotoRecord(
      tester,
      photoStore,
      'discard-removal',
    );
    final path = original.photos.single.localPath!;
    await _openForm(tester, RecordFormPage(editingRecord: original));

    await _removePhoto(tester);
    await _flush(tester, cleanup);
    expect(File(path).existsSync(), isTrue);
    await _discardAndLeave(tester);
    await _flush(tester, cleanup);

    expect(File(path).existsSync(), isTrue);
    expect(
      (await recordsForCurrentOwner()).single.photos.single.localPath,
      path,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving photo removal reclaims the former saved file', (
    tester,
  ) async {
    final original = await _seedPhotoRecord(tester, photoStore, 'save-removal');
    final path = original.photos.single.localPath!;
    await _openForm(tester, RecordFormPage(editingRecord: original));
    await _removePhoto(tester);
    expect(File(path).existsSync(), isTrue);

    await _save(tester);
    await _flush(tester, cleanup);

    expect(find.byType(RecordFormPage), findsNothing);
    expect((await recordsForCurrentOwner()).single.photos, isEmpty);
    expect(File(path).existsSync(), isFalse);
    expect(galleryOriginal.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a saved new selection survives release of the editor draft', (
    tester,
  ) async {
    final original = await _seedPhotoRecord(
      tester,
      photoStore,
      'save-addition',
    );
    await _openForm(tester, RecordFormPage(editingRecord: original));
    final added = await _pickPhoto(tester, backend, expectedPhotoCount: 2);

    await _save(tester);
    await _flush(tester, cleanup);

    expect(find.byType(RecordFormPage), findsNothing);
    final saved = (await recordsForCurrentOwner()).single;
    expect(saved.photos, hasLength(2));
    expect(saved.photos.map((photo) => photo.localPath), contains(added.path));
    expect(File(added.path).existsSync(), isTrue);
    expect(File(original.photos.single.localPath!).existsSync(), isTrue);
    expect(galleryOriginal.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed photo removal preserves the file until retry commits', (
    tester,
  ) async {
    final original = await _seedPhotoRecord(
      tester,
      photoStore,
      'retry-removal',
    );
    final path = original.photos.single.localPath!;
    await _openForm(tester, RecordFormPage(editingRecord: original));
    await _removePhoto(tester);
    final database = await AppDatabase.instance.database;
    await database.execute('''
      CREATE TRIGGER reject_photo_cleanup_save
      BEFORE INSERT ON ${AppDatabase.fishingRecordsTable}
      BEGIN SELECT RAISE(ABORT, 'test save failure'); END
    ''');

    await _save(tester);
    await _flush(tester, cleanup);

    expect(find.text(_saveFailure), findsOneWidget);
    expect(find.byType(RecordFormPage), findsOneWidget);
    expect(File(path).existsSync(), isTrue);
    expect(
      (await recordsForCurrentOwner()).single.photos.single.localPath,
      path,
    );

    await database.execute('DROP TRIGGER reject_photo_cleanup_save');
    await _save(tester);
    await _flush(tester, cleanup);

    expect(find.byType(RecordFormPage), findsNothing);
    expect((await recordsForCurrentOwner()).single.photos, isEmpty);
    expect(File(path).existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an open editor protects photos after the stored record is deleted',
    (tester) async {
      final original = await _seedPhotoRecord(
        tester,
        photoStore,
        'open-deleted-record',
      );
      final path = original.photos.single.localPath!;
      await _openForm(tester, RecordFormPage(editingRecord: original));

      await records.deleteRecord(original.id);
      cleanup.requestCleanup(auth.dataOwnerKey);
      await _flush(tester, cleanup);

      expect(await recordsForCurrentOwner(), isEmpty);
      expect(File(path).existsSync(), isTrue);
      expect(find.byType(RecordFormPage), findsOneWidget);
      await _disposeForm(tester, cleanup);

      expect(File(path).existsSync(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an account switch during selection does not attach the old photo',
    (tester) async {
      final selected = Completer<String?>();
      pickerResult = () => selected.future;
      await _openForm(tester, const RecordFormPage());
      await _startPickingPhoto(tester);
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'another-photo-owner@example.com',
      );

      selected.complete(galleryOriginal.path);
      await _pumpIoUntil(tester, () => find.text('사진 저장 중').evaluate().isEmpty);
      await _flush(tester, cleanup);
      expect(find.text('사진 추가 (0/10)'), findsOneWidget);
      await _disposeForm(tester, cleanup);

      expect(
        backend.stored.every((photo) => !File(photo.path).existsSync()),
        isTrue,
      );
      expect(galleryOriginal.existsSync(), isTrue);
      expect(await recordsForCurrentOwner(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new draft cannot save its old owner photos into another account',
    (tester) async {
      final originalOwner = auth.dataOwnerKey;
      await _openForm(
        tester,
        const RecordFormPage(
          initialLocation: 'Account A harbor',
          initialTide: '3물',
          initialWeather: '맑음',
          initialAirTemperature: 22,
          initialWaterTemperature: 19,
        ),
      );
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '루어'));
      await tester.tap(find.widgetWithText(ChoiceChip, '루어'));
      final photo = await _pickPhoto(tester, backend);
      await _flush(tester, cleanup);
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'new-photo-save-owner@example.com',
      );
      final switchedOwner = auth.dataOwnerKey;
      expect(switchedOwner, isNot(originalOwner));

      await _save(tester);

      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(
        find.text('로그인 계정이 변경되어 저장할 수 없습니다. 입력한 내용은 유지됩니다.'),
        findsWidgets,
      );
      final location = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '위치 *',
      );
      expect(
        tester.widget<TextField>(location).controller!.text,
        'Account A harbor',
      );
      final store = LocalDataStore.instance;
      for (final owner in [originalOwner, switchedOwner]) {
        expect(await store.readRecordsForOwner(owner), isEmpty);
        expect(await store.readOutboxItemsForOwner(owner), isEmpty);
      }
      expect(File(photo.path).existsSync(), isTrue);
      await _disposeForm(tester, cleanup);
      expect(File(photo.path).existsSync(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<List<FishingRecord>> recordsForCurrentOwner() => LocalDataStore.instance
    .readRecordsForOwner(AuthSessionRepository.instance.dataOwnerKey);

Future<FishingRecord> _seedPhotoRecord(
  WidgetTester tester,
  RecordPhotoFileStore store,
  String id,
) async {
  final stored = (await tester.runAsync(
    () => store.persistSelection(
      ownerId: AuthSessionRepository.instance.dataOwnerKey,
      recordId: id,
      photoId: 'photo-$id',
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jI9sAAAAASUVORK5CYII=',
      ),
      contentType: 'image/png',
    ),
  ))!;
  final record = FishingRecord(
    id: id,
    location: 'Photo harbor',
    startAt: DateTime(2026, 9, 22, 8),
    endAt: DateTime(2026, 9, 22, 10),
    genreName: '루어',
    tide: '3물',
    weather: '맑음',
    airTemperature: 22,
    waterTemperature: 19,
    photos: [
      RecordPhoto(
        id: 'photo-$id',
        localPath: stored.path,
        contentType: stored.contentType,
        sizeBytes: stored.byteLength,
        checksum: stored.checksum,
      ),
    ],
  );
  await FishingRecordRepository.instance.addRecord(record);
  return record;
}

Future<void> _openForm(WidgetTester tester, RecordFormPage form) async {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push<bool>(MaterialPageRoute<bool>(builder: (_) => form)),
            child: const Text('Open form'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open form'));
  await tester.pumpAndSettle();
}

Future<void> _startPickingPhoto(WidgetTester tester) async {
  final addButton = find.widgetWithIcon(
    OutlinedButton,
    Icons.add_photo_alternate_outlined,
  );
  await tester.ensureVisible(addButton);
  await tester.tap(addButton);
  await tester.pumpAndSettle();
  await tester.tap(find.text('앨범에서 선택'));
  await tester.pump();
}

Future<StoredRecordPhotoFile> _pickPhoto(
  WidgetTester tester,
  _TrackingPhotoFileStore store, {
  int expectedPhotoCount = 1,
}) async {
  store.nextStored = Completer<StoredRecordPhotoFile>();
  await _startPickingPhoto(tester);
  StoredRecordPhotoFile? result;
  store.nextStored!.future.then((stored) => result = stored);
  await _pumpIoUntil(tester, () => result != null);
  await tester.pumpAndSettle();
  expect(find.text('사진 추가 ($expectedPhotoCount/10)'), findsOneWidget);
  return result!;
}

Future<void> _removePhoto(WidgetTester tester) async {
  await tester.ensureVisible(find.byIcon(Icons.close));
  await tester.tap(find.byIcon(Icons.close));
  await tester.pumpAndSettle();
  await _flush(tester, RecordPhotoCleanupService.instance);
}

Future<void> _discardAndLeave(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
  expect(find.text(_discardTitle), findsOneWidget);
  await tester.tap(find.widgetWithText(FilledButton, '나가기'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await _flush(tester, RecordPhotoCleanupService.instance);
  final saveButton = find.widgetWithText(FilledButton, '저장');
  await tester.ensureVisible(saveButton);
  await tester.tap(saveButton);
  await tester.pump();
  await _pumpIoUntil(
    tester,
    () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
  await tester.pumpAndSettle();
}

Future<void> _flush(
  WidgetTester tester,
  RecordPhotoCleanupService service,
) async {
  var completed = false;
  service.flushPending().then((_) => completed = true);
  await _pumpIoUntil(tester, () => completed);
  await tester.pumpAndSettle();
}

Future<void> _pumpIoUntil(
  WidgetTester tester,
  bool Function() isComplete,
) async {
  // File I/O uses the real event loop; widget and SQLite continuations also
  // need the fake clock's microtasks pumped between those I/O completions.
  for (var iteration = 0; iteration < 500 && !isComplete(); iteration++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(isComplete(), isTrue, reason: 'Timed out waiting for photo file I/O.');
}

Future<void> _disposeForm(
  WidgetTester tester,
  RecordPhotoCleanupService service,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await _flush(tester, service);
}

final class _TrackingPhotoFileStore implements RecordPhotoFileStoreBackend {
  _TrackingPhotoFileStore(this.delegate);

  final RecordPhotoFileStore delegate;
  final stored = <StoredRecordPhotoFile>[];
  Completer<StoredRecordPhotoFile>? nextStored;

  @override
  Future<StoredRecordPhotoFile> persistSelection({
    required String ownerId,
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) async {
    final result = await delegate.persistSelection(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      bytes: bytes,
      sourcePath: sourcePath,
      contentType: contentType,
    );
    stored.add(result);
    if (nextStored != null && !nextStored!.isCompleted) {
      nextStored!.complete(result);
    }
    return result;
  }

  @override
  Future<int> deleteUnreferencedFiles({
    required String ownerId,
    required Set<String> retainedPaths,
    bool Function(String path)? isProtected,
  }) => delegate.deleteUnreferencedFiles(
    ownerId: ownerId,
    retainedPaths: retainedPaths,
    isProtected: isProtected,
  );

  @override
  Future<void> deleteOwnerFiles(String ownerId) =>
      delegate.deleteOwnerFiles(ownerId);

  @override
  Future<Uint8List> readBytes(String path) => delegate.readBytes(path);
}
