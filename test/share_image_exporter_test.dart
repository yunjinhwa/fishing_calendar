import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:fishing_build/data/sharing/share_image_exporter.dart';
import 'package:fishing_build/data/sharing/share_image_exporter_io.dart'
    show IoShareImageExporter, ShareImagePlatform, ShareImageExportBackend;
import 'package:fishing_build/data/sharing/share_image_exporter_stub.dart'
    show UnsupportedShareImageExporter;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

void main() {
  late Directory temporary;
  late _Backend backend;
  late IoShareImageExporter exporter;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1mQAAAAASUVORK5CYII=',
  );
  const origin = Rect.fromLTWH(20, 30, 100, 40);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('share_image_test_');
    backend = _Backend(temporary);
    exporter = IoShareImageExporter(backend: backend);
  });

  tearDown(() async {
    // Every test owns this verified createTemp directory and no other files.
    expect(p.basename(temporary.path), startsWith('share_image_test_'));
    await temporary.delete(recursive: true);
  });

  test('construction never accesses storage, permission, or native UI', () {
    createShareImageExporter();
    expect(backend.calls, isEmpty);
    expect(temporary.listSync(), isEmpty);
  });

  test('mobile save uses a grant without requesting it again', () async {
    final result = await exporter.save(png, fileName: 'personal_best.png');
    expect(result, ShareImageExportResult.saved);
    expect(backend.calls, ['hasAccess', 'gallery']);
    expect(backend.galleryBytes, png);
    expect(backend.galleryName, 'personal_best');
    expect(temporary.listSync(), isEmpty);
  });

  test('mobile save requests permission only after a save action', () async {
    backend.hasAccess = false;
    expect(backend.calls, isEmpty);
    expect(
      await exporter.save(png, fileName: r'../../private\best.png'),
      ShareImageExportResult.saved,
    );
    expect(backend.calls, ['hasAccess', 'request', 'gallery']);
    expect(backend.galleryName, 'best');
  });

  test('gallery denial never writes or shares bytes', () async {
    backend
      ..hasAccess = false
      ..permissionGranted = false;
    await expectLater(
      exporter.save(png, fileName: 'record.png'),
      _failure(ShareImageExportFailure.permissionDenied),
    );
    expect(backend.calls, ['hasAccess', 'request']);
    expect(backend.galleryBytes, isNull);
    expect(backend.sharedPaths, isEmpty);
  });

  test('a changed session during permission check cannot prompt', () async {
    var current = true;
    backend.hasAccess = false;
    backend.accessPending = Completer<bool>();
    final pending = exporter.save(
      png,
      fileName: 'record.png',
      isCurrent: () => current,
    );
    current = false;
    backend.accessPending!.complete(false);
    expect(await pending, ShareImageExportResult.cancelled);
    expect(backend.calls, ['hasAccess']);
  });

  test('a changed session during permission request cannot save', () async {
    var current = true;
    backend
      ..hasAccess = false
      ..permissionPending = Completer<bool>()
      ..permissionStarted = Completer<void>();
    final pending = exporter.save(
      png,
      fileName: 'record.png',
      isCurrent: () => current,
    );
    await backend.permissionStarted!.future;
    current = false;
    backend.permissionPending!.complete(true);
    expect(await pending, ShareImageExportResult.cancelled);
    expect(backend.calls, ['hasAccess', 'request']);
  });

  for (final platform in [
    ShareImagePlatform.windows,
    ShareImagePlatform.macos,
    ShareImagePlatform.linux,
  ]) {
    test('${platform.name} save uses the selected location', () async {
      backend
        ..currentPlatform = platform
        ..savePath = p.join(temporary.path, 'selected.png');
      expect(
        await exporter.save(png, fileName: 'record.png'),
        ShareImageExportResult.saved,
      );
      expect(backend.calls, ['pick', 'write']);
      expect(await File(backend.savePath!).readAsBytes(), png);
    });
  }

  test('cancelling a desktop save does not create a file', () async {
    backend.currentPlatform = ShareImagePlatform.windows;
    expect(
      await exporter.save(png, fileName: 'record.png'),
      ShareImageExportResult.cancelled,
    );
    expect(backend.calls, ['pick']);
    expect(temporary.listSync(), isEmpty);
  });

  test('a changed session while choosing a location cannot write', () async {
    var current = true;
    backend
      ..currentPlatform = ShareImagePlatform.windows
      ..pickPending = Completer<String?>();
    final pending = exporter.save(
      png,
      fileName: 'record.png',
      isCurrent: () => current,
    );
    current = false;
    backend.pickPending!.complete(p.join(temporary.path, 'stale.png'));
    expect(await pending, ShareImageExportResult.cancelled);
    expect(backend.calls, ['pick']);
    expect(temporary.listSync(), isEmpty);
  });

  test('sharing uses a private random file and forwards its origin', () async {
    expect(
      await exporter.share(png, fileName: '../record.png', origin: origin),
      ShareImageExportResult.shared,
    );
    final first = File(backend.sharedPaths.single);
    expect(p.basename(first.path), 'record.png');
    expect(p.basename(first.parent.path), startsWith('share_'));
    expect(p.basename(first.parent.parent.path), 'share_image_exports');
    expect(p.isWithin(temporary.path, first.path), isTrue);
    expect(await first.readAsBytes(), png);
    expect(backend.origin, origin);
    expect(backend.calls, ['temporary', 'share']);
    await exporter.share(png, fileName: 'record.png', origin: origin);
    expect(backend.sharedPaths.toSet(), hasLength(2));
    expect(
      await first.exists(),
      isTrue,
      reason: 'The recipient may read later',
    );
  });

  for (final pair in [
    (ShareResultStatus.dismissed, ShareImageExportResult.cancelled),
    (ShareResultStatus.unavailable, ShareImageExportResult.shareSheetOpened),
  ]) {
    test(
      'native ${pair.$1.name} is not reported as completed sharing',
      () async {
        backend.shareResult = pair.$1;
        expect(
          await exporter.share(png, fileName: 'record.png', origin: origin),
          pair.$2,
        );
        expect(await File(backend.sharedPaths.single).exists(), isTrue);
      },
    );
  }

  test('source changed during temporary path lookup cannot share', () async {
    var current = true;
    backend.temporaryPending = Completer<Directory>();
    final pending = exporter.share(
      png,
      fileName: 'record.png',
      isCurrent: () => current,
      origin: origin,
    );
    current = false;
    backend.temporaryPending!.complete(temporary);
    expect(await pending, ShareImageExportResult.cancelled);
    expect(backend.calls, ['temporary']);
    expect(temporary.listSync(), isEmpty);
  });

  test(
    'source changed after staging removes its PNG and private directory',
    () async {
      final result = await exporter.share(
        png,
        fileName: 'record.png',
        isCurrent: () => !temporary
            .listSync(recursive: true)
            .any((entity) => entity is File),
        origin: origin,
      );
      expect(result, ShareImageExportResult.cancelled);
      expect(backend.sharedPaths, isEmpty);
      final root = Directory(p.join(temporary.path, 'share_image_exports'));
      expect(await root.list().isEmpty, isTrue);
    },
  );

  test(
    'cancellation after directory creation removes the empty stage',
    () async {
      Directory? stage;
      final result = await exporter.share(
        png,
        fileName: 'record.png',
        isCurrent: () {
          final children = temporary
              .listSync(recursive: true)
              .whereType<Directory>()
              .where(
                (directory) =>
                    p.basename(directory.path).startsWith('share_') &&
                    p.basename(directory.parent.path) == 'share_image_exports',
              );
          if (children.isEmpty) return true;
          stage = children.single;
          return false;
        },
        origin: origin,
      );
      expect(result, ShareImageExportResult.cancelled);
      expect(stage, isNotNull);
      expect(await stage!.exists(), isFalse);
      expect(backend.sharedPaths, isEmpty);
    },
  );

  test(
    'cancellation after preparation cleans only the unshared stage',
    () async {
      await exporter.share(png, fileName: 'retained.png', origin: origin);
      final retained = File(backend.sharedPaths.single);
      var checksAfterWrite = 0;
      final result = await exporter.share(
        png,
        fileName: 'cancelled.png',
        isCurrent: () {
          if (temporary
              .listSync(recursive: true)
              .any(
                (entity) =>
                    entity is File &&
                    p.basename(entity.path) == 'cancelled.png',
              )) {
            checksAfterWrite++;
          }
          return checksAfterWrite < 2;
        },
        origin: origin,
      );
      expect(result, ShareImageExportResult.cancelled);
      expect(checksAfterWrite, 2);
      expect(backend.sharedPaths, hasLength(1));
      expect(await retained.exists(), isTrue);
      expect(await retained.parent.parent.list().length, 1);
    },
  );

  test('native share errors preserve a file already handed off', () async {
    backend.shareError = StateError('Native share failed after handoff');
    await expectLater(
      exporter.share(png, fileName: 'record.png', origin: origin),
      _failure(ShareImageExportFailure.failed),
    );
    expect(await File(backend.sharedPaths.single).readAsBytes(), png);
  });

  test(
    'session cancellation after handoff preserves the recipient file',
    () async {
      var current = true;
      backend
        ..sharePending = Completer<ShareResultStatus>()
        ..shareStarted = Completer<void>();
      final pending = exporter.share(
        png,
        fileName: 'record.png',
        isCurrent: () => current,
        origin: origin,
      );
      await backend.shareStarted!.future;
      current = false;
      backend.sharePending!.complete(ShareResultStatus.success);
      expect(await pending, ShareImageExportResult.cancelled);
      expect(await File(backend.sharedPaths.single).readAsBytes(), png);
    },
  );

  test('another share cannot replace a pending native share', () async {
    backend
      ..sharePending = Completer<ShareResultStatus>()
      ..shareStarted = Completer<void>();
    final pending = exporter.share(png, fileName: 'one.png', origin: origin);
    await backend.shareStarted!.future;
    await expectLater(
      exporter.share(png, fileName: 'two.png', origin: origin),
      _failure(ShareImageExportFailure.unavailable),
    );
    expect(backend.sharedPaths, hasLength(1));
    backend.sharePending!.complete(ShareResultStatus.success);
    expect(await pending, ShareImageExportResult.shared);
  });

  test('a later explicit share expires only old managed images', () async {
    await exporter.share(png, fileName: 'old.png', origin: origin);
    final old = File(backend.sharedPaths.single);
    final unrelated = File(p.join(temporary.path, 'unrelated.png'));
    await unrelated.writeAsBytes(png);
    final later = IoShareImageExporter(
      backend: backend,
      now: () => DateTime.now().add(const Duration(hours: 25)),
    );
    await later.share(png, fileName: 'new.png', origin: origin);
    expect(await old.exists(), isFalse);
    expect(await old.parent.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(await File(backend.sharedPaths.last).exists(), isTrue);
  });

  test('retention cap keeps recent shares and refuses extra staging', () async {
    final root = Directory(p.join(temporary.path, 'share_image_exports'));
    await root.create();
    for (
      var index = 0;
      index < IoShareImageExporter.maxRetainedFiles;
      index++
    ) {
      final directory = await root.createTemp('share_');
      await File(p.join(directory.path, 'image.png')).writeAsBytes(png);
    }
    await expectLater(
      exporter.share(png, fileName: 'record.png', origin: origin),
      _failure(ShareImageExportFailure.storageFull),
    );
    expect(await root.list().length, IoShareImageExporter.maxRetainedFiles);
    expect(backend.sharedPaths, isEmpty);
  });

  test('invalid images never reach a plugin or the filesystem', () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
    ]) {
      await expectLater(
        exporter.save(bytes, fileName: 'record.png'),
        _failure(ShareImageExportFailure.invalidImage),
      );
      await expectLater(
        exporter.share(bytes, fileName: 'record.png'),
        _failure(ShareImageExportFailure.invalidImage),
      );
    }
    expect(backend.calls, isEmpty);
    expect(temporary.listSync(), isEmpty);
  });

  test('unsupported exports never pretend to save or share', () async {
    const web = UnsupportedShareImageExporter();
    await expectLater(
      web.save(png, fileName: 'record.png'),
      _failure(ShareImageExportFailure.unavailable),
    );
    await expectLater(
      web.share(png, fileName: 'record.png'),
      _failure(ShareImageExportFailure.unavailable),
    );
    backend.currentPlatform = ShareImagePlatform.linux;
    await expectLater(
      exporter.share(png, fileName: 'record.png'),
      _failure(ShareImageExportFailure.unavailable),
    );
    expect(backend.calls, isEmpty);
  });

  test('an Apple share requires valid bounds before native UI opens', () async {
    backend.currentPlatform = ShareImagePlatform.ios;
    for (final invalidOrigin in [null, Rect.zero]) {
      await expectLater(
        exporter.share(png, fileName: 'record.png', origin: invalidOrigin),
        _failure(ShareImageExportFailure.unavailable),
      );
    }
    expect(backend.calls, isEmpty);
  });

  for (final (error, failure) in <(Object, ShareImageExportFailure)>[
    (
      MissingPluginException('secret path'),
      ShareImageExportFailure.unavailable,
    ),
    (
      PlatformException(code: 'permission_denied', message: 'secret path'),
      ShareImageExportFailure.permissionDenied,
    ),
    (
      const FileSystemException(
        'secret path',
        '/private/path',
        OSError('', 28),
      ),
      ShareImageExportFailure.storageFull,
    ),
    (StateError('secret path'), ShareImageExportFailure.failed),
    for (final (type, reason) in [
      (GalExceptionType.accessDenied, ShareImageExportFailure.permissionDenied),
      (GalExceptionType.notEnoughSpace, ShareImageExportFailure.storageFull),
      (
        GalExceptionType.notSupportedFormat,
        ShareImageExportFailure.invalidImage,
      ),
      (GalExceptionType.unexpected, ShareImageExportFailure.failed),
    ])
      (
        GalException(
          type: type,
          platformException: PlatformException(
            code: type.code,
            message: 'secret path',
          ),
          stackTrace: StackTrace.empty,
        ),
        reason,
      ),
  ]) {
    test(
      '${error.runtimeType} maps to ${failure.name} without private details',
      () async {
        backend.galleryError = error;
        try {
          await exporter.save(png, fileName: 'record.png');
          fail('Expected a safe export error');
        } on ShareImageExportException catch (caught) {
          expect(caught.reason, failure);
          expect(caught.toString(), isNot(contains('secret')));
          expect(caught.toString(), isNot(contains('/private')));
        }
      },
    );
  }
}

