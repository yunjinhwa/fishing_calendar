# Firestore 기록 동기화 설정

## 적용 범위

유료 회원의 SQLite Outbox를 Firestore의 다음 경로에 반영한다.

```text
users/{firebaseUid}/records/{recordId}
users/{firebaseUid}/sync_receipts/{outboxId}
```

- `records`: 출조 기록 본문과 삭제 tombstone
- `sync_receipts`: 같은 Outbox 요청의 중복 반영을 막는 처리 영수증
- 기록과 영수증은 한 Firestore 트랜잭션에서 함께 기록된다. 보안 규칙도 두 문서의 사용자, 기록 ID, Outbox ID, 버전, 작업 종류와 서버 시각이 서로 일치해야만 쓰기를 허용한다.
- 사진의 기기 로컬 경로는 Firestore에 저장하지 않는다. 같은 기기에서는 경로를 보존하고, 실제 사진 파일 동기화는 Firebase Storage 연동 단계에서 추가한다.
- 유료 플랜은 현재 앱의 로컬 정책으로 판정한다. 결제 적용 전 서버 entitlement 또는 Firebase custom claim 검증을 추가해야 한다.

현재 여러 기기에서 같은 기록을 동시에 수정하면 Firestore에 나중에 도착한 요청이 적용된다. 자동 병합과 사용자 선택형 충돌 해결은 별도 후속 작업이다. 서버 문서 형식이 잘못된 경우에는 전체 pull을 실패 처리하고 기존 로컬 스냅샷을 유지한다.

## 기록 입력 한도

앱 저장 검증과 Firestore 규칙은 다음 한도를 공유한다.

- 기록 ID 200자, Outbox ID 300자
- 위치 200자, 낚시 장르·물때·날씨 100자, 메모 5,000자
- 조과 100개, 각 어종명 100자
- 기온·수온·조과 크기는 `NaN`이나 무한대가 아닌 유한한 숫자

## Firestore 규칙 배포

프로젝트 루트에서 로그인한 Firebase CLI로 실행한다.

```powershell
firebase deploy --only firestore:rules,firestore:indexes --project fishingbuild
```

규칙은 로그인한 사용자가 자신의 UID 하위 기록과 영수증에만 접근하도록 제한한다.

## 실제 Firebase로 실행

```powershell
flutter run --dart-define=FIREBASE_AUTH_ENABLED=true
```

디버그 빌드는 기본적으로 로컬 인증 모드이므로 `FIREBASE_AUTH_ENABLED=true`가 필요하다. 회원가입 또는 로그인 후 플랜 화면에서 유료 플랜으로 변경하면 기존 로컬 기록이 Outbox에 추가되고 실제 동기화가 시작된다.

## 에뮬레이터로 실행

Firebase 에뮬레이터를 먼저 실행한다.

```powershell
firebase emulators:start --only auth,firestore --project fishingbuild
```

규칙의 소유권, 원자 생성, 레코드/영수증 결합, tombstone 동작은 다음 명령으로 한 번에 확인할 수 있다. 단독 레코드 쓰기와 단독 영수증 쓰기가 거부되는지도 검사한다.

```powershell
firebase emulators:exec --only auth,firestore --project fishingbuild "node tool/firestore_rules_smoke.mjs"
```

Android 에뮬레이터에서는 호스트 PC를 `10.0.2.2`로 지정한다.

```powershell
flutter run `
  --dart-define=FIREBASE_AUTH_ENABLED=true `
  --dart-define=FIREBASE_AUTH_EMULATOR_HOST=10.0.2.2 `
  --dart-define=FIREBASE_AUTH_EMULATOR_PORT=9099 `
  --dart-define=FIRESTORE_EMULATOR_HOST=10.0.2.2 `
  --dart-define=FIRESTORE_EMULATOR_PORT=8080
```

실제 기기는 `10.0.2.2` 대신 같은 네트워크에 연결된 PC의 IPv4 주소를 사용한다.

## 수동 확인 항목

1. Firebase 회원으로 로그인하고 유료 플랜으로 변경한다.
2. 기록을 생성한 뒤 Firestore의 `users/{uid}/records`에 `ACTIVE` 문서가 생기는지 확인한다.
3. 기록을 수정하고 `versionNo`가 증가하는지 확인한다.
4. 기록을 삭제하고 같은 문서가 `DELETED` tombstone으로 바뀌는지 확인한다.
5. 네트워크를 끈 상태에서 기록을 생성·수정·삭제하고 Outbox에 대기 항목이 남는지 확인한다.
6. 네트워크를 다시 연결하고 대기 항목이 성공 상태로 바뀌는지 확인한다.
7. 업로드 중 앱을 종료한 뒤 다시 실행해 중복 기록 없이 재시도되는지 확인한다.
8. 다른 계정으로 로그인했을 때 이전 계정의 기록이 표시되지 않는지 확인한다.
9. 사진이 첨부된 기록을 동기화한 뒤 같은 기기에서 사진이 유지되는지 확인한다.
10. 동기화 중 다른 계정으로 전환한 뒤 두 계정의 로컬 기록과 Outbox가 섞이지 않는지 확인한다.
11. 위치 200자/201자와 메모 5,000자/5,001자 경계에서 전자는 저장되고 후자는 입력 단계에서 차단되는지 확인한다.

동기화는 앱 시작, 앱 복귀, 하단 탭 전환, 네트워크 연결 복구, 기록 변경, 동기화 화면의 수동 새로고침에서 실행된다.
