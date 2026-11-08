import 'dart:typed_data';
import 'dart:ui';

import 'share_image_exporter_types.dart';

ShareImageExporter createShareImageExporter() =>
    const UnsupportedShareImageExporter();

/// Web export is not offered until it has a supported download/share flow.
class UnsupportedShareImageExporter implements ShareImageExporter {
  const UnsupportedShareImageExporter();

  @override
  Future<ShareImageExportResult> save(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
  }) async {
    if (!(isCurrent?.call() ?? true)) return ShareImageExportResult.cancelled;
    throw const ShareImageExportException(ShareImageExportFailure.unavailable);
  }

  @override
  Future<ShareImageExportResult> share(
    Uint8List bytes, {
    required String fileName,
    bool Function()? isCurrent,
    Rect? origin,
  }) async {
    if (!(isCurrent?.call() ?? true)) return ShareImageExportResult.cancelled;
    throw const ShareImageExportException(ShareImageExportFailure.unavailable);
  }
}
