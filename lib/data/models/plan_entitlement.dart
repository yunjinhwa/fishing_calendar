import 'user_plan.dart';

enum PlanEntitlementStatus {
  active,
  expired,
  suspended,
  revoked;

  static PlanEntitlementStatus? fromWireValue(String? value) {
    return switch (value?.trim().toUpperCase()) {
      'ACTIVE' => PlanEntitlementStatus.active,
      'EXPIRED' => PlanEntitlementStatus.expired,
      'SUSPENDED' => PlanEntitlementStatus.suspended,
      'REVOKED' => PlanEntitlementStatus.revoked,
      _ => null,
    };
  }

  String get wireValue => name.toUpperCase();
}

/// Server-owned account plan information.
///
/// A missing document is treated as a free entitlement. [UserPlan.guest] is
/// never represented here because guest access is an authentication state.
class PlanEntitlement {
  final UserPlan plan;
  final PlanEntitlementStatus status;
  final DateTime? expiresAt;
  final DateTime? updatedAt;
  final String? source;

  const PlanEntitlement({
    required this.plan,
    required this.status,
    this.expiresAt,
    this.updatedAt,
    this.source,
  }) : assert(plan != UserPlan.guest);

  bool isActiveAt(DateTime now) {
    final expiry = expiresAt;
    return status == PlanEntitlementStatus.active &&
        (expiry == null || expiry.isAfter(now));
  }

  UserPlan effectivePlanAt(DateTime now) {
    return plan == UserPlan.paid && isActiveAt(now)
        ? UserPlan.paid
        : UserPlan.free;
  }
}

/// Indicates where the effective plan shown by the app came from.
enum PlanEntitlementSource {
  localDevelopment,
  server,
  firestoreCache,
  deviceCache,
  defaultFree,
}

class PlanEntitlementSnapshot {
  final PlanEntitlement? entitlement;
  final bool isFromCache;

  const PlanEntitlementSnapshot({
    required this.entitlement,
    required this.isFromCache,
  });
}

class PlanEntitlementRefreshResult {
  final UserPlan previousPlan;
  final UserPlan currentPlan;
  final PlanEntitlementSource source;
  final String? errorMessage;

  const PlanEntitlementRefreshResult({
    required this.previousPlan,
    required this.currentPlan,
    required this.source,
    this.errorMessage,
  });

  bool get changed => previousPlan != currentPlan;
  bool get usedFallback =>
      source == PlanEntitlementSource.deviceCache ||
      source == PlanEntitlementSource.defaultFree;
}
