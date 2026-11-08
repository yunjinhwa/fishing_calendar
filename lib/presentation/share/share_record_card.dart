import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/models/personal_best_record.dart';
import '../../data/models/share_record_data.dart';

/// A portrait card whose content comes only from the selected catch.
class ShareRecordCard extends StatelessWidget {
  const ShareRecordCard({
    super.key,
    required this.data,
    this.options = const ShareRecordOptions(),
  });

  final ShareRecordData data;
  final ShareRecordOptions options;

  static const double width = 360;
  static const _ink = Color(0xFF153343);
  static const _teal = Color(0xFF087F8C);
  static const _muted = Color(0xFF607584);

  /// Use this same bounded provider when precaching before exporting the card.
  static final ImageProvider<Object> backgroundProvider = ResizeImage(
    const AssetImage('assets/images/share_record_background.png'),
    width: 1080,
    height: 1080,
    policy: ResizeImagePolicy.fit,
  );

  /// Use this same provider when precaching before exporting the card.
  static ImageProvider<Object> photoProvider(Uint8List bytes) => ResizeImage(
    MemoryImage(bytes),
    width: 1080,
    height: 1080,
    policy: ResizeImagePolicy.fit,
  );

  @override
  Widget build(BuildContext context) {
    final showMeasurements = options.showLength || options.showWeight;
    final showDetails = options.showDate || options.showLocation;
    final photoBytes = data.photoBytes;

    // An exported image has a stable type scale regardless of device settings.
    return MediaQuery.withNoTextScaling(
      child: SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: Colors.white),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 500),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: Image(
                      image: backgroundProvider,
                      opacity: const AlwaysStoppedAnimation<double>(0.3),
                      fit: BoxFit.cover,
                      alignment: Alignment.bottomCenter,
                      excludeFromSemantics: true,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.expand(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.emoji_events_outlined,
                                color: _teal,
                                size: 20,
                              ),
                              const SizedBox(width: 7),
                              Text(
                                data.criterion == PersonalBestSortType.weight
                                    ? '최고 무게 기록'
                                    : '최고 크기 기록',
                                style: const TextStyle(
                                  color: _teal,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _cleanText(data.speciesName, fallback: '어종 미입력'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              height: 1.1,
                            ),
                          ),
                          if (options.showNickname) ...[
                            const SizedBox(height: 6),
                            Text(
                              _cleanText(
                                data.nickname,
                                fallback: '낚시인',
                                limit: 60,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                height: 1.3,
                              ),
                            ),
                          ],
                          if (options.showPhoto) ...[
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: ColoredBox(
                                color: const Color(0xFFF1F6F7),
                                child: SizedBox(
                                  height: 180,
                                  width: double.infinity,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Padding(
                                        padding: EdgeInsets.fromLTRB(
                                          12,
                                          9,
                                          12,
                                          6,
                                        ),
                                        child: Text(
                                          '출조 사진',
                                          style: TextStyle(
                                            color: _muted,
                                            fontSize: 11,
                                            height: 1.2,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: SizedBox(
                                          width: double.infinity,
                                          child:
                                              photoBytes == null ||
                                                  photoBytes.isEmpty
                                              ? const _PhotoPlaceholder()
                                              : Image(
                                                  image: photoProvider(
                                                    photoBytes,
                                                  ),
                                                  fit: BoxFit.contain,
                                                  filterQuality:
                                                      FilterQuality.medium,
                                                  errorBuilder:
                                                      (
                                                        context,
                                                        error,
                                                        stackTrace,
                                                      ) =>
                                                          const _PhotoPlaceholder(),
                                                ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (showMeasurements) ...[
                            const SizedBox(height: 16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (options.showLength)
                                  Expanded(
                                    child: _Measurement(
                                      label: '크기',
                                      value: _lengthText(data.lengthCm),
                                      unit: 'cm',
                                    ),
                                  ),
                                if (options.showLength && options.showWeight)
                                  const SizedBox(width: 12),
                                if (options.showWeight)
                                  Expanded(
                                    child: _Measurement(
                                      label: '무게',
                                      value: _weightText(data.weightG),
                                      unit: 'g',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (showDetails) ...[
                            const SizedBox(height: 14),
                            if (options.showDate)
                              _DetailLine(
                                icon: Icons.calendar_today_outlined,
                                text: _dateText(data.caughtAt),
                              ),
                            if (options.showDate && options.showLocation)
                              const SizedBox(height: 6),
                            if (options.showLocation)
                              _DetailLine(
                                icon: Icons.place_outlined,
                                text: _cleanText(
                                  data.location,
                                  fallback: '장소 미입력',
                                  limit: 120,
                                ),
                                maxLines: 2,
                              ),
                          ],
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Divider(height: 1, color: Color(0xFFE5EDF0)),
                            SizedBox(height: 12),
                            Text(
                              'FishingBuild',
                              style: TextStyle(
                                color: _muted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _cleanText(
    String value, {
    required String fallback,
    int limit = 80,
  }) {
    final clean = value
        .replaceAll(
          RegExp(
            r'[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return fallback;
    if (clean.runes.length <= limit) return clean;
    return '${String.fromCharCodes(clean.runes.take(limit))}…';
  }

  static String? _lengthText(double? length) =>
      length != null && length.isFinite && length > 0
      ? length.toStringAsFixed(1)
      : null;

  static String? _weightText(int? weight) =>
      weight != null && weight > 0 ? '$weight' : null;

  static String _dateText(DateTime date) =>
      '${date.year}.${date.month.toString().padLeft(2, '0')}.'
      '${date.day.toString().padLeft(2, '0')}';
}

class _Measurement extends StatelessWidget {
  const _Measurement({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String? value;
  final String unit;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFFF1F7FA),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: ShareRecordCard._muted,
              fontSize: 11,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 30,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value == null ? '미측정' : '$value $unit',
                style: TextStyle(
                  color: ShareRecordCard._ink,
                  fontSize: value == null ? 18 : 25,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.icon,
    required this.text,
    this.maxLines = 1,
  });

  final IconData icon;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 15, color: ShareRecordCard._muted),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: ShareRecordCard._muted,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ),
    ],
  );
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.photo_outlined, color: Color(0xFF9CAFB7), size: 32),
        SizedBox(height: 7),
        Text(
          '사진 없음',
          style: TextStyle(
            color: ShareRecordCard._muted,
            fontSize: 12,
            height: 1.3,
          ),
        ),
      ],
    ),
  );
}
