# 서버 플랜 entitlement 설정

## 출시 초기 동기화 개방

출시 시 모든 로그인 회원에게 기록 동기화와 서버 이력 조회를 제공한다. `app_settings/record_access`의 **불리언** `allMembersSyncEnabled`가 `true`이면 앱과 Firestore가 회원별 플랜 문서 없이 동기화 권한을 부여한다. 계정은 자신의 기록과 처리 영수증만 사용할 수 있고, 비회원과 탈퇴 중인 계정의 정상 동기화는 차단된다.

1. Firebase CLI로 수정된 Firestore 규칙을 먼저 배포한다.

   ```powershell
   & "$env:APPDATA\npm\firebase.cmd" deploy --only 'firestore:rules' --project fishingbuild
   ```

2. Firebase Console의 **Firestore Database → 데이터**에서 `app_settings` 컬렉션에 ID가 `record_access`인 문서를 만든다.
3. `allMembersSyncEnabled` 필드의 유형을 **boolean**, 값을 `true`로 저장한다. 이 설정은 관리자만 변경할 수 있다.
4. 플랜 문서가 없는 테스트 계정으로 앱을 실행해 기록 저장, 오프라인 후 재연결, 동일 계정의 다른 기기에서 기록 조회를 확인한다.

설정을 `false`로 내리면 서버는 기존 계정별 entitlement를 적용한다. 설정 문서가 없거나 값의 유형이 잘못된 경우에도 같은 방식으로 판정한다. 앱은 다음 서버 권한 확인 때 변경사항을 반영한다. 오프라인에서는 기기에서 마지막으로 확인한 계정별 상태를 사용한다. 서버 기록과 기기에 내려받은 기록은 기존 플랜 전환 정책에 따라 보존한다.

## 데이터 구조

출시 초기 개방을 종료한 뒤에는 다음 Firestore 문서가 계정별 플랜 원본이다.

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

플랜 문서는 서버 소유 데이터다. 로그인한 사용자는 자기 문서 하나만 읽을 수 있다. Firebase Console과 Admin SDK에서 플랜 문서를 만들거나 변경한다. 계정 탈퇴 중에는 앱이 자기 문서를 삭제할 수 있다.

## 테스트 계정을 유료로 지정하기

1. Firebase Console의 **Authentication → Users**에서 테스트 계정의 UID를 복사한다.
2. **Firestore Database → 데이터**에서 `plan_entitlements` 컬렉션을 만든다.
3. 문서 ID를 복사한 Firebase UID와 정확히 같게 지정한다.
4. `planType`을 문자열 `PAID`, `status`를 문자열 `ACTIVE`로 저장한다.
5. 기간제 계정만 `expiresAt`을 Firestore timestamp 형식으로 추가한다.
6. 앱을 다시 실행하거나 백그라운드에서 돌아와 서버 권한을 다시 확인한다.

무료로 변경할 때는 `planType`을 `FREE`로 변경한다. 서버 강등이 확인되면 앱은 즉시 클라우드 기능을 막지만, 전송하지 못한 Outbox 항목은 삭제하지 않고 보존한다.

## 앱 판정과 오프라인 동작

- 로그인과 세션 복원 때 서버 플랜을 확인한다.
- 앱 복귀와 네트워크 연결 복구 때 동기화보다 먼저 플랜을 다시 확인한다.
- 서버에서 검증한 결과는 Firebase UID별로 기기에 캐시한다.
- 오프라인이면 마지막으로 검증한 캐시를 사용한다.
- 검증된 캐시가 없으면 무료 회원 권한을 적용하고 클라우드 동기화를 차단한다.
- 서버에서 유료 전환을 확인하면 기존 로컬 기록을 현재 Outbox 이전 절차에 넣는다.

## 규칙 배포

`allMembersSyncEnabled`가 꺼져 있으면 정상 동기화에 활성 유료 entitlement가 필요하다. 개방 설정과 계정별 entitlement 모두 사용자 UID 소유권, 탈퇴 처리, 기록·영수증 쓰기 검증을 적용한다.

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

이 검증은 출시 설정의 클라이언트 쓰기 제한, 본인 기록 동기화, 비회원·타인·탈퇴 중 계정의 접근 제한, 개방 종료 후 계정별 판정을 확인한다.

## 실제 결제 연동 전 제한

결제 상품을 도입할 때는 신뢰할 수 있는 백엔드가 구매·환불·해지를 검증한 뒤 관리자 권한으로 계정별 플랜 문서를 갱신해야 한다. 서비스 계정 JSON과 관리자 인증 정보는 저장소 밖에서 관리한다.
