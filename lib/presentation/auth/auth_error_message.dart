import '../../data/auth/auth_gateway.dart';

String authFailureMessage(AuthFailure failure) {
  return switch (failure.code) {
    AuthFailureCode.invalidEmail => '이메일 형식을 확인해 주세요.',
    AuthFailureCode.invalidCredentials => '이메일 또는 비밀번호가 올바르지 않습니다.',
    AuthFailureCode.userNotFound => '가입된 계정을 찾을 수 없습니다.',
    AuthFailureCode.emailAlreadyInUse => '이미 가입된 이메일입니다.',
    AuthFailureCode.weakPassword => '더 안전한 비밀번호를 입력해 주세요.',
    AuthFailureCode.userDisabled => '사용이 중지된 계정입니다. 관리자에게 문의해 주세요.',
    AuthFailureCode.tooManyRequests => '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
    AuthFailureCode.networkUnavailable => '네트워크 연결을 확인한 뒤 다시 시도해 주세요.',
    AuthFailureCode.operationNotAllowed => '이메일 로그인이 아직 활성화되지 않았습니다.',
    AuthFailureCode.requiresRecentLogin => '보안을 위해 다시 로그인한 뒤 시도해 주세요.',
    AuthFailureCode.noCurrentUser ||
    AuthFailureCode.sessionExpired => '로그인 세션이 만료되었습니다. 다시 로그인해 주세요.',
    AuthFailureCode.accountConflict =>
      '기존 계정 데이터와 충돌했습니다. 다른 계정으로 시도하거나 관리자에게 문의해 주세요.',
    AuthFailureCode.nicknameAlreadyInUse => '이미 사용 중인 닉네임입니다. 다른 닉네임을 입력해 주세요.',
    AuthFailureCode.nicknameRequired => '계속하려면 사용할 닉네임을 설정해 주세요.',
    AuthFailureCode.initializationFailed ||
    AuthFailureCode.configuration ||
    AuthFailureCode.serviceUnavailable =>
      '인증 서비스를 사용할 수 없습니다. 앱 설정을 확인하거나 잠시 후 다시 시도해 주세요.',
    AuthFailureCode.invalidProfile => '회원 정보를 저장하지 못했습니다. 다시 시도해 주세요.',
    AuthFailureCode.unknown => '인증 처리 중 오류가 발생했습니다. 다시 시도해 주세요.',
  };
}
