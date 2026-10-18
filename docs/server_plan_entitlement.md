# 서버 플랜 entitlement 설정

## 데이터 구조

Firebase 회원의 플랜 원본은 다음 Firestore 문서이다.

```text
plan_entitlements/{firebaseUid}
```

| 필드 | 형식 | 값 | 필수 여부 |
| --- | --- | --- | --- |
| `planType` | string | `FREE`, `PAID` | 필수 |
| `status` | string | `ACTIVE`, `EXPIRED`, `SUSPENDED`, `REVOKED` | 필수 |
| `expiresAt` | timestamp 또는 null | 유료 권한 만료 시각 | 선택 |
| `source` | string | `MANUAL`, `BILLING` 등 관리용 출처 | 선택 |
| `updatedAt` | timestamp | 관리용 변경 시각 | 선택 |

문서가 없거나, 값이 잘못됐거나, 상태가 `ACTIVE`가 아니거나, `expiresAt`이 지난 계정은 무료 회원으로 처리한다. 영구 유료 계정은 `expiresAt`을 생략하거나 null로 저장한다.

플랜 문서는 서버 소유 데이터다. 로그인한 사용자는 자기 문서 하나만 읽을 수 있고 앱에서는 생성·수정·삭제할 수 없다. Firebase Console과 Admin SDK는 보안 규칙을 우회하는 관리자 권한이므로 테스트용 유료 플랜을 지정할 수 있다.

## 테스트 계정을 유료로 지정하기

1. Firebase Console의 **Authentication → Users**에서 테스트 계정의 UID를 복사한다.
2. **Firestore Database → 데이터**에서 `plan_entitlements` 컬렉션을 만든다.
3. 문서 ID를 복사한 Firebase UID와 정확히 같게 지정한다.
4. `planType`을 문자열 `PAID`, `status`를 문자열 `ACTIVE`로 저장한다.
5. 기간제 계정만 `expiresAt`을 Firestore timestamp 형식으로 추가한다.
6. 앱의 **내정보 → 플랜 정보 → 서버 플랜 새로고침**을 누르거나 앱을 다시 실행한다.

무료로 변경할 때는 `planType`을 `FREE`로 변경한다. 서버 강등이 확인되면 앱은 즉시 클라우드 기능을 막지만, 전송하지 못한 Outbox 항목은 삭제하지 않고 보존한다.

## 앱 판정과 오프라인 동작

- 로그인과 세션 복원 때 서버 플랜을 확인한다.
- 앱 복귀와 네트워크 연결 복구 때 동기화보다 먼저 플랜을 다시 확인한다.
- 서버에서 검증한 결과는 Firebase UID별로 기기에 캐시한다.
- 오프라인이면 마지막으로 검증한 캐시를 사용한다.
- 검증된 캐시가 없으면 무료 회원 권한을 적용하고 클라우드 동기화를 차단한다.
- 서버에서 유료 전환을 확인하면 기존 로컬 기록을 현재 Outbox 이전 절차에 넣는다.

## 규칙 배포

규칙을 배포하면 활성 유료 entitlement가 없는 계정은 `users/{uid}/records`와 `sync_receipts`를 읽거나 쓸 수 없다. 기존 테스트 유료 계정이 있다면 해당 문서를 먼저 만든 뒤 규칙을 배포한다.

```powershell
firebase deploy --only "firestore:rules,firestore:indexes" --project fishingbuild
```

규칙 에뮬레이터 검증은 다음 명령으로 실행한다.

```powershell
npx --yes firebase-tools@15.33.0 emulators:exec `
  --only auth,firestore `
  --project fishingbuild `
  "node tool/firestore_rules_smoke.mjs"
```

이 검증은 본인 entitlement 조회, 타인 조회와 모든 클라이언트 쓰기 차단, 무료·만료·중지 계정의 기록 접근 차단, 활성 유료 계정의 기록 동기화를 확인한다.

## 실제 결제 연동 전 제한

현재 브랜치는 서버 판정과 보안 경계를 구현한다. 결제 상품, 영수증 검증, 환불·해지 웹훅은 아직 연결하지 않는다. 실제 결제를 붙일 때 신뢰할 수 있는 백엔드가 관리자 권한으로 같은 문서를 갱신해야 한다. 서비스 계정 JSON과 관리자 인증 정보는 저장소에 커밋하지 않는다.
