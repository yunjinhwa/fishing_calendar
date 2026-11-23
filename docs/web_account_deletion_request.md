# 웹 계정 삭제 요청

Firebase Hosting의 `/account-deletion/`에서 낚시 캘린더 계정과 서버 데이터의 삭제를 요청한다. 기존 이메일과 비밀번호로 본인 확인하며, 비밀번호를 잊은 사용자는 같은 화면에서 재설정 메일을 요청할 수 있다. 계정 삭제 요청은 운영자가 확인한 뒤 처리한다. [Google Play 계정 삭제 링크 요건](https://support.google.com/googleplay/android-developer/answer/13327111)

## 접수 방식

- Firebase Authentication으로 로그인하고 검증된 UID 아래 `web_account_deletion_requests/{uid}` 문서를 생성한다. 문서에는 버전, `REQUESTED` 상태, 서버 요청 시각을 기록한다.
- 재제출 시 기존 요청을 확인한다. 브라우저는 인증 토큰을 요청 중에만 사용하며 접수 문서에는 이메일·비밀번호·토큰을 저장하지 않는다.
- 보안 규칙은 본인 문서 조회와 최근 인증한 계정의 요청 생성만 허용한다. 접수 컬렉션 열람과 요청 변경은 관리자가 수행한다.
- 실제 삭제가 시작되는 시점은 운영자가 기존 `account_deletion_requests/{uid}` 표식을 생성할 때다. 이 표식을 기기에서 감지하면 서버 쓰기와 동기화를 막고 해당 계정의 앱 내부 기기 데이터를 정리한다. [앱 탈퇴 처리](account_deletion.md)

## 운영자 처리 절차

1. Firestore의 `web_account_deletion_requests`를 주기적으로 확인한다. 요청 문서 ID와 Authentication의 UID를 대조하고, `user_profiles/{uid}`에서 닉네임 키를 확인한다.
2. `account_deletion_requests/{uid}`에 `uid` 문자열, `schemaVersion` 숫자 `1`, `status` 문자열 `REQUESTED`, `requestedAt` Timestamp를 기록한다. 웹 요청의 서버 접수 시각을 사용한다. 기존 표식이 있으면 그 상태에서 이어서 처리한다.
3. 같은 UID의 `users/{uid}/records`, `users/{uid}/sync_receipts`에 남은 문서와 `plan_entitlements/{uid}`를 정리한다. 빈 상위 문서만 삭제하면 하위 컬렉션이 남을 수 있으므로, Firebase Console에서 하위 문서가 비었는지 함께 확인한다. [Firestore 데이터 삭제 안내](https://firebase.google.com/docs/firestore/manage-data/delete-data)
4. 해당 UID의 `user_profiles` 문서와 동일한 UID에 속한 `nickname_claims` 문서를 정리한다. 데이터 정리를 확인한 뒤 동일한 UID의 Firebase Authentication 계정을 삭제한다.
5. 관련 데이터와 계정 삭제를 확인한 뒤 웹 접수 문서를 정리한다. 일부 단계가 실패하면 접수 문서를 보존하고 같은 UID에서 이어서 처리한다. 기존 탈퇴 표식은 오래된 인증 세션의 데이터 재생성을 막기 위해 남아 있다.

사용자가 기기 갤러리에 저장하거나 다른 앱으로 공유한 사본은 해당 위치에서 관리한다. 운영자는 요청 확인·처리 주기와 개인정보 처리방침의 보존 정책을 공개 전에 확정한다.

## 배포

기존 비밀번호 재설정과 같은 Firebase Hosting 사이트를 쓴다. 프로젝트 루트에서 공개 설정과 정적 파일을 준비하고, 규칙을 먼저 배포한다.

```powershell
node tool/prepare_password_reset_web.mjs
& "$env:APPDATA\npm\firebase.cmd" deploy --only 'firestore:rules' --project fishingbuild
& "$env:APPDATA\npm\firebase.cmd" deploy --config firebase.auth.json --only hosting --project fishingbuild
```

예정 URL은 `https://fishingbuild-password-reset.web.app/account-deletion/`이다. 배포 후 별도 테스트 계정으로 접수와 중복 제출, 운영자 처리까지 확인한 뒤 Play Console의 **데이터 보안 → 계정 삭제 URL**에 등록한다. 루트의 비밀번호 재설정 링크도 함께 점검한다.

## 로컬 검증

```powershell
node --test tool/account_deletion_web_test.mjs tool/password_reset_web_test.mjs
& "$env:APPDATA\npm\firebase.cmd" emulators:exec --only 'auth,firestore' `
  --project demo-fishing-web-delete 'node tool/account_deletion_web_emulator_smoke.mjs'
```

로컬 검증은 테스트 계정으로 본인 확인, 접수, 중복 제출, 비밀번호 재설정 메일 요청을 확인한다. `tool/firestore_rules_smoke.mjs`는 본인과 다른 UID의 접근 제한을 별도로 검사한다.
