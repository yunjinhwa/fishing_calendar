import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;
  late RecordPhotoFileStore fileStore;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'record-photo-store-',
    );
    fileStore = RecordPhotoFileStore(
      supportPathProvider: () async => temporaryDirectory.path,
      maxFileBytes: 16,
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'selected photos are copied to an account-scoped managed path',
    () async {
      final bytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);

      final first = await fileStore.persistSelection(
        ownerId: 'member:first-user',
        recordId: 'record/with unsafe characters',
        photoId: 'photo:1',
        bytes: bytes,
        contentType: 'image/jpeg',
      );
      final second = await fileStore.persistSelection(
        ownerId: 'member:second-user',
        recordId: 'record/with unsafe characters',
        photoId: 'photo:1',
        bytes: bytes,
        contentType: 'image/jpeg',
      );

      expect(first.path, isNot(second.path));
      expect(first.path, contains('record_photo_files_v1'));
      expect(first.path, isNot(contains('member:first-user')));
      expect(await fileStore.readBytes(first.path), bytes);
      expect(first.checksum, sha256.convert(bytes).toString());
      expect(first.contentType, 'image/jpeg');
      expect(first.byteLength, bytes.length);
    },
  );

  test('empty and oversized files are rejected', () async {
    await expectLater(
      fileStore.persistSelection(
        ownerId: 'uid-1',
        recordId: 'record-1',
        photoId: 'empty',
        bytes: Uint8List(0),
      ),
      throwsA(isA<RecordPhotoFileStoreException>()),
    );
    await expectLater(
      fileStore.persistSelection(
        ownerId: 'uid-1',
        recordId: 'record-1',
        photoId: 'large',
        bytes: Uint8List(17),
      ),
      throwsA(isA<RecordPhotoTooLargeException>()),
    );
  });
}
