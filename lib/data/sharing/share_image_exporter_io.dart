import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'share_image_exporter_types.dart';

ShareImageExporter createShareImageExporter() => IoShareImageExporter();

enum ShareImagePlatform { android, ios, macos, windows, linux, unsupported }

/// The adapter boundary keeps unit tests away from permission and OS dialogs.
abstract class ShareImageExportBackend {
  ShareImagePlatform get platform;
  Future<bool> hasGalleryAccess();
  Future<bool> requestGalleryAccess();
  Future<void> saveToGallery(Uint8List bytes, String name);
  Future<String?> pickSavePath(String fileName);
  Future<void> writeSaveFile(Uint8List bytes, String path);
  Future<Directory> temporaryDirectory();
  Future<ShareResultStatus> shareFile(String path, {Rect? origin});
}

class IoShareImageExporter implements ShareImageExporter {
  IoShareImageExporter({
    ShareImageExportBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? _NativeShareImageExportBackend(),
       _now = now ?? DateTime.now;

  final ShareImageExportBackend _backend;
  final DateTime Function() _now;

  static const temporaryDirectoryName = 'share_image_exports';
  static const temporaryFileLifetime = Duration(hours: 24);
  static const maxImageBytes = 12 * 1024 * 1024;
  static const maxRetainedBytes = 128 * 1024 * 1024;
  static const maxRetainedFiles = 128;
  static bool _sharing = false;

  @override
  Future<ShareImageExportResult> save(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
  }) async {
    try {
      _checkCurrent(isCurrent);
      _validatePng(bytes);
      final name = _safeFileName(fileName);
      switch (_backend.platform) {
        case ShareImagePlatform.android:
        case ShareImagePlatform.ios:
          final hasAccess = await _backend.hasGalleryAccess();
          _checkCurrent(isCurrent);
          if (!hasAccess) {
            final granted = await _backend.requestGalleryAccess();
            _checkCurrent(isCurrent);
            if (!granted) {
              throw const ShareImageExportException(
                ShareImageExportFailure.permissionDenied,
              );
            }
          }
          await _backend.saveToGallery(bytes, p.basenameWithoutExtension(name));
          _checkCurrent(isCurrent);
          return ShareImageExportResult.saved;
        case ShareImagePlatform.macos:
        case ShareImagePlatform.windows:
        case ShareImagePlatform.linux:
          final path = await _backend.pickSavePath(name);
          _checkCurrent(isCurrent);
          if (path == null) return ShareImageExportResult.cancelled;
          await _backend.writeSaveFile(bytes, path);
          _checkCurrent(isCurrent);
          return ShareImageExportResult.saved;
        case ShareImagePlatform.unsupported:
          throw const ShareImageExportException(
            ShareImageExportFailure.unavailable,
          );
      }
    } on _ExportCancelled {
      return ShareImageExportResult.cancelled;
    } on Object catch (error) {
      throw _safeException(error);
    }
  }

  @override
  Future<ShareImageExportResult> share(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
    Rect? origin,
  }) async {
    var ownsShare = false;
    var handedOff = false;
    final stage = _ShareImageStage();
    try {
      _checkCurrent(isCurrent);
      _validatePng(bytes);
      if (_backend.platform == ShareImagePlatform.linux ||
          _backend.platform == ShareImagePlatform.unsupported ||
          _sharing) {
        throw const ShareImageExportException(
          ShareImageExportFailure.unavailable,
        );
      }
      // An iPad requires a valid popover anchor. The caller supplies the button
      // bounds on all platforms, so no permission or native UI is needed here.
      if ((_backend.platform == ShareImagePlatform.ios ||
              _backend.platform == ShareImagePlatform.macos) &&
          (origin == null || !origin.isFinite || origin.isEmpty)) {
        throw const ShareImageExportException(
          ShareImageExportFailure.unavailable,
        );
      }
      _sharing = true;
      ownsShare = true;
      final file = await _prepareShareFile(
        bytes,
        _safeFileName(fileName),
        isCurrent,
        stage,
      );
      _checkCurrent(isCurrent);
      // Once invocation begins, even a plugin error may leave a recipient
      // reading the image. Only copies that never reached this point are ours
      // to remove immediately.
      handedOff = true;
      final result = await _backend.shareFile(file.path, origin: origin);
      _checkCurrent(isCurrent);
      // Keep the file: selecting a share target does not mean that it has
      // finished reading it. Only a later explicit share expires old copies.
      return switch (result) {
        ShareResultStatus.success => ShareImageExportResult.shared,
        ShareResultStatus.dismissed => ShareImageExportResult.cancelled,
        ShareResultStatus.unavailable =>
          ShareImageExportResult.shareSheetOpened,
      };
    } on _ExportCancelled {
      return ShareImageExportResult.cancelled;
    } on Object catch (error) {
      throw _safeException(error);
    } finally {
      if (!handedOff) await _deleteUnsharedStage(stage);
      if (ownsShare) _sharing = false;
    }
  }