Matcher _failure(ShareImageExportFailure reason) => throwsA(
  isA<ShareImageExportException>().having(
    (error) => error.reason,
    'reason',
    reason,
  ),
);

class _Backend extends ShareImageExportBackend {
  _Backend(this.temporary);

  final Directory temporary;
  final calls = <String>[];
  final sharedPaths = <String>[];
  ShareImagePlatform currentPlatform = ShareImagePlatform.android;
  bool hasAccess = true;
  bool permissionGranted = true;
  Uint8List? galleryBytes;
  String? galleryName;
  String? savePath;
  Rect? origin;
  Object? galleryError;
  Object? shareError;
  ShareResultStatus shareResult = ShareResultStatus.success;
  Completer<bool>? accessPending;
  Completer<bool>? permissionPending;
  Completer<void>? permissionStarted;
  Completer<String?>? pickPending;
  Completer<Directory>? temporaryPending;
  Completer<ShareResultStatus>? sharePending;
  Completer<void>? shareStarted;

  @override
  ShareImagePlatform get platform => currentPlatform;

  @override
  Future<bool> hasGalleryAccess() async {
    calls.add('hasAccess');
    return accessPending?.future ?? hasAccess;
  }

  @override
  Future<bool> requestGalleryAccess() async {
    calls.add('request');
    permissionStarted?.complete();
    return permissionPending?.future ?? permissionGranted;
  }

  @override
  Future<void> saveToGallery(Uint8List bytes, String name) async {
    calls.add('gallery');
    if (galleryError != null) throw galleryError!;
    galleryBytes = bytes;
    galleryName = name;
  }

  @override
  Future<String?> pickSavePath(String fileName) async {
    calls.add('pick');
    return pickPending?.future ?? savePath;
  }

  @override
  Future<void> writeSaveFile(Uint8List bytes, String path) async {
    calls.add('write');
    await File(path).writeAsBytes(bytes);
  }

  @override
  Future<Directory> temporaryDirectory() async {
    calls.add('temporary');
    return temporaryPending?.future ?? temporary;
  }

  @override
  Future<ShareResultStatus> shareFile(String path, {Rect? origin}) async {
    calls.add('share');
    sharedPaths.add(path);
    this.origin = origin;
    shareStarted?.complete();
    if (shareError != null) throw shareError!;
    return sharePending?.future ?? shareResult;
  }
}
