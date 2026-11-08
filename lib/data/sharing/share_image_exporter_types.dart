import 'dart:typed_data';
import 'dart:ui';

/// The native sheet can report selection, but cannot guarantee delivery.
enum ShareImageExportResult { saved, shared, cancelled, shareSheetOpened }

enum ShareImageExportFailure {
  permissionDenied,
  unavailable,
  invalidImage,
  storageFull,
  failed,
}

/// Deliberately excludes platform messages and local file paths.
class ShareImageExportException implements Exception {
  const ShareImageExportException(this.reason);

  final ShareImageExportFailure reason;

  @override
  String toString() => 'ShareImageExportException(${reason.name})';
}

abstract interface class ShareImageExporter {
  Future<ShareImageExportResult> save(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
  });

  Future<ShareImageExportResult> share(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
    Rect? origin,
  });
}
