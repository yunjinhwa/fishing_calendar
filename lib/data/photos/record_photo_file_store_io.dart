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
  Future<void> deleteOwnerFiles(String ownerId) async {
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
    if (await ownerDirectory.exists()) {
      await ownerDirectory.delete(recursive: true);
    }
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
