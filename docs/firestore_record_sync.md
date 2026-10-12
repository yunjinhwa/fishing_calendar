# Firestore 기록 동기화 설정

## 적용 범위

유료 회원의 SQLite Outbox를 Firestore의 다음 경로에 반영한다.

```text
users/{firebaseUid}/records/{recordId}
users/{firebaseUid}/sync_receipts/{outboxId}
```

- `records`: 출조 기록 본문과 삭제 tombstone
- `sync_receipts`: 기준 버전과 결과 버전, 변경 지문을 보관해 같은 Outbox 요청의 중복 반영을 막는 처리 영수증
- 기록과 영수증은 한 Firestore 트랜잭션에서 함께 기록된다. 보안 규칙도 두 문서의 사용자, 기록 ID, Outbox ID, 버전, 작업 종류와 서버 시각이 서로 일치해야만 쓰기를 허용한다.
- 사진 원본과 기기 로컬 경로는 Firestore에 저장하지 않는다. 사진은 앱 전용 로컬 저장소에만 보관하며, 같은 기록을 서버에서 다시 내려받아도 현재 기기의 사진을 보존한다.
- 다른 기기에서는 기록 본문만 내려받고 사진은 표시하지 않는다. Firebase Storage는 사용하지 않는다.
- 유료 플랜은 현재 앱의 로컬 정책으로 판정한다. 결제 적용 전 서버 entitlement 또는 Firebase custom claim 검증을 추가해야 한다.

각 Outbox 요청은 변경을 시작한 서버 버전인 `baseVersionNo`를 고정해서 보관한다. 서버의 현재 버전과 기준 버전이 다르면 요청을 쓰지 않고 충돌로 전환한다. 새 기록은 기준 버전 0에서 시작하며, 같은 기기에서 오프라인으로 생성·수정·삭제하면 기준 버전이 0, 1, 2로 이어진다.

충돌 내용과 양쪽 스냅샷은 SQLite에 저장되므로 앱을 다시 실행해도 유지된다. 사용자는 내 변경을 최신 서버 버전 위에 다시 적용하거나, 서버의 최신 변경을 이 기기에 적용하거나, 항목별로 값을 선택해 병합할 수 있다. 해결 요청을 보내는 동안 서버가 다시 변경되면 새로운 충돌로 표시한다. 서버 값을 적용하거나 직접 병합할 때 사진은 현재 기기의 파일을 유지한다.

서버 문서 형식이 잘못된 경우에는 전체 pull을 실패 처리하고 기존 로컬 스냅샷을 유지한다.

## 기록 입력 한도

앱 저장 검증과 Firestore 규칙은 다음 한도를 공유한다.

- 기록 ID 200자, Outbox ID 300자
- 위치 200자, 낚시 장르·물때·날씨 100자, 메모 5,000자
- 조과 100개, 각 어종명 100자
- 로컬 사진 10장, 파일당 10 MiB, JPEG/PNG/WebP
- 기온·수온·조과 크기는 `NaN`이나 무한대가 아닌 유한한 숫자

## Firestore 규칙 배포

프로젝트 루트에서 로그인한 Firebase CLI로 실행한다.

```powershell
firebase deploy --only firestore:rules,firestore:indexes --project fishingbuild
```

충돌 감지 앱보다 이 규칙을 먼저 배포해야 한다. 새 앱은 v2 영수증을 쓰며, 규칙은 작업 종류, `baseVersionNo`, `resultingVersionNo`, 변경 지문과 레코드 버전이 모두 일치할 때만 원자 쓰기를 허용한다. 배포 전환 중인 기존 앱을 위해 v1 영수증도 현재 레코드 버전과 결과 버전이 정확히 이어질 때만 임시로 허용한다. 모든 사용자가 새 앱으로 전환된 뒤 v1 신규 쓰기 허용을 제거할 수 있다. 규칙은 로그인한 사용자가 자신의 UID 하위 기록과 영수증에만 접근하도록 제한한다.

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

규칙의 소유권, 원자 생성·수정·삭제, 기준 버전, 작업 종류, 레코드/영수증 결합과 tombstone 동작은 다음 명령으로 한 번에 확인할 수 있다. 오래된 기준 버전과 단독 레코드/영수증 쓰기가 거부되는지도 검사한다.

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
9. 사진이 첨부된 기록을 동기화한 뒤 같은 기기에서 사진이 유지되고 Firestore 문서에 로컬 경로나 이미지 데이터가 없는지 확인한다.
10. 다른 기기에서 같은 계정으로 로그인했을 때 기록 본문은 내려오고 사진은 표시되지 않는지 확인한다.
11. 동기화 중 다른 계정으로 전환한 뒤 두 계정의 로컬 기록과 Outbox가 섞이지 않는지 확인한다.
12. 위치 200자/201자와 메모 5,000자/5,001자 경계에서 전자는 저장되고 후자는 입력 단계에서 차단되는지 확인한다.
13. 두 기기에서 같은 서버 버전의 기록을 각각 수정하고 한쪽을 먼저 동기화한 뒤, 다른 쪽이 `충돌 해결 필요`로 표시되는지 확인한다.
14. 충돌에서 서버 변경 적용을 선택하면 서버의 최신 값이 반영되고 현재 기기의 사진이 유지되는지 확인한다.
15. 충돌에서 내 변경 적용을 선택하면 새 서버 버전으로 반영되고 충돌이 완료되는지 확인한다.
16. 활성 기록끼리 충돌했을 때 직접 병합에서 항목별 값을 선택할 수 있는지 확인한다.
17. 기록 수정과 삭제가 충돌했을 때 양쪽 상태가 정확히 표시되고 선택한 결과대로 기록이 복원되거나 삭제되는지 확인한다.

동기화는 앱 시작, 앱 복귀, 하단 탭 전환, 네트워크 연결 복구, 기록 변경, 동기화 화면의 수동 새로고침에서 실행된다.