  Future<File> _prepareShareFile(
    Uint8List bytes,
    String fileName,
    bool Function()? isCurrent,
    _ShareImageStage stage,
  ) async {
    final temporary = await _backend.temporaryDirectory();
    _checkCurrent(isCurrent);
    final canonicalTemporary = await temporary.resolveSymbolicLinks();
    _checkCurrent(isCurrent);
    final root = Directory(p.join(canonicalTemporary, temporaryDirectoryName));
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    _checkCurrent(isCurrent);
    if (type == FileSystemEntityType.notFound) {
      await root.create();
      _checkCurrent(isCurrent);
    } else if (type != FileSystemEntityType.directory) {
      throw const ShareImageExportException(ShareImageExportFailure.failed);
    }
    final canonicalRoot = await root.resolveSymbolicLinks();
    _checkCurrent(isCurrent);
    if (!p.equals(canonicalRoot, root.path) ||
        !p.isWithin(canonicalTemporary, canonicalRoot)) {
      throw const ShareImageExportException(ShareImageExportFailure.failed);
    }
    await _expireOldFiles(root, bytes.length, isCurrent);
    _checkCurrent(isCurrent);
    // createTemp adds an unpredictable component, isolating identical names.
    final directory = await root.createTemp('share_');
    stage
      ..root = root
      ..directory = directory;
    _checkCurrent(isCurrent);
    final file = File(p.join(directory.path, fileName));
    stage.file = file;
    await file.writeAsBytes(bytes, flush: true);
    _checkCurrent(isCurrent);
    return file;
  }

