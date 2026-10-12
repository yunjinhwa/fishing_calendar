enum OutboxOperationType { create, update, delete }

enum OutboxStatus { pending, sending, succeeded, failed, conflicted }

class OutboxItem {
  final String id;
  final String? userId;
  final String recordId;
  final OutboxOperationType operationType;
  final OutboxStatus status;
  final DateTime createdAt;
  final DateTime? lastTriedAt;
  final String? errorMessage;
  final int retryCount;
  final bool isMigration;
  final int? baseVersionNo;
  final Map<String, dynamic>? payload;

  const OutboxItem({
    required this.id,
    this.userId,
    required this.recordId,
    required this.operationType,
    required this.status,
    required this.createdAt,
    this.lastTriedAt,
    this.errorMessage,
    this.retryCount = 0,
    this.isMigration = false,
    this.baseVersionNo,
    this.payload,
  }) : assert(baseVersionNo == null || baseVersionNo >= 0);

  factory OutboxItem.fromJson(Map<String, dynamic> json) {
    return OutboxItem(
      id: json['id'] as String,
      userId: json['userId'] as String?,
      recordId: json['recordId'] as String,
      operationType: OutboxOperationType.values.byName(
        json['operationType'] as String,
      ),
      status: OutboxStatus.values.byName(json['status'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastTriedAt: json['lastTriedAt'] == null
          ? null
          : DateTime.parse(json['lastTriedAt'] as String),
      errorMessage: json['errorMessage'] as String?,
      retryCount: json['retryCount'] as int? ?? 0,
      isMigration: json['isMigration'] as bool? ?? false,
      baseVersionNo: (json['baseVersionNo'] as num?)?.toInt(),
      payload: json['payload'] == null
          ? null
          : Map<String, dynamic>.from(json['payload'] as Map),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'recordId': recordId,
      'operationType': operationType.name,
      'status': status.name,
      'createdAt': createdAt.toIso8601String(),
      'lastTriedAt': lastTriedAt?.toIso8601String(),
      'errorMessage': errorMessage,
      'retryCount': retryCount,
      'isMigration': isMigration,
      'baseVersionNo': baseVersionNo,
      'payload': payload,
    };
  }

  OutboxItem copyWith({
    OutboxStatus? status,
    DateTime? lastTriedAt,
    String? errorMessage,
    int? retryCount,
    int? baseVersionNo,
    bool clearBaseVersionNo = false,
    Map<String, dynamic>? payload,
    bool clearErrorMessage = false,
  }) {
    return OutboxItem(
      id: id,
      userId: userId,
      recordId: recordId,
      operationType: operationType,
      status: status ?? this.status,
      createdAt: createdAt,
      lastTriedAt: lastTriedAt ?? this.lastTriedAt,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      retryCount: retryCount ?? this.retryCount,
      isMigration: isMigration,
      baseVersionNo: clearBaseVersionNo
          ? null
          : baseVersionNo ?? this.baseVersionNo,
      payload: payload ?? this.payload,
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
      case OutboxStatus.conflicted:
        return '충돌 해결 필요';
    }
  }
}
