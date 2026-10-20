import 'outbox_item.dart';

/// The latest local intent made while cloud writes were unavailable by plan.
/// Kept separately from immutable requests which may already have a receipt.
class LocalRecordChange {
  final String recordId;
  final OutboxOperationType operationType;
  final Map<String, dynamic> payload;

  const LocalRecordChange({
    required this.recordId,
    required this.operationType,
    required this.payload,
  });
}
