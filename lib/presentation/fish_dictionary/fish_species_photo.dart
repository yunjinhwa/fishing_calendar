import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/fish_species.dart';
import '../../data/fish/fish_photo_validation.dart';

/// Displays the complete provider photo without cropping or decorative edits.
class FishSpeciesPhoto extends StatelessWidget {
  const FishSpeciesPhoto({
    super.key,
    required this.fish,
    this.height = 220,
    this.compact = false,
    this.allowNetwork = true,
  });
  final FishSpecies fish;
  final double height;
  final bool compact;
  final bool allowNetwork;

  @override
  Widget build(BuildContext context) {
    final url = fish.imageUrl?.trim();
    final hasPhoto = hasUsableFishPhoto(fish);
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: !hasPhoto || !allowNetwork
            ? _placeholder(
                context,
                !allowNetwork && (hasPhoto || fish.detailNeedsRetry)
                    ? '오프라인에서는 사진을 불러올 수 없습니다.'
                    : fish.detailNeedsRetry
                    ? '사진을 불러오지 못했습니다.'
                    : '사진이 없습니다.',
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : 400.0;
                  final ratio = MediaQuery.devicePixelRatioOf(context);
                  final bound = compact ? 160 : 1200;
                  final decodeWidth = math.min(
                    bound,
                    math.max(1, (width * ratio).ceil()),
                  );
                  final decodeHeight = math.min(
                    bound,
                    math.max(1, (height * ratio).ceil()),
                  );
                  return Image(
                    image: ResizeImage(
                      NetworkImage(url!),
                      width: decodeWidth,
                      height: decodeHeight,
                      policy: ResizeImagePolicy.fit,
                    ),
                    fit: BoxFit.contain,
                    semanticLabel: '${fish.name} 사진',
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : _placeholder(context, '사진을 불러오는 중입니다.'),
                    errorBuilder: (context, error, stackTrace) =>
                        _placeholder(context, '사진을 불러올 수 없습니다.'),
                  );
                },
              ),
      ),
    );
  }

  Widget _placeholder(BuildContext context, String message) => Center(
    child: Padding(
      padding: EdgeInsets.all(compact ? 4 : 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.set_meal_outlined,
            size: compact ? 28 : 56,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            semanticLabel: compact ? message : null,
          ),
          if (!compact) ...[
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
          ],
        ],
      ),
    ),
  );
}
