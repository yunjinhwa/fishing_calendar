import 'user_plan.dart';

enum UserCapability { manageRecords, cloudSync, outbox }

class UserPlanPolicy {
  final UserPlan plan;
  final bool canManageRecords;
  final bool canUseOfflineRecords;
  final bool canUseCloudSync;
  final bool usesOutbox;
  final bool storesOriginalLocally;
  final int? localCacheDays;

  const UserPlanPolicy._({
    required this.plan,
    required this.canManageRecords,
    required this.canUseOfflineRecords,
    required this.canUseCloudSync,
    required this.usesOutbox,
    required this.storesOriginalLocally,
    required this.localCacheDays,
  });

  static const guest = UserPlanPolicy._(
    plan: UserPlan.guest,
    canManageRecords: false,
    canUseOfflineRecords: false,
    canUseCloudSync: false,
    usesOutbox: false,
    storesOriginalLocally: false,
    localCacheDays: null,
  );

  static const free = UserPlanPolicy._(
    plan: UserPlan.free,
    canManageRecords: true,
    canUseOfflineRecords: true,
    canUseCloudSync: false,
    usesOutbox: false,
    storesOriginalLocally: true,
    localCacheDays: null,
  );

  static const paid = UserPlanPolicy._(
    plan: UserPlan.paid,
    canManageRecords: true,
    canUseOfflineRecords: true,
    canUseCloudSync: true,
    usesOutbox: true,
    storesOriginalLocally: false,
    localCacheDays: 31,
  );

  factory UserPlanPolicy.forPlan(UserPlan plan) {
    switch (plan) {
      case UserPlan.guest:
        return guest;
      case UserPlan.free:
        return free;
      case UserPlan.paid:
        return paid;
    }
  }

  bool allows(UserCapability capability) {
    switch (capability) {
      case UserCapability.manageRecords:
        return canManageRecords;
      case UserCapability.cloudSync:
        return canUseCloudSync;
      case UserCapability.outbox:
        return usesOutbox;
    }
  }
}
