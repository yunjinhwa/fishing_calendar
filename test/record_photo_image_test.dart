import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fishing_build/presentation/record/record_photo_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('landscape and portrait decode to cover without stretching', () async {
    for (final (width, height, expectedWidth, expectedHeight) in [
      (4000, 3000, 480, 360),
      (3000, 4000, 360, 480),
    ]) {
      final image = await _decode(
        RecordPhotoImage(
          MemoryImage(await _png(width, height)),
          pixelSize: 360,
        ),
      );
      try {
        expect(image.image.width, expectedWidth);
        expect(image.image.height, expectedHeight);
        expect(image.image.width / image.image.height, width / height);
      } finally {
        image.dispose();
      }
    }
  });

  test('small originals retain their native decoded dimensions', () async {
    for (final (width, height) in [(40, 30), (30, 40), (1, 1)]) {
      final image = await _decode(
        RecordPhotoImage(
          MemoryImage(await _png(width, height)),
          pixelSize: 360,
        ),
      );
      try {
        expect(image.image.width, width);
        expect(image.image.height, height);
      } finally {
        image.dispose();
      }
    }
  });

  test(
    'enlarged views use a separate bounded decode without changing bytes',
    () async {
      final bytes = await _png(4000, 3000);
      final original = Uint8List.fromList(bytes);
      final source = MemoryImage(bytes);
      final thumbnail = RecordPhotoImage(source, pixelSize: 5000);
      final enlarged = RecordPhotoImage(
        source,
        pixelSize: 5000,
        decodeLimit: 3072,
      );
      expect(thumbnail, isNot(enlarged));
      expect(
        await thumbnail.obtainKey(ImageConfiguration.empty),
        isNot(await enlarged.obtainKey(ImageConfiguration.empty)),
      );
      for (final (provider, width, height) in [
        (thumbnail, 1200, 900),
        (enlarged, 3072, 2304),
      ]) {
        final image = await _decode(provider);
        try {
          expect(image.image.width, width);
          expect(image.image.height, height);
        } finally {
          image.dispose();
        }
      }
      expect(bytes, original);
    },
  );

  test('panoramas stay bounded and never request a zero-sized edge', () async {
    for (final (width, height, expectedWidth, expectedHeight) in [
      (12000, 1000, 1200, 100),
      (1000, 12000, 100, 1200),
      (16000, 1, 1200, 1),
      (1, 16000, 1, 1200),
    ]) {
      final image = await _decode(
        RecordPhotoImage(
          MemoryImage(await _png(width, height)),
          pixelSize: 360,
        ),
      );
      try {
        expect(image.image.width, expectedWidth);
        expect(image.image.height, expectedHeight);
        expect(image.image.width, inInclusiveRange(1, 1200));
        expect(image.image.height, inInclusiveRange(1, 1200));
      } finally {
        image.dispose();
      }
    }
  });

  test(
    'cache keys follow the original and physical size across DPRs',
    () async {
      final bytes = await _png(4000, 3000);
      final source = MemoryImage(bytes);
      final oneX = RecordPhotoImage(source, pixelSize: 96);
      final threeX = RecordPhotoImage(source, pixelSize: 288);
      final key = await oneX.obtainKey(ImageConfiguration.empty);
      final equivalent = await RecordPhotoImage(
        MemoryImage(bytes),
        pixelSize: 96,
      ).obtainKey(ImageConfiguration.empty);

      expect(key.sourceKey, await source.obtainKey(ImageConfiguration.empty));
      expect(key, equivalent);
      expect(key.hashCode, equivalent.hashCode);
      expect(key, isNot(await threeX.obtainKey(ImageConfiguration.empty)));
      expect(
        key,
        isNot(
          await RecordPhotoImage(
            MemoryImage(Uint8List.fromList(bytes)),
            pixelSize: 96,
          ).obtainKey(ImageConfiguration.empty),
        ),
      );

      for (final (provider, expectedWidth, expectedHeight) in [
        (oneX, 128, 96),
        (threeX, 384, 288),
        (RecordPhotoImage(source, pixelSize: 5000), 1200, 900),
      ]) {
        final image = await _decode(provider);
        try {
          expect(image.image.width, expectedWidth);
          expect(image.image.height, expectedHeight);
        } finally {
          image.dispose();
        }
      }
    },
  );

  test('FileImage decoding leaves the original encoded file intact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'record-photo-image-',
    );
    final file = File.fromUri(directory.uri.resolve('original.png'));
    try {
      final bytes = await _png(4000, 3000);
      await file.writeAsBytes(bytes, flush: true);
      final image = await _decode(
        RecordPhotoImage(FileImage(file), pixelSize: 360),
      );
      try {
        expect(image.image.width, 480);
        expect(image.image.height, 360);
        expect(await file.readAsBytes(), bytes);
        expect(directory.listSync().map((entry) => entry.path), [file.path]);
      } finally {
        image.dispose();
      }
    } finally {
      if (await file.exists()) await file.delete();
      await directory.delete();
    }
  });

  test(
    'ten actual decodes shrink pixel buffers while preserving bytes',
    () async {
      // Encode and dispose the full-size fixture before retaining any thumbnails.
      final bytes = await _png(4000, 3000);
      final original = Uint8List.fromList(bytes);
      const physicalSizes = [96, 192, 288, 384, 480, 120, 240, 360, 480, 600];
      final sources = [
        for (final _ in physicalSizes) MemoryImage(Uint8List.fromList(bytes)),
      ];
      final images = <ImageInfo>[];
      try {
        for (var i = 0; i < sources.length; i++) {
          images.add(
            await _decode(
              RecordPhotoImage(sources[i], pixelSize: physicalSizes[i]),
            ),
          );
        }
        var decodedBytes = 0;
        for (var i = 0; i < images.length; i++) {
          final image = images[i].image;
          final rgba = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(image.width, physicalSizes[i] * 4 ~/ 3);
          expect(image.height, physicalSizes[i]);
          expect(rgba!.lengthInBytes, image.width * image.height * 4);
          expect(sources[i].bytes, original);
          decodedBytes += rgba.lengthInBytes;
        }
        expect(images, hasLength(10));
        expect(decodedBytes, lessThan(10 * 4000 * 3000 * 4 ~/ 50));
        expect(bytes, original);
      } finally {
        for (final image in images) {
          image.dispose();
        }
      }
    },
  );
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff137d69), ui.BlendMode.src);
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Future<ImageInfo> _decode<T extends Object>(
  RecordPhotoImage<T> provider,
) async {
  final key = await provider.obtainKey(ImageConfiguration.empty);
  final completer = provider.loadImage(
    key,
    PaintingBinding.instance.instantiateImageCodecWithSize,
  );
  final result = Completer<ImageInfo>();
  final listener = ImageStreamListener(
    (image, synchronousCall) => result.complete(image),
    onError: (Object error, StackTrace? stackTrace) =>
        result.completeError(error, stackTrace),
  );
  completer.addListener(listener);
  try {
    return await result.future;
  } finally {
    completer.removeListener(listener);
  }
}
