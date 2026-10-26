import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'record_photo_file_store_types.dart';
import 'record_photo_file_store_utils.dart';

RecordPhotoFileStoreBackend createRecordPhotoFileStoreBackend({
  RecordPhotoSupportPathProvider? supportPathProvider,
  required int maxFileBytes,
}) {
  return MemoryRecordPhotoFileStoreBackend(maxFileBytes: maxFileBytes);
}

final class MemoryRecordPhotoFileStoreBackend
    implements RecordPhotoFileStoreBackend {
  final int maxFileBytes;
  static final Map<String, Uint8List> _files = <String, Uint8List>{};

  MemoryRecordPhotoFileStoreBackend({
    this.maxFileBytes = defaultRecordPhotoMaxBytes,
  }) {
    if (maxFileBytes <= 0) {
      throw ArgumentError.value(
        maxFileBytes,
        'maxFileBytes',
        'Must be greater than zero.',
      );
    }
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
    if (bytes == null) {
      throw UnsupportedError(
        'Reading a selected photo from sourcePath is unavailable on this '
        'platform. Supply bytes instead.',
      );
    }
    _validateSize(bytes.length);
    final checksum = sha256.convert(bytes).toString();
    final resolvedContentType = normalizeRecordPhotoContentType(
      contentType,
      bytes: bytes,
    );
    return _store(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      purpose: 'selected',
      bytes: bytes,
      checksum: checksum,
      contentType: resolvedContentType,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final stored = _files[path];
    if (stored == null) {
      throw RecordPhotoFileNotFoundException(path);
    }
    return Uint8List.fromList(stored);
  }

  @override
  Future<int> deleteUnreferencedFiles({
    required String ownerId,
    required Set<String> retainedPaths,
    bool Function(String path)? isProtected,
  }) async {
    final prefix = _ownerPrefix(ownerId);
    final retained = retainedPaths.map(_normalizedMemoryPath).toSet();
    var deleted = 0;
    for (final path in _files.keys.toList()) {
      if (!path.startsWith(prefix) ||
          retained.contains(_normalizedMemoryPath(path)) ||
          (isProtected?.call(path) ?? false)) {
        continue;
      }
      _files.remove(path);
      deleted += 1;
    }
    return deleted;
  }

  @override
  Future<void> deleteOwnerFiles(String ownerId) async {
    final prefix = _ownerPrefix(ownerId);
    _files.removeWhere((path, _) => path.startsWith(prefix));
  }

  String _ownerPrefix(String ownerId) {
    final ownerSegment = safeRecordPhotoPathSegment(
      ownerId,
      fieldName: 'ownerId',
    );
    return 'memory-record-photo:///'
        '${p.url.join(recordPhotoStorageDirectoryName, ownerSegment)}/';
  }

  String _normalizedMemoryPath(String path) {
    return Uri.parse(path.trim()).normalizePath().toString();
  }

  StoredRecordPhotoFile _store({
    required String ownerId,
    required String recordId,
    required String photoId,
    required String purpose,
    required Uint8List bytes,
    required String checksum,
    required String contentType,
  }) {
    final path = _path(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      purpose: purpose,
      checksum: checksum,
      contentType: contentType,
    );
    _files[path] = Uint8List.fromList(bytes);
    return StoredRecordPhotoFile(
      path: path,
      checksum: checksum,
      byteLength: bytes.length,
      contentType: contentType,
    );
  }

  String _path({
    required String ownerId,
    required String recordId,
    required String photoId,
    required String purpose,
    required String checksum,
    required String contentType,
  }) {
    final relativePath = recordPhotoRelativePath(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      purpose: purpose,
      checksum: checksum,
      contentType: contentType,
    );
    return 'memory-record-photo:///${p.url.joinAll(p.split(relativePath))}';
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
}
