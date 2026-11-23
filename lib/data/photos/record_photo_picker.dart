import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'record_photo_file_store.dart';

enum RecordPhotoSource { gallery, systemPicker, camera }

typedef SelectedRecordPhoto = Future<Uint8List> Function();

class RecordPhotoPicker {
  static const _gallery = MethodChannel('fishing_build/external_gallery');

  final _imagePicker = ImagePicker();

  Future<List<SelectedRecordPhoto>> pick({
    required RecordPhotoSource source,
    required int limit,
    required int maxBytes,
  }) async {
    if (source == RecordPhotoSource.gallery &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      final uris = await _pickFromGallery(limit, maxBytes);
      if (uris != null) {
        return [for (final uri in uris) () => _readGalleryPhoto(uri, maxBytes)];
      }
    }

    final List<XFile> files;
    if (source != RecordPhotoSource.camera && limit > 1) {
      files = await _imagePicker.pickMultiImage(limit: limit);
    } else {
      final file = await _imagePicker.pickImage(
        source: source == RecordPhotoSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
      );
      files = [?file];
    }
    return [for (final file in files) () => _readFile(file, maxBytes)];
  }

  Future<List<String>?> _pickFromGallery(int limit, int maxBytes) async {
    try {
      return await _gallery.invokeListMethod<String>('pick', {
        'limit': limit,
        'maxBytes': maxBytes,
      });
    } on MissingPluginException {
      return null;
    }
  }

  Future<Uint8List> _readGalleryPhoto(String uri, int maxBytes) async {
    try {
      final bytes = await _gallery.invokeMethod<Uint8List>('read', {
        'uri': uri,
        'maxBytes': maxBytes,
      });
      if (bytes == null) {
        throw StateError('The gallery did not return image data.');
      }
      return bytes;
    } on PlatformException catch (error) {
      if (error.code != 'photo-too-large') rethrow;
      final reportedSize = error.details;
      throw RecordPhotoTooLargeException(
        actualBytes: reportedSize is int ? reportedSize : maxBytes + 1,
        maxBytes: maxBytes,
      );
    }
  }

  Future<Uint8List> _readFile(XFile file, int maxBytes) async {
    final length = await file.length();
    if (length > maxBytes) {
      throw RecordPhotoTooLargeException(
        actualBytes: length,
        maxBytes: maxBytes,
      );
    }
    return file.readAsBytes();
  }
}
