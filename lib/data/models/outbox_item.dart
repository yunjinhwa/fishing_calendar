enum OutboxOperationType {
  create,
  update,
  delete,
}

enum OutboxStatus {
  pending,
  sending,
  succeeded,
  failed,
}

class OutboxItem {
  final String id;
  final String recordId;
  final OutboxOperationType operationType;
  final OutboxStatus status;
  final DateTime createdAt;
  final DateTime? lastTriedAt;
  final String? errorMessage;

  const OutboxItem({
    required this.id,
    required this.recordId,
    required this.operationType,
    required this.status,
    required this.createdAt,
    this.lastTriedAt,
    this.errorMessage,
  });

  OutboxItem copyWith({
    OutboxStatus? status,
    DateTime? lastTriedAt,
    String? errorMessage,
  }) {
    return OutboxItem(
      id: id,
      recordId: recordId,
      operationType: operationType,
      status: status ?? this.status,
      createdAt: createdAt,
      lastTriedAt: lastTriedAt ?? this.lastTriedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  String get operationLabel {
    switch (operationType) {
      case OutboxOperationType.create:
        return '생성';
      case OutboxOperationType.update:
        return '수정';
      case OutboxOperationType.delete:
        return '삭제';
    }
  }

  String get statusLabel {
    switch (status) {
      case OutboxStatus.pending:
        return '업로드 대기';
      case OutboxStatus.sending:
        return '업로드 중';
      case OutboxStatus.succeeded:
        return '업로드 완료';
      case OutboxStatus.failed:
        return '업로드 실패';
    }
  }
}