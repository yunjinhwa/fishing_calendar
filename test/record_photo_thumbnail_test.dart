import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/presentation/record/record_photo_image.dart';
import 'package:fishing_build/presentation/record/record_photo_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _PhotoReader = Future<Uint8List> Function(String path);

void main() {
  testWidgets('DPR changes resize the decode without rereading the photo', (
    tester,
  ) async {
    final bytes = _png();
    final paths = <String>[];
    Future<Uint8List> reader(String path) async {
      paths.add(path);
      return bytes;
    }

    await tester.pumpWidget(
      _preview(path: ' photo.png ', reader: reader, size: 95.5, dpr: 1.25),
    );
    await tester.pump();
    expect(_memoryPreview(tester).pixelSize, 120);
    expect(_previewBytes(tester), same(bytes));
    await _finishDecode(tester);

    // Replacing the model and presentation options keeps the same local read.
    await tester.pumpWidget(
      _preview(
        path: 'photo.png',
        reader: reader,
        size: 95.5,
        dpr: 1.25,
        compact: true,
      ),
    );
    expect(_memoryPreview(tester).pixelSize, 120);

    for (final (dpr, expectedPixels) in [
      (2.5, 239),
      (100.0, RecordPhotoImage.maxDimension),
      (0.001, 1),
    ]) {
      await tester.pumpWidget(
        _preview(path: 'photo.png', reader: reader, size: 95.5, dpr: dpr),
      );
      expect(_memoryPreview(tester).pixelSize, expectedPixels);
      expect(_previewBytes(tester), same(bytes));
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, 95.5);
      expect(image.height, 95.5);
      expect(image.fit, BoxFit.cover);
      await _finishDecode(tester);
    }

    expect(paths, ['photo.png']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('path changes hide the old photo and ignore stale reads', (
    tester,
  ) async {
    final firstBytes = _png();
    final staleBytes = _png();
    final currentBytes = _png();
    final stale = Completer<Uint8List>();
    final current = Completer<Uint8List>();
    final paths = <String>[];
    Future<Uint8List> reader(String path) {
      paths.add(path);
      return switch (path) {
        'first.png' => Future.value(firstBytes),
        'stale.png' => stale.future,
        'current.png' => current.future,
        _ => throw StateError('Unexpected path: $path'),
      };
    }

    await tester.pumpWidget(_preview(path: 'first.png', reader: reader));
    await tester.pump();
    await _finishDecode(tester);
    expect(_previewBytes(tester), same(firstBytes));

    await tester.pumpWidget(_preview(path: 'stale.png', reader: reader));
    _expectLoading();
    await tester.pumpWidget(_preview(path: 'current.png', reader: reader));
    _expectLoading();

    stale.complete(staleBytes);
    await tester.pump();
    _expectLoading();

    current.complete(currentBytes);
    await tester.pumpAndSettle();
    expect(_previewBytes(tester), same(currentBytes));
    await _finishDecode(tester);
    expect(paths, ['first.png', 'stale.png', 'current.png']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader changes reload the same path and ignore stale errors', (
    tester,
  ) async {
    final firstBytes = _png();
    final currentBytes = _png();
    final stale = Completer<Uint8List>();
    final current = Completer<Uint8List>();
    final calls = <String>[];
    Future<Uint8List> firstReader(String path) async {
      calls.add('first:$path');
      return firstBytes;
    }

    Future<Uint8List> staleReader(String path) {
      calls.add('stale:$path');
      return stale.future;
    }

    Future<Uint8List> currentReader(String path) {
      calls.add('current:$path');
      return current.future;
    }

    await tester.pumpWidget(_preview(path: 'photo.png', reader: firstReader));
    await tester.pump();
    await _finishDecode(tester);
    expect(_previewBytes(tester), same(firstBytes));

    await tester.pumpWidget(_preview(path: 'photo.png', reader: staleReader));
    _expectLoading();
    await tester.pumpWidget(_preview(path: 'photo.png', reader: currentReader));
    _expectLoading();

    stale.completeError(StateError('The previous reader failed'));
    await tester.pump();
    _expectLoading();
    expect(find.text(_errorLabel), findsNothing);

    current.complete(currentBytes);
    await tester.pumpAndSettle();
    expect(_previewBytes(tester), same(currentBytes));
    await _finishDecode(tester);
    expect(calls, ['first:photo.png', 'stale:photo.png', 'current:photo.png']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty paths show a placeholder without reading any bytes', (
    tester,
  ) async {
    var reads = 0;
    Future<Uint8List> unexpectedReader(String path) async {
      reads++;
      throw StateError('An empty path must not be read');
    }

    for (final path in <String?>[null, '', ' \n\t ']) {
      await tester.pumpWidget(_preview(path: path, reader: unexpectedReader));
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(reads, 0);
  });

  testWidgets('read and decode errors show safe error placeholders', (
    tester,
  ) async {
    final failingReaders = <_PhotoReader>[
      (_) => throw StateError('Synchronous read failure'),
      (_) => Future.error(StateError('Asynchronous read failure')),
    ];
    for (final reader in failingReaders) {
      await tester.pumpWidget(_preview(path: 'broken.png', reader: reader));
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text(_errorLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(
      _preview(
        path: 'corrupt.png',
        reader: (_) async => Uint8List.fromList([1, 2, 3, 4]),
        compact: true,
      ),
    );
    await tester.pump();
    await _finishDecode(tester);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.text(_errorLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending reads can complete or fail after disposal', (
    tester,
  ) async {
    for (final fails in [false, true]) {
      final pending = Completer<Uint8List>();
      await tester.pumpWidget(
        _preview(path: 'pending.png', reader: (_) => pending.future),
      );
      _expectLoading();
      await tester.pumpWidget(const SizedBox.shrink());

      if (fails) {
        pending.completeError(StateError('Read failed after disposal'));
      } else {
        pending.complete(_png());
      }
      await tester.pump();

      expect(find.byType(RecordPhotoThumbnail), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}

const _errorLabel = 'Preview unavailable';

Widget _preview({
  required String? path,
  _PhotoReader? reader,
  double size = 96,
  double dpr = 1,
  bool compact = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(devicePixelRatio: dpr),
    child: Center(
      child: RecordPhotoThumbnail(
        photo: RecordPhoto(id: 'local-photo', localPath: path),
        size: size,
        compact: compact,
        errorLabel: _errorLabel,
        photoReader: reader,
      ),
    ),
  ),
);

RecordPhotoImage<MemoryImage> _memoryPreview(WidgetTester tester) =>
    tester.widget<Image>(find.byType(Image)).image
        as RecordPhotoImage<MemoryImage>;

Uint8List _previewBytes(WidgetTester tester) =>
    (_memoryPreview(tester).source as MemoryImage).bytes;

void _expectLoading() {
  expect(find.byType(Image), findsNothing);
  expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
}

// A valid 2-by-2 RGBA PNG. Each call creates a distinct source/cache identity.
Uint8List _png() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMQrs38D8IM'
  'MAYAQZIH4XTlNsEAAAAASUVORK5CYII=',
);

Future<void> _finishDecode(WidgetTester tester) async {
  final provider = tester.widget<Image>(find.byType(Image)).image;
  await tester.runAsync(() async {
    final completed = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (image, synchronousCall) {
        image.dispose();
        if (!completed.isCompleted) completed.complete();
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!completed.isCompleted) completed.complete();
      },
    );
    stream.addListener(listener);
    try {
      await completed.future;
    } finally {
      stream.removeListener(listener);
    }
  });
  await tester.pump();
}
