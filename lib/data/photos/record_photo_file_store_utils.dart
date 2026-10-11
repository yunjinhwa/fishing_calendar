import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const String recordPhotoStorageDirectoryName = 'record_photo_files_v1';

String safeRecordPhotoPathSegment(String value, {required String fieldName}) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, fieldName, 'Must not be empty.');
  }
  return sha256.convert(utf8.encode(normalized)).toString().substring(0, 32);
}

String normalizeRecordPhotoContentType(
  String? contentType, {
  String? sourcePath,
  Uint8List? bytes,
}) {
  final normalized = contentType?.split(';').first.trim().toLowerCase();
  if (normalized != null && normalized.isNotEmpty) {
    return normalized;
  }

  final extension = sourcePath == null
      ? ''
      : p.extension(sourcePath).toLowerCase();
  final fromExtension = switch (extension) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    '.heic' => 'image/heic',
    '.heif' => 'image/heif',
    '.bmp' => 'image/bmp',
    _ => null,
  };
  if (fromExtension != null) {
    return fromExtension;
  }

  return detectRecordPhotoContentType(bytes) ?? 'application/octet-stream';
}

String? detectRecordPhotoContentType(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return 'image/png';
  }
  if (bytes.length >= 6) {
    final header = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
    if (header == 'GIF87a' || header == 'GIF89a') {
      return 'image/gif';
    }
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image/webp';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp') {
    final brand = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
    if (brand == 'heic' || brand == 'heix' || brand == 'hevc') {
      return 'image/heic';
    }
    if (brand == 'heif' || brand == 'mif1' || brand == 'msf1') {
      return 'image/heif';
    }
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    return 'image/bmp';
  }
  return null;
}

String recordPhotoExtensionFor(String contentType) {
  return switch (contentType.toLowerCase()) {
    'image/jpeg' || 'image/jpg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/heic' => 'heic',
    'image/heif' => 'heif',
    'image/bmp' => 'bmp',
    _ => 'bin',
  };
}

String recordPhotoRelativePath({
  required String ownerId,
  required String recordId,
  required String photoId,
  required String purpose,
  required String checksum,
  required String contentType,
}) {
  return p.join(
    recordPhotoStorageDirectoryName,
    safeRecordPhotoPathSegment(ownerId, fieldName: 'ownerId'),
    safeRecordPhotoPathSegment(recordId, fieldName: 'recordId'),
    safeRecordPhotoPathSegment(photoId, fieldName: 'photoId'),
    purpose,
    '$checksum.${recordPhotoExtensionFor(contentType)}',
  );
}
