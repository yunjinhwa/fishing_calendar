import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fishing_build/core/validation/fishing_record_validator.dart';
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
const _externalGalleryChannel = MethodChannel('fishing_build/external_gallery');
const _android = TargetPlatformVariant({TargetPlatform.android});
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
  List<String>? multiPickerResults;
  MethodCall? lastPickerCall;
  List<String>? externalGalleryResults;
  final externalGalleryCalls = <MethodCall>[];

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
    final galleryBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMQrs38D8IMMAYAQZIH4XTlNsEAAAAASUVORK5CYII=',
    );
    await galleryOriginal.writeAsBytes(galleryBytes, flush: true);
    backend = _TrackingPhotoFileStore(
      RecordPhotoFileStore(
        supportPathProvider: () async => temporaryDirectory.path,
      ),
    );
    photoStore = RecordPhotoFileStore.withBackend(backend);
    await cleanup.configureForTesting(fileStore: photoStore);
    cleanup.enableAutomaticCleanup();
    pickerResult = null;
    multiPickerResults = null;
    lastPickerCall = null;
    externalGalleryResults = null;
    externalGalleryCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_externalGalleryChannel, (call) async {
          externalGalleryCalls.add(call);
          if (call.method == 'pick') return externalGalleryResults;
          if (call.method == 'read') {
            final uri = call.arguments is Map<Object?, Object?>
                ? (call.arguments as Map<Object?, Object?>)['uri']
                : null;
            if (externalGalleryResults?.contains(uri) ?? false) {
              return galleryBytes;
            }
          }
          throw PlatformException(code: 'unexpected-external-gallery-call');
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, (call) async {
          if (call.method != 'pickImage' && call.method != 'pickMultiImage') {
            throw PlatformException(code: 'unexpected-test-picker-method');
          }
          lastPickerCall = call;
          if (call.method == 'pickMultiImage' && multiPickerResults != null) {
            return multiPickerResults!;
          }
          final result = pickerResult == null
              ? galleryOriginal.path
              : await pickerResult!();
          return call.method == 'pickMultiImage'
              ? (result == null ? <String>[] : [result])
              : result;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_externalGalleryChannel, null);
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

  testWidgets(
    'an external gallery batch preserves existing photos and saves in order',
    (tester) async {
      final original = await _seedPhotoRecord(tester, photoStore, 'batch-save');
      final uris = [
        'content://gallery/image/3',
        'content://gallery/image/1',
        'content://gallery/image/2',
      ];
      externalGalleryResults = uris;
      await _openForm(tester, RecordFormPage(editingRecord: original));
      await _startPickingPhoto(tester);
      await _waitForSelection(tester);

      expect(lastPickerCall, isNull);
      expect(externalGalleryCalls.map((call) => call.method), [
        'pick',
        'read',
        'read',
        'read',
      ]);
      expect(externalGalleryCalls.first.arguments, {
        'limit': 9,
        'maxBytes': FishingRecordValidator.maxPhotoBytes,
      });
      expect(externalGalleryCalls.skip(1).map((call) => call.arguments), [
        for (final uri in uris)
          {'uri': uri, 'maxBytes': FishingRecordValidator.maxPhotoBytes},
      ]);
      expect(find.text('사진 추가 (4/10)'), findsOneWidget);
      final added = backend.stored.skip(1).toList();
      expect(added, hasLength(3));
      expect(added.map((photo) => photo.path).toSet(), hasLength(3));
      await _save(tester);
      await _flush(tester, cleanup);

      final saved = (await recordsForCurrentOwner()).single;
      expect(saved.photos.map((photo) => photo.localPath), [
        original.photos.single.localPath,
        ...added.map((photo) => photo.path),
      ]);
      expect(saved.photos.map((photo) => photo.id).toSet(), hasLength(4));
      expect(
        saved.photos.every((photo) => File(photo.localPath!).existsSync()),
        isTrue,
      );
      expect(galleryOriginal.existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: _android,
  );

  testWidgets(
    'a batch keeps valid files when another cannot be copied or read',
    (tester) async {
      final unsupported = File('${temporaryDirectory.path}/not-a-photo.txt');
      await tester.runAsync(() => unsupported.writeAsString('not an image'));
      multiPickerResults = [
        galleryOriginal.path,
        unsupported.path,
        '${temporaryDirectory.path}/missing.png',
        galleryOriginal.path,
      ];
      await _openForm(tester, const RecordFormPage());
      await _startPickingPhoto(tester);
      await _waitForSelection(tester);

      expect(find.text('사진 추가 (2/10)'), findsOneWidget);
      expect(find.textContaining('형식·크기 제한으로 제외 1장'), findsOneWidget);
      expect(find.textContaining('불러오기·저장 실패 1장'), findsOneWidget);
      expect(backend.stored, hasLength(2));
      await _discardAndLeave(tester);
      await _flush(tester, cleanup);
      expect(
        backend.stored.every((photo) => !File(photo.path).existsSync()),
        isTrue,
      );
      expect(galleryOriginal.existsSync(), isTrue);
      expect(unsupported.existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a platform ignoring the selection limit cannot attach over ten',
    (tester) async {
      multiPickerResults = List.filled(12, galleryOriginal.path);
      await _openForm(tester, const RecordFormPage());
      await _startPickingPhoto(tester);
      await _waitForSelection(tester);

      expect(find.text('사진 추가 (10/10)'), findsOneWidget);
      expect(find.textContaining('10장 제한으로 일부 제외'), findsOneWidget);
      expect(backend.stored, hasLength(10));
      await _discardAndLeave(tester);
      await _flush(tester, cleanup);
      expect(
        backend.stored.every((photo) => !File(photo.path).existsSync()),
        isTrue,
      );
      expect(galleryOriginal.existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unavailable gallery falls back to the single-photo picker',
    (tester) async {
      final original = await _seedPhotoRecord(tester, photoStore, 'one-slot');
      final record = FishingRecord.fromJson({
        ...original.toJson(),
        'photos': [
          for (var i = 0; i < 9; i++)
            {...original.photos.single.toJson(), 'id': 'existing-$i'},
        ],
      });
      await records.updateRecord(record);
      await _openForm(tester, RecordFormPage(editingRecord: record));
      await _startPickingPhoto(tester);
      await _waitForSelection(tester);

      expect(externalGalleryCalls.single.method, 'pick');
      expect(externalGalleryCalls.single.arguments, {
        'limit': 1,
        'maxBytes': FishingRecordValidator.maxPhotoBytes,
      });
      expect(lastPickerCall!.method, 'pickImage');
      expect(find.text('사진 추가 (10/10)'), findsOneWidget);
      await _disposeForm(tester, cleanup);
      expect(tester.takeException(), isNull);
    },
    variant: _android,
  );

  testWidgets(
    'the system picker action opens the existing multi-photo picker',
    (tester) async {
      multiPickerResults = [galleryOriginal.path, galleryOriginal.path];
      await _openForm(tester, const RecordFormPage());
      await _startPickingPhoto(tester, source: '시스템 사진 선택기');
      await _waitForSelection(tester);

      expect(externalGalleryCalls, isEmpty);
      expect(lastPickerCall!.method, 'pickMultiImage');
      expect(find.text('사진 추가 (2/10)'), findsOneWidget);
      await _disposeForm(tester, cleanup);
      expect(tester.takeException(), isNull);
    },
    variant: _android,
  );

  testWidgets(
    'cancelling the external gallery permits a later camera selection',
    (tester) async {
      final original = await _seedPhotoRecord(tester, photoStore, 'cancel');
      externalGalleryResults = [];
      await _openForm(tester, RecordFormPage(editingRecord: original));
      await _startPickingPhoto(tester);
      await _waitForSelection(tester);

      expect(externalGalleryCalls.single.method, 'pick');
      expect(lastPickerCall, isNull);
      expect(find.text('사진 추가 (1/10)'), findsOneWidget);
      expect(backend.stored, hasLength(1));

      await _startPickingPhoto(tester, source: '카메라로 촬영');
      await _waitForSelection(tester);
      expect(externalGalleryCalls.single.method, 'pick');
      expect(lastPickerCall!.method, 'pickImage');
      final pickerArguments =
          lastPickerCall!.arguments as Map<Object?, Object?>;
      expect(pickerArguments['source'], 0);
      expect(find.text('사진 추가 (2/10)'), findsOneWidget);
      await _discardAndLeave(tester);
      await _flush(tester, cleanup);
      expect(File(original.photos.single.localPath!).existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: _android,
  );

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
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMQrs38D8IMMAYAQZIH4XTlNsEAAAAASUVORK5CYII=',
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

Future<void> _startPickingPhoto(
  WidgetTester tester, {
  String source = '앨범에서 선택',
}) async {
  final addButton = find.widgetWithIcon(
    OutlinedButton,
    Icons.add_photo_alternate_outlined,
  );
  await tester.ensureVisible(addButton);
  await tester.tap(addButton);
  await tester.pumpAndSettle();
  await tester.tap(find.text(source));
  await tester.pump();
}

Future<void> _waitForSelection(WidgetTester tester) async {
  await _pumpIoUntil(tester, () => find.text('사진 저장 중').evaluate().isEmpty);
  await tester.pumpAndSettle();
}

Future<StoredRecordPhotoFile> _pickPhoto(
  WidgetTester tester,
  _TrackingPhotoFileStore store, {
  int expectedPhotoCount = 1,
}) async {
  store.nextStored = Completer<StoredRecordPhotoFile>();
  await _startPickingPhoto(tester);
  StoredRecordPhotoFile? result;
  unawaited(
    store.nextStored!.future.then<void>((stored) {
      result = stored;
    }),
  );
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
  unawaited(
    service.flushPending().then<void>((_) {
      completed = true;
    }),
  );
  await _pumpIoUntil(tester, () => completed);
  await tester.pumpAndSettle();
}

Future<void> _pumpIoUntil(
  WidgetTester tester,
  bool Function() isComplete,
) async {
  // File I/O uses the real event loop; widget and SQLite continuations also
  // need the fake clock's microtasks pumped between those I/O completions.
  for (var iteration = 0; iteration < 1500 && !isComplete(); iteration++) {
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
