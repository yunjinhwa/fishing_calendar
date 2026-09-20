enum UserPlan {
  guest,
  free,
  paid;

  String get storageValue {
    switch (this) {
      case UserPlan.guest:
        return 'guest';
      case UserPlan.free:
        return 'free';
      case UserPlan.paid:
        return 'paid';
    }
  }

  String get label {
    switch (this) {
      case UserPlan.guest:
        return '비회원';
      case UserPlan.free:
        return '무료 회원';
      case UserPlan.paid:
        return '유료 회원';
    }
  }

  static UserPlan fromStorageValue(String? value) {
    switch (value) {
      case 'free':
        return UserPlan.free;
      case 'paid':
        return UserPlan.paid;
      case 'guest':
      default:
        return UserPlan.guest;
    }
  }
}
