enum ConflictStatus {
  unresolved,
  resolved,
}

enum ConflictResolutionType {
  useMine,
  useTheirs,
  manualMerge,
}

class ConflictItem {
  final String id;
  final String recordTitle;
  final String location;
  final DateTime occurredAt;
  final ConflictStatus status;
  final List<ConflictField> fields;
  final ConflictResolutionType? resolutionType;

  const ConflictItem({
    required this.id,
    required this.recordTitle,
    required this.location,
    required this.occurredAt,
    required this.status,
    required this.fields,
    this.resolutionType,
  });

  ConflictItem copyWith({
    ConflictStatus? status,
    ConflictResolutionType? resolutionType,
  }) {
    return ConflictItem(
      id: id,
      recordTitle: recordTitle,
      location: location,
      occurredAt: occurredAt,
      status: status ?? this.status,
      fields: fields,
      resolutionType: resolutionType ?? this.resolutionType,
    );
  }

  String get statusLabel {
    switch (status) {
      case ConflictStatus.unresolved:
        return '해결 필요';
      case ConflictStatus.resolved:
        return '해결 완료';
    }
  }

  String get resolutionLabel {
    switch (resolutionType) {
      case ConflictResolutionType.useMine:
        return '내 변경 적용';
      case ConflictResolutionType.useTheirs:
        return '상대 변경 적용';
      case ConflictResolutionType.manualMerge:
        return '직접 병합';
      case null:
        return '-';
    }
  }
}

class ConflictField {
  final String fieldName;
  final String mineValue;
  final String theirsValue;

  const ConflictField({
    required this.fieldName,
    required this.mineValue,
    required this.theirsValue,
  });
}