import 'dart:typed_data';

const int defaultRecordPhotoMaxBytes = 10 * 1024 * 1024;

typedef RecordPhotoSupportPathProvider = Future<String> Function();

final class StoredRecordPhotoFile {
  final String path;
  final String checksum;
  final int byteLength;
  final String contentType;

  const StoredRecordPhotoFile({
    required this.path,
    required this.checksum,
    required this.byteLength,
    required this.contentType,
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StoredRecordPhotoFile &&
            path == other.path &&
            checksum == other.checksum &&
            byteLength == other.byteLength &&
            contentType == other.contentType;
  }

  @override
  int get hashCode => Object.hash(path, checksum, byteLength, contentType);

  @override
  String toString() {
    return 'StoredRecordPhotoFile('
        'path: $path, '
        'checksum: $checksum, '
        'byteLength: $byteLength, '
        'contentType: $contentType)';
  }
}

abstract interface class RecordPhotoFileStoreBackend {
  Future<StoredRecordPhotoFile> persistSelection({
    required String ownerId,
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  });

  Future<Uint8List> readBytes(String path);

  Future<void> deleteOwnerFiles(String ownerId);
}

class RecordPhotoFileStoreException implements Exception {
  final String message;

  const RecordPhotoFileStoreException(this.message);

  @override
  String toString() => 'RecordPhotoFileStoreException: $message';
}

final class RecordPhotoTooLargeException extends RecordPhotoFileStoreException {
  final int actualBytes;
  final int maxBytes;

  const RecordPhotoTooLargeException({
    required this.actualBytes,
    required this.maxBytes,
  }) : super('Photo size $actualBytes bytes exceeds the $maxBytes byte limit.');
}

final class RecordPhotoFileNotFoundException
    extends RecordPhotoFileStoreException {
  final String path;

  const RecordPhotoFileNotFoundException(this.path)
    : super('Photo file does not exist: $path');
}
