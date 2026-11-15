import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Decodes a device-local photo at a bounded size without changing its source.
///
/// The shorter edge reaches [pixelSize] when the original and [decodeLimit]
/// allow it. Wide or tall photos stop at the long-edge limit instead of retaining
/// an arbitrarily large decoded image for [BoxFit.cover].
@immutable
class RecordPhotoImage<T extends Object>
    extends ImageProvider<RecordPhotoImageKey<T>> {
  const RecordPhotoImage(
    this.source, {
    required this.pixelSize,
    this.decodeLimit = maxDimension,
  }) : assert(pixelSize > 0),
       assert(decodeLimit > 0);

  static const int maxDimension = 1200;

  /// An unresized image provider, such as [FileImage] or [MemoryImage].
  final ImageProvider<T> source;

  /// The square preview's side length in physical pixels.
  final int pixelSize;

  /// Long-edge ceiling; enlarged views use a separate, higher cache limit.
  final int decodeLimit;

  @override
  bool operator ==(Object other) =>
      other is RecordPhotoImage<Object> &&
      other.source == source &&
      other.pixelSize == pixelSize &&
      other.decodeLimit == decodeLimit;

  @override
  int get hashCode => Object.hash(source, pixelSize, decodeLimit);

  @override
  Future<RecordPhotoImageKey<T>> obtainKey(ImageConfiguration configuration) {
    return source
        .obtainKey(configuration)
        .then(
          (sourceKey) => RecordPhotoImageKey<T>(
            sourceKey: sourceKey,
            pixelSize: pixelSize,
            decodeLimit: decodeLimit,
          ),
        );
  }

  @override
  ImageStreamCompleter loadImage(
    RecordPhotoImageKey<T> key,
    ImageDecoderCallback decode,
  ) {
    final completer = source.loadImage(key.sourceKey, (
      buffer, {
      getTargetSize,
    }) {
      assert(
        getTargetSize == null,
        'RecordPhotoImage requires an unresized source image provider.',
      );
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final coverScale = math.max(
            key.pixelSize / intrinsicWidth,
            key.pixelSize / intrinsicHeight,
          );
          final limitScale =
              key.decodeLimit / math.max(intrinsicWidth, intrinsicHeight);
          final scale = math.min(1.0, math.min(coverScale, limitScale));
          return ui.TargetImageSize(
            width: math.max(1, (intrinsicWidth * scale).floor()),
            height: math.max(1, (intrinsicHeight * scale).floor()),
          );
        },
      );
    });
    completer.addEphemeralErrorListener((error, stackTrace) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }
}

/// Identifies both the original image and its physical preview size in cache.
@immutable
class RecordPhotoImageKey<T extends Object> {
  const RecordPhotoImageKey({
    required this.sourceKey,
    required this.pixelSize,
    this.decodeLimit = RecordPhotoImage.maxDimension,
  });

  final T sourceKey;
  final int pixelSize;
  final int decodeLimit;

  @override
  bool operator ==(Object other) =>
      other is RecordPhotoImageKey<Object> &&
      other.sourceKey == sourceKey &&
      other.pixelSize == pixelSize &&
      other.decodeLimit == decodeLimit;

  @override
  int get hashCode => Object.hash(sourceKey, pixelSize, decodeLimit);
}
