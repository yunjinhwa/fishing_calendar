# Firebase Authentication / Firestore 설정

이 브랜치는 이메일/비밀번호 Firebase Authentication, Firestore 기반 고유 닉네임 예약, Firebase UID 기반 로컬 데이터 소유권, 기존 이메일 기반 로컬 데이터 이전까지 구현한다. Firebase 프로젝트 값이 없는 디버그 환경에서는 `FIREBASE_AUTH_ENABLED`의 기본값이 `false`이므로 기존 로컬 인증 방식으로 실행된다. 릴리스 빌드는 Firebase 인증이 기본 활성화되어 설정 누락 시 로컬 비밀번호 방식으로 실행되지 않는다.

Firebase Authentication 플러그인 구현이 없는 Linux 데스크톱은 이 연동의 지원 대상이 아니다. Android, iOS, macOS, Windows, Web을 대상으로 설정한다.

## 1. 앱 식별자 확정

현재 Firebase에 등록된 Android application ID는 `com.jinhwan.fishing_build`이고 Apple 플랫폼 식별자는 `com.jinhwan.fishingBuild`이다. 배포 전에 이 식별자를 최종 확인한다.

Firebase Flutter 플러그인의 현재 iOS 최소 버전에 맞춰 이 프로젝트의 iOS 배포 대상은 15.0으로 설정되어 있다.
macOS 대상에는 Firebase 통신과 인증 세션 보관에 필요한 outbound network 및 Keychain Sharing entitlement가 포함되어 있다.

## 2. Firebase 프로젝트 연결

Firebase CLI와 FlutterFire CLI를 설치하고 로그인한다.

```powershell
npm install -g firebase-tools
firebase login
dart pub global activate flutterfire_cli
```

프로젝트 루트에서 사용할 Firebase 프로젝트와 플랫폼을 선택한다. 현재 저장소는 `fishingbuild` 프로젝트 설정으로 생성되어 있다.

```powershell
flutterfire configure
```

이 명령이 `lib/firebase_options.dart`와 각 플랫폼 설정을 갱신한다. Firebase 구성 식별자는 비밀 키가 아니므로 팀의 배포 정책에 따라 파일을 버전 관리할 수 있다.

Firebase Console의 **Authentication → Sign-in method**에서 **Email/Password** 제공자를 활성화한다. Google/Apple 로그인 버튼은 이번 작업 범위에 포함되지 않아 화면에서 비활성화되어 있다.

Firebase Console의 **Firestore Database**에서 데이터베이스도 생성한다. 데이터베이스 위치는 실제 사용자와 서버가 위치할 지역을 기준으로 선택하며, 한 번 정하면 변경할 수 없으므로 배포 지역을 먼저 확인한다. 생성 후 저장소의 닉네임 전용 보안 규칙과 인덱스 설정을 배포한다.

```powershell
firebase deploy --only "firestore:rules,firestore:indexes" --project fishingbuild
```

이 배포 전에는 Firebase 로그인 자체는 성공해도 닉네임 예약 단계에서 권한 또는 설정 오류가 표시될 수 있다.

## 3. Firebase 인증 활성화

Firebase 프로젝트 연결 후 다음과 같이 실행한다.

```powershell
flutter run --dart-define=FIREBASE_AUTH_ENABLED=true
```

설정이 누락되거나 Firebase 초기화가 실패하면 로컬 비밀번호 인증으로 자동 우회하지 않는다. 앱은 비회원 상태로 시작하고 로그인/회원가입 시 설정 오류를 표시한다.

FlutterFire CLI가 만든 파일을 사용하지 않고 실행별 설정을 주입하려면 다음 키를 JSON 파일에 넣을 수 있다.

```json
{
  "FIREBASE_AUTH_ENABLED": true,
  "FIREBASE_API_KEY": "...",
  "FIREBASE_APP_ID": "...",
  "FIREBASE_MESSAGING_SENDER_ID": "...",
  "FIREBASE_PROJECT_ID": "...",
  "FIREBASE_AUTH_DOMAIN": "...",
  "FIREBASE_STORAGE_BUCKET": "...",
  "FIREBASE_IOS_BUNDLE_ID": "..."
}
```

```powershell
flutter run --dart-define-from-file=firebase.local.json
```

`firebase.local.json`은 `.gitignore`에 포함되어 있다.

## 4. Auth / Firestore Emulator 사용

