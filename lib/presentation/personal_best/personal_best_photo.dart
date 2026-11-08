import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/models/fishing_record.dart';
import '../../data/photos/record_photo_file_store.dart';

/// Uses the same device-local photo source as the fishing record screens.
class PersonalBestPhoto extends StatefulWidget {
  const PersonalBestPhoto({
    super.key,
    required this.photo,
    required this.width,
    required this.height,
  });

  final RecordPhoto? photo;
  final double width;
  final double height;

  @override
  State<PersonalBestPhoto> createState() => _PersonalBestPhotoState();
}

class _PersonalBestPhotoState extends State<PersonalBestPhoto> {
  Future<Uint8List>? _bytes;

  String? get _localPath => widget.photo?.localPath?.trim();

  @override
  void initState() {
    super.initState();
    _loadWebPhoto();
  }

  @override
  void didUpdateWidget(PersonalBestPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo?.localPath != widget.photo?.localPath) _loadWebPhoto();
  }

  void _loadWebPhoto() {
    final path = _localPath;
    _bytes = kIsWeb && path != null && path.isNotEmpty
        ? RecordPhotoFileStore().readBytes(path)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final path = _localPath;
    if (path == null || path.isEmpty) {
      return _placeholder(
        context,
        widget.photo == null
            ? Icons.emoji_events_outlined
            : Icons.image_not_supported_outlined,
      );
    }
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = widget.width.isFinite
        ? (widget.width * ratio).ceil().clamp(1, 1200)
        : 1200;
    final decodeHeight = (widget.height * ratio).ceil().clamp(1, 1200);
    if (!kIsWeb) {
      return Image(
        image: ResizeImage(
          FileImage(File(path)),
          width: decodeWidth,
          height: decodeHeight,
          policy: ResizeImagePolicy.fit,
        ),
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _placeholder(context, Icons.broken_image_outlined),
      );
    }
    return FutureBuilder<Uint8List>(
      key: ValueKey(path),
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image(
            image: ResizeImage(
              MemoryImage(bytes),
              width: decodeWidth,
              height: decodeHeight,
              policy: ResizeImagePolicy.fit,
            ),
            width: widget.width,
            height: widget.height,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _placeholder(context, Icons.broken_image_outlined),
          );
        }
        return _placeholder(
          context,
          snapshot.hasError
              ? Icons.broken_image_outlined
              : Icons.image_outlined,
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: widget.width,
      height: widget.height,
      color: colors.primaryContainer,
      alignment: Alignment.center,
      child: Icon(icon, color: colors.onPrimaryContainer),
    );
  }
}