  Future<void> _deleteUnsharedStage(_ShareImageStage stage) async {
    final root = stage.root;
    final directory = stage.directory;
    if (root == null || directory == null) return;
    try {
      // Delete only this operation's direct child and known file. Resolve both
      // directories again so a redirected directory cannot escape our cache.
      if (!p.equals(p.dirname(directory.path), root.path) ||
          !p.basename(directory.path).startsWith('share_') ||
          await FileSystemEntity.type(root.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.equals(await root.resolveSymbolicLinks(), root.path) ||
          !p.equals(await directory.resolveSymbolicLinks(), directory.path)) {
        return;
      }
      final file = stage.file;
      if (file != null &&
          p.equals(p.dirname(file.path), directory.path) &&
          await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file) {
        await file.delete();
      }
      if (await directory.list(followLinks: false).isEmpty) {
        await directory.delete();
      }
    } on FileSystemException {
      // Cleanup is best effort when storage is unavailable; the existing
      // bounded expiry policy can retry on a later explicit share action.
    }
  }

  Future<void> _expireOldFiles(
    Directory root,
    int incomingBytes,
    bool Function()? isCurrent,
  ) async {
    final entries = await root
        .list(followLinks: false)
        .take(maxRetainedFiles + 1)
        .toList();
    _checkCurrent(isCurrent);
    var retainedFiles = 0;
    var retainedBytes = 0;
    for (final entry in entries) {
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      _checkCurrent(isCurrent);
      if (type != FileSystemEntityType.directory ||
          !p.basename(entry.path).startsWith('share_')) {
        throw const ShareImageExportException(ShareImageExportFailure.failed);
      }
      final directory = Directory(entry.path);
      final canonical = await directory.resolveSymbolicLinks();
      _checkCurrent(isCurrent);
      if (!p.equals(canonical, directory.path) ||
          !p.isWithin(root.path, canonical)) {
        throw const ShareImageExportException(ShareImageExportFailure.failed);
      }
      final files = await directory.list(followLinks: false).take(2).toList();
      _checkCurrent(isCurrent);
      if (files.length > 1) {
        throw const ShareImageExportException(ShareImageExportFailure.failed);
      }
      final directoryStat = await directory.stat();
      _checkCurrent(isCurrent);
      if (files.isEmpty) {
        if (_now().difference(directoryStat.modified) >=
            temporaryFileLifetime) {
          await directory.delete();
          _checkCurrent(isCurrent);
        } else {
          retainedFiles++;
        }
        continue;
      }
      final file = File(files.single.path);
      final fileType = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      _checkCurrent(isCurrent);
      if (fileType != FileSystemEntityType.file) {
        throw const ShareImageExportException(ShareImageExportFailure.failed);
      }
      final fileStat = await file.stat();
      _checkCurrent(isCurrent);
      // Inspect only the one managed image; never recurse or follow links.
      if (_now().difference(fileStat.modified) >= temporaryFileLifetime) {
        await file.delete();
        _checkCurrent(isCurrent);
        await directory.delete();
        _checkCurrent(isCurrent);
      } else {
        retainedFiles++;
        retainedBytes += fileStat.size;
      }
    }
    if (retainedFiles >= maxRetainedFiles ||
        retainedBytes + incomingBytes > maxRetainedBytes ||
        entries.length > maxRetainedFiles) {
      throw const ShareImageExportException(
        ShareImageExportFailure.storageFull,
      );
    }
  }

  void _checkCurrent(bool Function()? isCurrent) {
    if (!(isCurrent?.call() ?? true)) throw const _ExportCancelled();
  }

  void _validatePng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length <= signature.length || bytes.length > maxImageBytes) {
      throw const ShareImageExportException(
        ShareImageExportFailure.invalidImage,
      );
    }
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) {
        throw const ShareImageExportException(
          ShareImageExportFailure.invalidImage,
        );
      }
    }
  }

  String _safeFileName(String name) {
    var stem = name.split(RegExp(r'[/\\]')).last;
    if (stem.toLowerCase().endsWith('.png')) {
      stem = stem.substring(0, stem.length - 4);
    }
    stem = stem.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    if (stem.isEmpty) stem = 'fishing_record';
    if (stem.length > 80) stem = stem.substring(0, 80);
    return '$stem.png';
  }

  ShareImageExportException _safeException(Object error) {
    if (error is ShareImageExportException) return error;
    if (error is GalException) {
      return ShareImageExportException(switch (error.type) {
        GalExceptionType.accessDenied =>
          ShareImageExportFailure.permissionDenied,
        GalExceptionType.notEnoughSpace => ShareImageExportFailure.storageFull,
        GalExceptionType.notSupportedFormat =>
          ShareImageExportFailure.invalidImage,
        GalExceptionType.unexpected => ShareImageExportFailure.failed,
      });
    }
    if (error is MissingPluginException || error is UnsupportedError) {
      return const ShareImageExportException(
        ShareImageExportFailure.unavailable,
      );
    }
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      if (code.contains('denied') || code.contains('permission')) {
        return const ShareImageExportException(
          ShareImageExportFailure.permissionDenied,
        );
      }
      if (code == 'unavailable' || code == 'not_available') {
        return const ShareImageExportException(
          ShareImageExportFailure.unavailable,
        );
      }
    }
    if (error is FileSystemException &&
        (error.osError?.errorCode == 28 || error.osError?.errorCode == 112)) {
      return const ShareImageExportException(
        ShareImageExportFailure.storageFull,
      );
    }
    return const ShareImageExportException(ShareImageExportFailure.failed);
  }
}

class _ExportCancelled implements Exception {
  const _ExportCancelled();
}

class _ShareImageStage {
  Directory? root;
  Directory? directory;
  File? file;
}

class _NativeShareImageExportBackend extends ShareImageExportBackend {
  @override
  ShareImagePlatform get platform {
    if (Platform.isAndroid) return ShareImagePlatform.android;
    if (Platform.isIOS) return ShareImagePlatform.ios;
    if (Platform.isMacOS) return ShareImagePlatform.macos;
    if (Platform.isWindows) return ShareImagePlatform.windows;
    if (Platform.isLinux) return ShareImagePlatform.linux;
    return ShareImagePlatform.unsupported;
  }

  @override
  Future<bool> hasGalleryAccess() => Gal.hasAccess();

  @override
  Future<bool> requestGalleryAccess() => Gal.requestAccess();

  @override
  Future<void> saveToGallery(Uint8List bytes, String name) =>
      Gal.putImageBytes(bytes, name: name);

  @override
  Future<String?> pickSavePath(String fileName) async =>
      (await selector.getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const [
          selector.XTypeGroup(
            label: 'PNG image',
            extensions: ['png'],
            uniformTypeIdentifiers: ['public.png'],
          ),
        ],
      ))?.path;

  @override
  Future<void> writeSaveFile(Uint8List bytes, String path) =>
      XFile.fromData(bytes, mimeType: 'image/png').saveTo(path);

  @override
  Future<Directory> temporaryDirectory() => getTemporaryDirectory();

  @override
  Future<ShareResultStatus> shareFile(String path, {Rect? origin}) async =>
      (await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'image/png')],
          sharePositionOrigin: origin,
          downloadFallbackEnabled: false,
        ),
      )).status;
}
