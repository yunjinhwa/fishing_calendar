import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

typedef ShareImageCapture = Future<Uint8List> Function(GlobalKey boundaryKey);

/// Captures only the card, never its options, navigation or surrounding UI.
Future<Uint8List> captureShareImage(GlobalKey boundaryKey) async {
  final boundary = boundaryKey.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary ||
      boundary.size.isEmpty ||
      boundary.size.width > 400 ||
      boundary.size.height > 800) {
    throw StateError('Share card is unavailable.');
  }
  final image = await boundary.toImage(pixelRatio: 3);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null || png.lengthInBytes > 10 * 1024 * 1024) {
      throw StateError('Share card could not be encoded.');
    }
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}
