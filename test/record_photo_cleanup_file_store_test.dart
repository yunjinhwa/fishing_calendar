import 'dart:io';
import 'dart:typed_data';

import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/photos/record_photo_file_store_stub.dart';
import 'package:fishing_build/data/photos/record_photo_file_store_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('managed photo cleanup on disk', () {
    late Directory temporaryDirectory;
    late Directory supportDirectory;
    late RecordPhotoFileStore store;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'record-photo-cleanup-',
      );
      supportDirectory = await Directory(
        p.join(temporaryDirectory.path, 'support'),
      ).create();
      store = RecordPhotoFileStore(
        supportPathProvider: () async => supportDirectory.path,
      );
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    Future<StoredRecordPhotoFile> persist(
      String photoId, {
      String ownerId = 'member:owner-a',
      String? sourcePath,
    }) {
      return store.persistSelection(
        ownerId: ownerId,
        recordId: 'record-one',
        photoId: photoId,
        bytes: sourcePath == null ? Uint8List.fromList(<int>[1, 2, 3]) : null,
        sourcePath: sourcePath,
      );
    }

    Directory ownerDirectory([String ownerId = 'member:owner-a']) {
      return Directory(
        p.join(
          supportDirectory.path,
          recordPhotoStorageDirectoryName,
          safeRecordPhotoPathSegment(ownerId, fieldName: 'ownerId'),
        ),
      );
    }

    test(
      'removes only unreferenced copies and preserves gallery originals',
      () async {
        final source = await File(
          p.join(temporaryDirectory.path, 'gallery-original.jpg'),
        ).writeAsBytes(<int>[4, 5, 6]);
        final kept = await persist('kept');
        final unused = await persist('unused', sourcePath: source.path);
        final anotherOwner = await persist(
          'another',
          ownerId: 'member:owner-b',
        );
        final unrelatedSupportFile = await File(
          p.join(supportDirectory.path, 'not-a-photo.db'),
        ).writeAsBytes(<int>[7]);

        expect(
          await store.deleteUnreferencedFiles(
            ownerId: 'member:owner-a',
            retainedPaths: <String>{kept.path, source.path},
          ),
          1,
        );
        expect(await File(unused.path).exists(), isFalse);
        expect(await File(kept.path).exists(), isTrue);
        expect(await File(anotherOwner.path).exists(), isTrue);
        expect(await source.readAsBytes(), <int>[4, 5, 6]);
        expect(await unrelatedSupportFile.exists(), isTrue);
        expect(
          await store.deleteUnreferencedFiles(
            ownerId: 'member:owner-a',
            retainedPaths: <String>{kept.path},
          ),
          0,
        );
      },
    );

    test(
      'normalizes retained paths including Windows case and dot segments',
      () async {
        final kept = await persist('kept');
        var retainedPath = p.join(
          p.dirname(kept.path),
          'unused-directory',
          '..',
          p.basename(kept.path),
        );
        if (Platform.isWindows) {
          retainedPath = retainedPath.toUpperCase();
        }
        expect(
          await store.deleteUnreferencedFiles(
            ownerId: 'member:owner-a',
            retainedPaths: <String>{' $retainedPath '},
          ),
          0,
        );
        expect(await File(kept.path).exists(), isTrue);
      },
    );

    test(
      'checks live draft protection immediately before deleting files',
      () async {
        final activeDraft = await persist('active-draft');
        final orphan = await persist('orphan');
        final checkedPaths = <String>[];
        expect(
          await store.deleteUnreferencedFiles(
            ownerId: 'member:owner-a',
            retainedPaths: <String>{},
            isProtected: (path) {
              checkedPaths.add(path);
              expect(File(path).existsSync(), isTrue);
              return p.equals(path, activeDraft.path);
            },
          ),
          1,
        );
        expect(
          checkedPaths,
          containsAll(<String>[activeDraft.path, orphan.path]),
        );
        expect(await File(activeDraft.path).exists(), isTrue);
        expect(await File(orphan.path).exists(), isFalse);
        expect(
          await store.deleteUnreferencedFiles(
            ownerId: 'member:owner-a',
            retainedPaths: <String>{},
          ),
          1,
        );
      },
    );

    test(
      'removes abandoned temporary files while keeping retained photos',
      () async {
        final kept = await persist('kept');
        final abandoned = await File(
          p.join(p.dirname(kept.path), '.photo.12345.tmp'),
        ).writeAsBytes(<int>[1]);
        expect(
          await store.deleteUnreferencedFiles(
            ownerId: 'member:owner-a',
            retainedPaths: <String>{kept.path},
          ),
          1,
        );
        expect(await abandoned.exists(), isFalse);
        expect(await File(kept.path).exists(), isTrue);
      },
    );

    test('an absent owner is a no-op and is not created by cleanup', () async {
      expect(
        await store.deleteUnreferencedFiles(
          ownerId: 'member:missing',
          retainedPaths: <String>{},
        ),
        0,
      );
      expect(await ownerDirectory('member:missing').exists(), isFalse);
    });

    test('empty support and owner paths are rejected', () async {
      final invalidStore = RecordPhotoFileStore(
        supportPathProvider: () async => ' ',
      );
      await expectLater(
        invalidStore.deleteUnreferencedFiles(
          ownerId: 'member:owner-a',
          retainedPaths: <String>{},
        ),
        throwsA(isA<RecordPhotoFileStoreException>()),
      );
      await expectLater(
        store.deleteUnreferencedFiles(ownerId: ' ', retainedPaths: <String>{}),
        throwsArgumentError,
      );
    });

    test(
      'directory links inside an owner are not followed or removed',
      () async {
        final orphan = await persist('orphan');
        final gallery = await Directory(
          p.join(temporaryDirectory.path, 'gallery'),
        ).create();
        final source = await File(
          p.join(gallery.path, 'original.jpg'),
        ).writeAsBytes(<int>[8, 9]);
        final linkedPath = p.join(ownerDirectory().path, 'linked-gallery');
        final removeLink = await _createDirectoryLink(linkedPath, gallery.path);
        try {
          expect(
            await store.deleteUnreferencedFiles(
              ownerId: 'member:owner-a',
              retainedPaths: <String>{},
            ),
            1,
          );
          expect(await File(orphan.path).exists(), isFalse);
          expect(await source.readAsBytes(), <int>[8, 9]);
          expect(
            await FileSystemEntity.type(linkedPath, followLinks: false),
            isNot(FileSystemEntityType.notFound),
          );
        } finally {
          await removeLink();
        }
      },
    );

    test(
      'an owner directory redirected to another owner is rejected',
      () async {
        final anotherOwner = await persist(
          'another',
          ownerId: 'member:owner-b',
        );
        final linkedOwner = ownerDirectory().path;
        final removeLink = await _createDirectoryLink(
          linkedOwner,
          ownerDirectory('member:owner-b').path,
        );
        try {
          await expectLater(
            store.deleteUnreferencedFiles(
              ownerId: 'member:owner-a',
              retainedPaths: <String>{},
            ),
            throwsA(isA<RecordPhotoFileStoreException>()),
          );
          expect(await File(anotherOwner.path).exists(), isTrue);
        } finally {
          await removeLink();
        }
      },
    );

    test('a redirected application support ancestor is rejected', () async {
      final kept = await persist('kept');
      final linkedSupport = p.join(temporaryDirectory.path, 'linked-support');
      final removeLink = await _createDirectoryLink(
        linkedSupport,
        supportDirectory.path,
      );
      final linkedStore = RecordPhotoFileStore(
        supportPathProvider: () async => linkedSupport,
      );
      try {
        await expectLater(
          linkedStore.deleteUnreferencedFiles(
            ownerId: 'member:owner-a',
            retainedPaths: <String>{},
          ),
          throwsA(isA<RecordPhotoFileStoreException>()),
        );
        expect(await File(kept.path).exists(), isTrue);
      } finally {
        await removeLink();
      }
    });

    test('account cleanup preserves linked targets as well', () async {
      final orphan = await persist('orphan');
      final gallery = await Directory(
        p.join(temporaryDirectory.path, 'gallery'),
      ).create();
      final source = await File(
        p.join(gallery.path, 'original.jpg'),
      ).writeAsBytes(<int>[7, 8]);
      final linkedPath = p.join(ownerDirectory().path, 'linked-gallery');
      final removeLink = await _createDirectoryLink(linkedPath, gallery.path);
      try {
        await store.deleteOwnerFiles('member:owner-a');
        expect(await File(orphan.path).exists(), isFalse);
        expect(await source.readAsBytes(), <int>[7, 8]);
        expect(
          await FileSystemEntity.type(linkedPath, followLinks: false),
          isNot(FileSystemEntityType.notFound),
        );
      } finally {
        await removeLink();
      }
    });
  });

  test(
    'memory backend honors owner, normalized references and live pins',
    () async {
      final backend = MemoryRecordPhotoFileStoreBackend();
      final store = RecordPhotoFileStore.withBackend(backend);
      const ownerId = 'cleanup-memory-owner';
      const anotherOwnerId = 'cleanup-memory-other-owner';
      addTearDown(() async {
        await backend.deleteOwnerFiles(ownerId);
        await backend.deleteOwnerFiles(anotherOwnerId);
      });
      Future<StoredRecordPhotoFile> persist(String owner, String photo) {
        return store.persistSelection(
          ownerId: owner,
          recordId: 'record-one',
          photoId: photo,
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        );
      }

      final retained = await persist(ownerId, 'retained');
      final pinned = await persist(ownerId, 'pinned');
      final orphan = await persist(ownerId, 'orphan');
      final other = await persist(anotherOwnerId, 'other');
      final normalizedRetainedPath = retained.path.replaceFirst(
        '/selected/',
        '/selected/../selected/',
      );
      expect(
        await store.deleteUnreferencedFiles(
          ownerId: ownerId,
          retainedPaths: <String>{normalizedRetainedPath},
          isProtected: (path) => path == pinned.path,
        ),
        1,
      );
      await expectLater(
        backend.readBytes(orphan.path),
        throwsA(isA<RecordPhotoFileNotFoundException>()),
      );
      expect(await backend.readBytes(retained.path), <int>[1, 2, 3]);
      expect(await backend.readBytes(pinned.path), <int>[1, 2, 3]);
      expect(await backend.readBytes(other.path), <int>[1, 2, 3]);
      expect(
        await store.deleteUnreferencedFiles(
          ownerId: ownerId,
          retainedPaths: <String>{retained.path},
        ),
        1,
      );
      expect(
        await store.deleteUnreferencedFiles(
          ownerId: ownerId,
          retainedPaths: <String>{retained.path},
        ),
        0,
      );
    },
  );
}

/// Junctions do not require Windows' optional symbolic-link privileges.
/// Their targets always stay in the test's own temporary directory.
Future<Future<void> Function()> _createDirectoryLink(
  String linkPath,
  String targetPath,
) async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', <String>[
      '/c',
      'mklink',
      '/J',
      linkPath,
      targetPath,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Could not create test junction: ${result.stderr}');
    }
    // Nonrecursive deletion removes only the junction entry, never its target.
    return () async => Directory(linkPath).delete();
  }
  await Link(linkPath).create(targetPath);
  return () async => Link(linkPath).delete();
}
