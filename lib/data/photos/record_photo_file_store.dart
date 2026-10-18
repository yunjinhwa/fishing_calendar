import 'dart:typed_data';

import 'record_photo_file_store_stub.dart'
    if (dart.library.io) 'record_photo_file_store_io.dart'
    as platform;
import 'record_photo_file_store_types.dart';

export 'record_photo_file_store_types.dart'
    show
        StoredRecordPhotoFile,
        RecordPhotoFileStoreBackend,
        RecordPhotoFileStoreException,
        RecordPhotoTooLargeException,
        RecordPhotoFileNotFoundException,
        RecordPhotoSupportPathProvider,
        defaultRecordPhotoMaxBytes;

final class RecordPhotoFileStore implements RecordPhotoFileStoreBackend {
  final RecordPhotoFileStoreBackend _backend;

  factory RecordPhotoFileStore({
    RecordPhotoSupportPathProvider? supportPathProvider,
    int maxFileBytes = defaultRecordPhotoMaxBytes,
  }) {
    if (maxFileBytes <= 0) {
      throw ArgumentError.value(
        maxFileBytes,
        'maxFileBytes',
        'Must be greater than zero.',
      );
    }
    return RecordPhotoFileStore.withBackend(
      platform.createRecordPhotoFileStoreBackend(
        supportPathProvider: supportPathProvider,
        maxFileBytes: maxFileBytes,
      ),
    );
  }

  const RecordPhotoFileStore.withBackend(this._backend);

  @override
  Future<StoredRecordPhotoFile> persistSelection({
    required String ownerId,
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) {
    return _backend.persistSelection(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      bytes: bytes,
      sourcePath: sourcePath,
      contentType: contentType,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) => _backend.readBytes(path);

  @override
  Future<void> deleteOwnerFiles(String ownerId) =>
      _backend.deleteOwnerFiles(ownerId);
}