Firebase Auth Emulator와 Firestore Emulator를 함께 실행한 뒤 두 호스트를 전달한다. 고유 닉네임 검증은 두 에뮬레이터가 모두 필요하다.

```powershell
firebase emulators:start --only auth,firestore
flutter run `
  --dart-define=FIREBASE_AUTH_ENABLED=true `
  --dart-define=FIREBASE_AUTH_EMULATOR_HOST=localhost `
  --dart-define=FIREBASE_AUTH_EMULATOR_PORT=9099 `
  --dart-define=FIRESTORE_EMULATOR_HOST=localhost `
  --dart-define=FIRESTORE_EMULATOR_PORT=8080
```

Android Emulator에서 PC의 localhost에 접근할 때는 두 호스트 모두 `localhost` 대신 `10.0.2.2`를 사용한다.

Windows에서 Flutter 플러그인 심볼릭 링크 오류가 발생하면 **설정 → 시스템 → 개발자용 → 개발자 모드**를 켠 뒤 `flutter pub get`을 다시 실행한다.

## 5. 닉네임 고유성

- 닉네임은 2~20자의 한글, 영문, 숫자, 일반 공백, 밑줄(`_`), 하이픈(`-`)만 허용한다.
- 앞뒤 공백과 영문 대소문자를 무시해 중복을 판정한다. 예를 들어 `Fisher`와 ` fisher `는 같은 닉네임이다.
- `nickname_claims/{정규화된 닉네임}`와 `user_profiles/{Firebase UID}`를 하나의 Firestore 트랜잭션에서 함께 기록한다.
- 동시에 같은 닉네임으로 가입해도 한 계정만 예약에 성공한다.
- 신규 가입 중 닉네임 충돌이 발생하면 방금 만든 Firebase Auth 계정을 삭제해 이메일만 남는 계정을 방지한다.
- 기존 Firebase 계정에 닉네임 예약 정보가 없고 현재 닉네임이 충돌하면 로그인 화면에서 새 닉네임을 입력한 후 다시 진행한다.
- 이미 정상 예약을 마친 로그인 세션은 오프라인 앱 재시작 시 기기의 검증된 닉네임 캐시로 복원한다. 새 로그인과 가입은 Firestore 확인이 필요하다.
- Firebase가 꺼진 로컬 개발 모드에서는 같은 기기에 저장된 계정 사이의 중복만 막을 수 있다.

## 6. 데이터 이전 동작

- 기존 로컬 회원 키: `member:<정규화된 이메일>`
- Firebase 회원 키: `member:uid:<Firebase UID>`
- 기존 로컬 계정은 저장된 비밀번호가 일치할 때 Firebase 계정을 생성하고 기록, 사진/어획 자식 데이터, Outbox, 플랜, 이전 상태, 닉네임을 UID로 이전한다.
- 이미 존재하는 Firebase 계정도 같은 이메일만으로는 기기의 예전 데이터를 가져갈 수 없으며, 입력한 비밀번호가 로컬 계정 비밀번호와도 일치해야 한다.
- 비밀번호 해시는 이전 성공 후 기기에서 제거한다.
- 비밀번호가 없던 구버전 활성 세션은 해당 기기에서 비밀번호를 먼저 설정할 수 있는 제한된 전환 상태로 한 번 복원되며, 이후 다시 로그인할 때 Firebase로 이전된다.
- 동일 ID 데이터 충돌이나 이미 다른 UID가 가져간 이메일 데이터가 감지되면 이전 전체를 롤백하고 로그인을 중단한다.
- Firebase 네이티브 세션은 유지되므로 “로그인 상태 유지”를 끄면 다음 앱 시작 시 즉시 Firebase 로그아웃을 수행한다.

## 7. 검증

Firebase 프로젝트 없이 저장소 테스트를 실행할 수 있다.

```powershell
flutter analyze
flutter test
flutter build apk --debug --dart-define=FIREBASE_AUTH_ENABLED=true
```

실제 Firebase 프로젝트를 연결한 뒤에는 신규 가입, 앱 재실행 후 세션 복원, 로그아웃, 잘못된 비밀번호, 중복 이메일, 중복 닉네임, 네트워크 단절, 기존 로컬 계정의 최초 로그인과 기록 이전을 기기에서 확인한다. 서로 다른 두 계정에서 같은 닉네임을 거의 동시에 제출하는 경우도 확인한다.
