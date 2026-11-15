import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/record/record_photo_image.dart';
import 'package:fishing_build/presentation/record/record_photo_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final cleanup = RecordPhotoCleanupService.instance;
  late Directory directory;
  late RecordPhoto photo;
  late Uint8List bytes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    await cleanup.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'photo-viewer@example.com',
    );
    directory = await Directory.systemTemp.createTemp('photo-viewer-');
    final store = RecordPhotoFileStore(
      supportPathProvider: () async => directory.path,
    );
    await cleanup.configureForTesting(fileStore: store);
    bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMQrs38D8IMMAYAQZIH4XTlNsEAAAAASUVORK5CYII=',
    );
    final stored = await store.persistSelection(
      ownerId: auth.dataOwnerKey,
      recordId: 'viewer-record',
      photoId: 'viewer-photo',
      bytes: bytes,
      contentType: 'image/png',
    );
    photo = RecordPhoto(id: 'viewer-photo', localPath: stored.path);
  });

  tearDown(() async {
    await cleanup.resetForTesting();
    await RecordSyncService.instance.resetForTesting();
    auth.resetAuthGatewayForTesting();
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  testWidgets('a photo zooms, resets and closes without rereading the original', (
    tester,
  ) async {
    var reads = 0;
    final original = Uint8List.fromList(bytes);
    await _openViewer(
      tester,
      RecordPhotoViewer(
        photo: photo,
        photoReader: (_) async {
          reads++;
          return bytes;
        },
      ),
    );
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final transform = viewer.transformationController!;
    expect(transform.value.getMaxScaleOnAxis(), 1);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as RecordPhotoImage).decodeLimit, 3072);

    final point = tester.getCenter(find.byType(InteractiveViewer));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), closeTo(2.5, 0.001));

    // A real two-pointer gesture exercises InteractiveViewer's scale recognizer.
    final left = await tester.startGesture(
      point - const Offset(40, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      point + const Offset(40, 0),
      pointer: 2,
    );
    await tester.pump();
    await left.moveTo(point - const Offset(80, 0));
    await right.moveTo(point + const Offset(80, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(2.5));
    expect(transform.value.getMaxScaleOnAxis(), lessThanOrEqualTo(4));

    await tester.tap(find.byTooltip('확대 초기화'));
    await tester.pump();
    expect(transform.value.getMaxScaleOnAxis(), 1);
    expect(reads, 1);
    expect(bytes, original);
    await _closeViewer(tester);
    expect(
      await tester.runAsync(() => File(photo.localPath!).readAsBytes()),
      original,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('read and decode failures keep the close button available', (
    tester,
  ) async {
    for (final reader in <Future<Uint8List> Function(String)>[
      (_) => Future.error(StateError('unavailable photo')),
      (_) async => Uint8List.fromList([1, 2, 3]),
    ]) {
      await _openViewer(
        tester,
        RecordPhotoViewer(photo: photo, photoReader: reader),
      );
      for (
        var i = 0;
        i < 50 && find.byIcon(Icons.broken_image_outlined).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(find.text('사진을 불러올 수 없습니다.'), findsOneWidget);
      await _closeViewer(tester);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'an account switch closes the viewer before a late read completes',
    (tester) async {
      final pending = Completer<Uint8List>();
      await _openViewer(
        tester,
        RecordPhotoViewer(photo: photo, photoReader: (_) => pending.future),
        settle: false,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'other-viewer@example.com',
      );
      await tester.pumpAndSettle();
      expect(find.byType(RecordPhotoViewer), findsNothing);
      pending.complete(bytes);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('Open photo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account deletion locks close a viewer without a session change',
    (tester) async {
      await _openViewer(
        tester,
        RecordPhotoViewer(photo: photo, photoReader: (_) async => bytes),
      );
      final generation = auth.sessionGeneration;
      auth.setAccountDeletionStateForTesting(
        isPending: true,
        initiatedLocally: false,
      );
      await tester.pumpAndSettle();
      expect(auth.sessionGeneration, generation);
      expect(find.byType(RecordPhotoViewer), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an open viewer pins its file until the preview is closed', (
    tester,
  ) async {
    await _openViewer(
      tester,
      RecordPhotoViewer(photo: photo, photoReader: (_) async => bytes),
    );
    expect(
      await tester.runAsync(() => cleanup.collectOwner(auth.dataOwnerKey)),
      0,
    );
    expect(File(photo.localPath!).existsSync(), isTrue);

    await _closeViewer(tester);
    await tester.runAsync(cleanup.flushPending);
    expect(
      await tester.runAsync(() => cleanup.collectOwner(auth.dataOwnerKey)),
      1,
    );
    expect(File(photo.localPath!).existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openViewer(
  WidgetTester tester,
  RecordPhotoViewer viewer, {
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push<void>(MaterialPageRoute(builder: (_) => viewer)),
            child: const Text('Open photo'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open photo'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _closeViewer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('사진 닫기'));
  await tester.pumpAndSettle();
  expect(find.byType(RecordPhotoViewer), findsNothing);
  expect(find.text('Open photo'), findsOneWidget);
}
