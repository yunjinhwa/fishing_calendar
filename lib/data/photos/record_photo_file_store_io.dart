import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'record_photo_file_store_types.dart';
import 'record_photo_file_store_utils.dart';

RecordPhotoFileStoreBackend createRecordPhotoFileStoreBackend({
  RecordPhotoSupportPathProvider? supportPathProvider,
  required int maxFileBytes,
}) {
  return IoRecordPhotoFileStoreBackend(
    supportPathProvider: supportPathProvider,
    maxFileBytes: maxFileBytes,
  );
}

final class IoRecordPhotoFileStoreBackend
    implements RecordPhotoFileStoreBackend {
  final RecordPhotoSupportPathProvider _supportPathProvider;
  final int maxFileBytes;
  final Random _random;

  IoRecordPhotoFileStoreBackend({
    RecordPhotoSupportPathProvider? supportPathProvider,
    this.maxFileBytes = defaultRecordPhotoMaxBytes,
    Random? random,
  }) : _supportPathProvider =
           supportPathProvider ?? _defaultSupportDirectoryPath,
       _random = random ?? Random.secure() {
    if (maxFileBytes <= 0) {
      throw ArgumentError.value(
        maxFileBytes,
        'maxFileBytes',
        'Must be greater than zero.',
      );
    }
  }

  static Future<String> _defaultSupportDirectoryPath() async {
    return (await getApplicationSupportDirectory()).path;
  }

  @override
  Future<StoredRecordPhotoFile> persistSelection({
    required String ownerId,
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) async {
    if ((bytes == null) == (sourcePath == null)) {
      throw ArgumentError(
        'Provide exactly one of bytes or sourcePath for a selected photo.',
      );
    }

    late final Uint8List photoBytes;
    if (bytes != null) {
      photoBytes = bytes;
    } else {
      final path = sourcePath!.trim();
      if (path.isEmpty) {
        throw ArgumentError.value(
          sourcePath,
          'sourcePath',
          'Must not be empty.',
        );
      }
      photoBytes = await _readFileBytes(path);
    }
    _validateSize(photoBytes.length);

    final checksum = sha256.convert(photoBytes).toString();
    final resolvedContentType = normalizeRecordPhotoContentType(
      contentType,
      sourcePath: sourcePath,
      bytes: photoBytes,
    );
    return _store(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      purpose: 'selected',
      bytes: photoBytes,
      checksum: checksum,
      contentType: resolvedContentType,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Must not be empty.');
    }
    return _readFileBytes(normalized);
  }

  @override
  Future<int> deleteUnreferencedFiles({
    required String ownerId,
    required Set<String> retainedPaths,
    bool Function(String path)? isProtected,
  }) async {
    final ownerDirectory = await _validatedOwnerDirectory(ownerId);
    if (ownerDirectory == null) {
      return 0;
    }
    return _deleteManagedFiles(
      ownerDirectory,
      ownerRoot: ownerDirectory.path,
      retainedPaths: retainedPaths.map(_comparisonPath).toSet(),
      isProtected: isProtected,
    );
  }

  @override
  Future<void> deleteOwnerFiles(String ownerId) async {
    final ownerDirectory = await _validatedOwnerDirectory(ownerId);
    if (ownerDirectory == null) {
      return;
    }
    await _deleteManagedFiles(
      ownerDirectory,
      ownerRoot: ownerDirectory.path,
      retainedPaths: const <String>{},
      removeEmptyDirectories: true,
    );
  }

  Future<Directory?> _validatedOwnerDirectory(String ownerId) async {
    final rootPath = (await _supportPathProvider()).trim();
    if (rootPath.isEmpty) {
      throw const RecordPhotoFileStoreException(
        'Application support directory path is empty.',
      );
    }
    final root = p.normalize(p.absolute(rootPath));
    final ownerDirectory = Directory(
      p.join(
        root,
        recordPhotoStorageDirectoryName,
        safeRecordPhotoPathSegment(ownerId, fieldName: 'ownerId'),
      ),
    );
    final target = p.normalize(p.absolute(ownerDirectory.path));
    if (!p.isWithin(root, target)) {
      throw const RecordPhotoFileStoreException(
        'Resolved photo directory is outside the application support path.',
      );
    }
    // Check the full ancestor chain, including the application support path.
    // Merely checking that the lexical target is within root would allow a
    // symlink or Windows junction to redirect deletion outside that root.
    var currentPath = p.rootPrefix(target);
    for (final segment in p.split(target)) {
      if (p.equals(segment, currentPath)) {
        continue;
      }
      currentPath = p.join(currentPath, segment);
      final type = await FileSystemEntity.type(currentPath, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return null;
      }
      if (type != FileSystemEntityType.directory ||
          !await _hasCanonicalDirectoryPath(Directory(currentPath))) {
        throw const RecordPhotoFileStoreException(
          'Managed photo directory contains a redirected or invalid path.',
        );
      }
    }
    return ownerDirectory;
  }

  Future<int> _deleteManagedFiles(
    Directory directory, {
    required String ownerRoot,
    required Set<String> retainedPaths,
    bool Function(String path)? isProtected,
    bool removeEmptyDirectories = false,
  }) async {
    if (!await _isSafeManagedDirectory(directory, ownerRoot)) {
      return 0;
    }
    var deleted = 0;
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        deleted += await _deleteManagedFiles(
          Directory(entity.path),
          ownerRoot: ownerRoot,
          retainedPaths: retainedPaths,
          isProtected: isProtected,
          removeEmptyDirectories: removeEmptyDirectories,
        );
      } else if (type == FileSystemEntityType.file) {
        final file = File(entity.path);
        if (retainedPaths.contains(_comparisonPath(file.path)) ||
            !await _isSafeManagedFile(file, ownerRoot)) {
          continue;
        }
        // Keep this synchronous check adjacent to deletion: a draft may have
        // pinned a photo while the filesystem checks above were awaiting IO.
        if (isProtected?.call(file.path) ?? false) {
          continue;
        }
        try {
          await file.delete();
          deleted += 1;
        } on FileSystemException {
          if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            rethrow;
          }
        }
      }
      // Links (including directory links) and other entity types are neither
      // followed nor deleted. Resolving canonical paths also rejects junctions
      // on platforms that report them as ordinary directories.
    }
    if (removeEmptyDirectories &&
        await _isSafeManagedDirectory(directory, ownerRoot) &&
        await directory.list(followLinks: false).isEmpty) {
      await directory.delete();
    }
    return deleted;
  }

  Future<bool> _isSafeManagedDirectory(
    Directory directory,
    String ownerRoot,
  ) async {
    final path = p.normalize(p.absolute(directory.path));
    if (!p.equals(ownerRoot, path) && !p.isWithin(ownerRoot, path)) {
      return false;
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    return _hasCanonicalDirectoryPath(directory);
  }

  Future<bool> _hasCanonicalDirectoryPath(Directory directory) async {
    try {
      return _comparisonPath(await directory.resolveSymbolicLinks()) ==
          _comparisonPath(directory.path);
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _isSafeManagedFile(File file, String ownerRoot) async {
    if (!p.isWithin(ownerRoot, p.normalize(p.absolute(file.path))) ||
        !await _isSafeManagedDirectory(file.parent, ownerRoot) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }
    try {
      if (_comparisonPath(await file.resolveSymbolicLinks()) !=
          _comparisonPath(file.path)) {
        return false;
      }
    } on FileSystemException {
      return false;
    }
    return true;
  }

  String _comparisonPath(String path) {
    final normalized = p.normalize(p.absolute(path.trim()));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<Uint8List> _readFileBytes(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw RecordPhotoFileNotFoundException(path);
    }
    _validateSize(stat.size);
    final bytes = await file.readAsBytes();
    _validateSize(bytes.length);
    return bytes;
  }

  Future<StoredRecordPhotoFile> _store({
    required String ownerId,
    required String recordId,
    required String photoId,
    required String purpose,
    required Uint8List bytes,
    required String checksum,
    required String contentType,
  }) async {
    final target = await _targetFile(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      purpose: purpose,
      checksum: checksum,
      contentType: contentType,
    );
    await target.parent.create(recursive: true);

    if (await target.exists()) {
      final existing = await _readFileBytes(target.path);
      if (sha256.convert(existing).toString() == checksum) {
        return StoredRecordPhotoFile(
          path: target.path,
          checksum: checksum,
          byteLength: existing.length,
          contentType: contentType,
        );
      }
    }

    final temporary = File(
      p.join(
        target.parent.path,
        '.${p.basename(target.path)}.$pid.'
        '${DateTime.now().microsecondsSinceEpoch}.'
        '${_random.nextInt(0x7fffffff)}.tmp',
      ),
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } on FileSystemException {
      if (!await target.exists()) {
        rethrow;
      }
      final existing = await _readFileBytes(target.path);
      if (sha256.convert(existing).toString() != checksum) {
        rethrow;
      }
    } finally {
      await _deleteIfPresent(temporary);
    }

    return StoredRecordPhotoFile(
      path: target.path,
      checksum: checksum,
      byteLength: bytes.length,
      contentType: contentType,
    );
  }

  Future<File> _targetFile({
    required String ownerId,
    required String recordId,
    required String photoId,
    required String purpose,
    required String checksum,
    required String contentType,
  }) async {
    final rootPath = (await _supportPathProvider()).trim();
    if (rootPath.isEmpty) {
      throw const RecordPhotoFileStoreException(
        'Application support directory path is empty.',
      );
    }
    final relativePath = recordPhotoRelativePath(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      purpose: purpose,
      checksum: checksum,
      contentType: contentType,
    );
    return File(p.join(p.normalize(p.absolute(rootPath)), relativePath));
  }

  void _validateSize(int byteLength) {
    if (byteLength < 1) {
      throw const RecordPhotoFileStoreException(
        'Photo file must contain at least one byte.',
      );
    }
    if (byteLength > maxFileBytes) {
      throw RecordPhotoTooLargeException(
        actualBytes: byteLength,
        maxBytes: maxFileBytes,
      );
    }
  }

  Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // A stale temporary or corrupt cache file can be cleaned up later.
    }
  }
}
