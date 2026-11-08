import 'share_image_exporter_stub.dart'
    if (dart.library.io) 'share_image_exporter_io.dart'
    as platform;
import 'share_image_exporter_types.dart';

export 'share_image_exporter_types.dart';

/// Construction has no filesystem, permission, or native plugin side effects.
ShareImageExporter createShareImageExporter() =>
    platform.createShareImageExporter();
