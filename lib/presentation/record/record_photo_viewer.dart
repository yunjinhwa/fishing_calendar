import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/models/fishing_record.dart';
import '../../data/photos/record_photo_file_store.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/record_photo_cleanup_service.dart';
import 'record_photo_image.dart';

Future<void> openRecordPhoto(BuildContext context, RecordPhoto photo) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RecordPhotoViewer(photo: photo),
      ),
    );

/// Displays one original at a time; closing releases the larger decoded frame.
class RecordPhotoViewer extends StatefulWidget {
  const RecordPhotoViewer({super.key, required this.photo, this.photoReader});
  final RecordPhoto photo;
  final Future<Uint8List> Function(String path)? photoReader;

  @override
  State<RecordPhotoViewer> createState() => _RecordPhotoViewerState();
}

class _RecordPhotoViewerState extends State<RecordPhotoViewer> {
  static const _decodeLimit = 3072;
  final _auth = AuthSessionRepository.instance;
  final _transform = TransformationController();
  final _decodedProviders = <ImageProvider<Object>>{};
  late final String _owner;
  late final int _generation;
  RecordPhotoDraftLease? _photoLease;
  Future<Uint8List>? _bytes;
  Offset _doubleTapPosition = Offset.zero;
  bool _closing = false;

  String? get _path => widget.photo.localPath?.trim();
  bool get _canRead =>
      _auth.canManageRecords &&
      _auth.dataOwnerKey == _owner &&
      _auth.sessionGeneration == _generation;

  @override
  void initState() {
    super.initState();
    _owner = _auth.dataOwnerKey;
    _generation = _auth.sessionGeneration;
    _auth.addListener(_onAuthChanged);
    final path = _path;
    if (_canRead && path != null && path.isNotEmpty) {
      _photoLease = RecordPhotoCleanupService.instance.createDraft(
        ownerKey: _owner,
        paths: [path],
      );
      if (kIsWeb || widget.photoReader != null) {
        _bytes = Future<Uint8List>.sync(
          () => (widget.photoReader ?? RecordPhotoFileStore().readBytes)(path),
        );
      }
    }
  }

  void _onAuthChanged() {
    if (!mounted || _canRead || _closing) return;
    final route = ModalRoute.of(context);
    _closing = true;
    setState(() {
      _bytes = null;
    });
    _releasePreview();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || route == null || !route.isActive || route.isFirst) return;
      if (route.isCurrent) {
        route.navigator?.pop();
      } else {
        route.navigator?.removeRoute(route);
      }
    });
  }

  void _releasePreview() {
    for (final provider in _decodedProviders) {
      unawaited(provider.evict());
    }
    _decodedProviders.clear();
    final lease = _photoLease;
    _photoLease = null;
    if (lease != null) unawaited(lease.release());
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _releasePreview();
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        _doubleTapPosition.dx * (1 - scale),
        _doubleTapPosition.dy * (1 - scale),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('사진'),
      leading: IconButton(
        tooltip: '사진 닫기',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        IconButton(
          tooltip: '확대 초기화',
          icon: const Icon(Icons.zoom_out_map),
          onPressed: () => _transform.value = Matrix4.identity(),
        ),
      ],
    ),
    body: SafeArea(
      child: !_canRead || _closing
          ? const Center(
              child: Text(
                '계정이 변경되어 사진을 표시할 수 없습니다.',
                style: TextStyle(color: Colors.white),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final ratio = MediaQuery.devicePixelRatioOf(context);
                final pixels =
                    (math.max(constraints.maxWidth, constraints.maxHeight) *
                            ratio *
                            1.5)
                        .ceil()
                        .clamp(1, _decodeLimit);
                final path = _path;
                if (path == null || path.isEmpty) return _error();
                Widget image;
                if (kIsWeb || widget.photoReader != null) {
                  image = FutureBuilder<Uint8List>(
                    future: _bytes,
                    builder: (context, snapshot) => snapshot.hasError
                        ? _error()
                        : snapshot.hasData
                        ? _image(MemoryImage(snapshot.data!), pixels)
                        : const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                  );
                } else {
                  image = _image(FileImage(File(path)), pixels);
                }
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTapDown: (details) =>
                      _doubleTapPosition = details.localPosition,
                  onDoubleTap: _toggleZoom,
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: 1,
                    maxScale: 4,
                    child: SizedBox.expand(child: image),
                  ),
                );
              },
            ),
    ),
  );

  Widget _image<T extends Object>(ImageProvider<T> source, int pixels) {
    final provider = RecordPhotoImage(
      source,
      pixelSize: pixels,
      decodeLimit: _decodeLimit,
    );
    _decodedProviders.add(provider);
    return Image(
      image: provider,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => _error(),
    );
  }

  Widget _error() => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, color: Colors.white, size: 48),
        SizedBox(height: 16),
        Text('사진을 불러올 수 없습니다.', style: TextStyle(color: Colors.white)),
      ],
    ),
  );
}
