import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/models/fishing_record.dart';
import '../../data/photos/record_photo_file_store.dart';
import 'record_photo_image.dart';

/// A bounded, device-local preview. Reading or decoding never rewrites the
/// original file; memory-backed reads belong only to this widget's lifetime.
class RecordPhotoThumbnail extends StatefulWidget {
  const RecordPhotoThumbnail({
    super.key,
    required this.photo,
    required this.size,
    this.compact = false,
    this.errorLabel = '사진을 불러올 수 없음',
    this.photoReader,
    this.onTap,
  }) : assert(size > 0 && size < double.infinity);

  final RecordPhoto photo;
  final double size;
  final bool compact;
  final String errorLabel;
  final Future<Uint8List> Function(String path)? photoReader;
  final VoidCallback? onTap;

  @override
  State<RecordPhotoThumbnail> createState() => _RecordPhotoThumbnailState();
}

class _RecordPhotoThumbnailState extends State<RecordPhotoThumbnail> {
  Future<Uint8List>? _bytes;
  int _readRevision = 0;

  String? get _path => widget.photo.localPath?.trim();
  bool get _usesBytes => kIsWeb || widget.photoReader != null;

  @override
  void initState() {
    super.initState();
    _readPhoto();
  }

  @override
  void didUpdateWidget(RecordPhotoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.localPath?.trim() != _path ||
        oldWidget.photoReader != widget.photoReader) {
      _readPhoto();
    }
  }

  void _readPhoto() {
    _readRevision++;
    final path = _path;
    _bytes = _usesBytes && path != null && path.isNotEmpty
        ? Future<Uint8List>.sync(
            () =>
                (widget.photoReader ?? RecordPhotoFileStore().readBytes)(path),
          )
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final child = _thumbnail(context);
    if (widget.onTap == null) return child;
    return Semantics(
      button: true,
      label: '사진 확대',
      child: InkWell(onTap: widget.onTap, child: child),
    );
  }

  Widget _thumbnail(BuildContext context) {
    final path = _path;
    if (path == null || path.isEmpty) {
      return _placeholder(context, error: true, label: '사진을 불러올 수 없음');
    }
    final pixelSize = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, RecordPhotoImage.maxDimension);
    if (!_usesBytes) {
      return _image(FileImage(File(path)), pixelSize);
    }
    return FutureBuilder<Uint8List>(
      // Reset snapshots on a new read so the previous photo cannot remain
      // visible while another photo/path is loading.
      key: ValueKey(_readRevision),
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return _image(MemoryImage(bytes), pixelSize);
        }
        return _placeholder(context, error: snapshot.hasError);
      },
    );
  }

  Widget _image<T extends Object>(ImageProvider<T> source, int pixelSize) =>
      Image(
        image: RecordPhotoImage(source, pixelSize: pixelSize),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) =>
            _placeholder(context, error: true),
      );

  Widget _placeholder(
    BuildContext context, {
    required bool error,
    String? label,
  }) {
    final message = label ?? (error ? widget.errorLabel : null);
    return Container(
      width: widget.size,
      height: widget.size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: EdgeInsets.all(widget.compact ? 6 : 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(error ? Icons.broken_image_outlined : Icons.image_outlined),
          if (message != null) ...[
            SizedBox(height: widget.compact ? 4 : 6),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: widget.compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }
}
