# MVP 통합 점검 — 2026-11-09

- 브랜치: `chore/mvp-integration-check`
- 기준 커밋: `d0c2e38`
- 범위: 주요 화면 연결, 계정·요금제·오프라인 데이터 경계, 기존 자동 테스트와 로컬 Firebase 규칙 검사, 현재 정책과 문서 정합성.
- 운영 Firebase 데이터·설정·배포와 실제 기기 조작은 이번 점검에서 변경하지 않았다.

## 이번 점검의 변경

### 계정 전환 시 동기화 시각 표시 수정

A 계정이 동기화에 성공한 뒤 B 계정으로 전환해 동기화가 오프라인·무료 권한으로 건너뛰어지면, 서비스가 상태 소유자만 B로 바꾸고 마지막 성공 시각을 지우지 않았다. B 계정에 A의 동기화 완료 시각이 표시될 수 있었다. A의 진행 중 작업이 계정 변경으로 취소되는 경로에서도 같은 문제가 발생했다.

`RecordSyncService`에서 상태 소유자가 바뀔 때 결과·성공 시각·오류를 함께 초기화하도록 수정했다. 세션 변경으로 취소된 이전 작업의 결과는 새 계정에 귀속시키지 않는다. 같은 계정에서 오프라인으로 건너뛴 경우는 본인의 이전 성공 시각을 유지한다. 기록 본문과 Outbox의 저장·전송 규칙은 변경하지 않았다.

수정 전 새 회귀 테스트에서 2건이 실패해 실제 시각 노출을 재현했다. 수정 후 계정 전환·취소·기존 동기화·요금제 이전·유료 캐시 관련 51개 테스트를 통과했다. 추가로 새 계정의 서버 조회 실패에서도 이전 성공 시각이 남지 않는 경우를 검증한다.

### 화면 사이 데이터 연결 검증 추가

`test/mvp_record_flow_test.dart`에서 지도 선택 → 기록 작성 → 실제 SQLite 저장·캐시 비우기·재조회 → 캘린더 → 날짜별 목록·상세 → 기본 기록어 집계 → 공유 미리보기를 연결했다. 같은 어종의 두 개체를 각각 `60cm·400g`, `40cm·1200g`으로 저장하고, 크기 기준과 무게 기준의 공유가 해당 조과의 수치·인덱스를 정확히 유지하는지 확인한다. 공유의 날짜·장소 기본 비공개도 확인한다.

지도·날씨·GPS의 네트워크 및 플랫폼 입출력은 대역을 사용한다. 실제 지도 SDK 렌더링, 운영 API 응답, 갤러리 PNG 저장과 OS 공유 화면까지 자동으로 검증했다는 뜻은 아니다. 민물 위치에서의 기록 작성은 현재의 필수 입력 계약을 사용하므로 아래 입력 정책 문제를 해결한 테스트로 해석하지 않는다.

### 날짜에 따라 바뀌던 기존 테스트 안정화

`test/tide_record_reference_test.dart`의 수동 입력값이 당일 자동 물때와 같아지면 실제 편집이 발생하지 않는 경우가 있었다. 항상 다른 수동 입력값을 사용하도록 테스트 자료만 바꿨다. 물때 계산이나 앱의 수동 입력 보존 동작은 변경하지 않았다.

## 현재 정책

| 항목 | 이번 점검에서 적용한 기준 |
|---|---|
| 조과 | 항목 하나가 한 마리. 같은 어종도 개체별 크기·무게를 입력하며 수량 기능은 제외 |
| 기록어 | 크기·무게 최대값을 독립 집계하고 공유에는 선택한 실제 조과의 수치를 사용 |
| 사진 | 기기 로컬 보관. 기기 간 사진 동기화·Firebase Storage 사용은 범위에서 제외 |
| 요금제 | Firebase에서는 서버 entitlement 확인. 클라이언트 직접 무료/유료 전환은 로컬 개발 환경에서만 제공 |
| 캐시 | 유료의 평상시 본문은 최근 31일, 과거 기록은 필요 시 조회. 무료 전환 시 내려받은 기록과 서버 과거 원본 보존 |
| 무료 기간 변경 | 무료 상태에서 서버에 쓰지 않음. 재승급 시 최신 수정·삭제를 불변 기존 요청 뒤 후속 요청으로 반영 |
| 충돌 | 내 변경·서버 변경·필드별 병합을 사용. 자동 LWW 덮어쓰기는 필수 수정으로 추가하지 않음 |
| 지도 해양 정보 | 바다·해안에서만 물때·수온·만조·간조 제공. 없는 값은 `제공되지 않음`, 카드의 출처·내부 메타데이터는 숨김 |
| 도감 | 실제 어종 사진만 사용. 자료 누락을 인정하며 추가 수집·보강 작업은 이번 범위에서 제외 |
| 원래 명세와의 차이 | Firebase SDK·Firestore와 SQLite를 사용. 원래 REST/서버 관계형 테이블 수나 `weight_kg` 필드를 맞추기 위한 확장은 하지 않으며 현재 조과 무게 단위는 g |

원본 DOCX/PDF는 변경하지 않았다. 과거 감사 문서는 당시 기록으로 보존하고 최신 보고서로 연결했다. 체크리스트의 미체크 항목은 기능 미구현이나 자동 테스트 실패를 뜻하지 않으며 사용자가 이번 통합 시나리오에서 확인할 항목이다.

## 자동 검증과 적용 범위

| 시나리오 | 주요 근거 |
|---|---|
| 지도부터 기록어·공유까지 동일 조과 연결 | `mvp_record_flow_test.dart`, `personal_best_repository_test.dart`, `share_record_page_test.dart` |
| 계정별 동기화 상태와 기록 격리 | `mvp_sync_status_test.dart`, `record_sync_test.dart`, `firebase_auth_test.dart` |
| 오프라인 요청 영속화·중간 종료·재시도 | `local_database_test.dart`, `record_save_transaction_test.dart`, `record_sync_test.dart` |
| 무료 기간 변경·삭제와 재승급·응답 유실 | `plan_migration_integrity_test.dart`, `plan_policy_test.dart` |
| 최근 캐시·과거 조회·계정 변경 중 응답 보호 | `paid_cache_sync_test.dart`, `paid_record_cache_service_test.dart`, `paid_cache_identity_migration_test.dart` |
| 열린 상세·수정 화면의 원격 변경/삭제와 충돌 | `record_edit_version_test.dart`, `record_refresh_timing_test.dart`, `record_sync_test.dart` |
| 탈퇴 시 계정별 정리·다른 기기 잠금 안내 | `account_deletion_local_test.dart`, `account_deletion_widget_test.dart`, `firebase_auth_test.dart` |
| 서버 접근·entitlement·기록/영수증 원자 쓰기·탈퇴 표식 | 로컬 Auth·Firestore 에뮬레이터의 `tool/firestore_rules_smoke.mjs` |

전체 Flutter 테스트 **1,227개 통과**(신규 통합·상태 회귀 테스트 5개 포함), Dart 분석 **`No issues found!`**를 확인했다. 날짜·시간 경계를 고려해 통합 테스트의 날씨 대역과 캘린더 검증도 보정하고 관련 신규 테스트를 별도로 재확인했다.

로컬 Firebase 검사는 `demo-fishing-mvp` 프로젝트의 Auth `127.0.0.1:19099`·Firestore `127.0.0.1:18080`에서 실행하여 **종료 코드 0 / `Firestore rules smoke test passed.`**를 확인했다. 임시 설정·현재 규칙 사본·실행 로그는 Git에서 제외되는 `.dart_tool/`에 보관했다. 검사 종료 후 에뮬레이터를 종료했다. 운영 인덱스 준비 상태와 운영에 배포된 규칙을 검사한 결과는 아니다.

```powershell
& "C:\flutter\bin\flutter.bat" test --no-pub --concurrency=1 --reporter expanded
& "C:\flutter\bin\dart.bat" analyze --fatal-infos
```

규칙 검사는 설치된 Firebase CLI의 `emulators:exec`로 Auth·Firestore만 실행하고 `tool/firestore_rules_smoke.mjs`를 호출한다. 이번 실행은 기존 설정과 충돌하지 않도록 `.dart_tool/mvp.firebase.json`의 별도 로컬 포트를 사용했다.

## 남은 확인 사항

1. **민물·내륙 기록의 필수 입력 정책:** 지도는 해양 정보를 숨기지만 기록 폼은 물때·수온을 필수로 요구한다. 민물 위치에서 기록을 열고 다른 항목을 채워 저장하면 물때 입력을 요구하며, 수온이 없을 때도 저장이 막힌다. 제공되지 않는 자료를 사용자가 임의로 채워야 할 수 있으므로 후속 정책 정리가 필요하다. 이번 브랜치에서는 필수 조건을 임의로 완화하거나 수역 저장 필드를 추가하지 않았다.
2. **비밀번호 재설정:** 별도 `feature/password-reset` 브랜치의 전용 화면·메일 연결 설정 작업이다. Firebase의 `EMAIL_TEMPLATE_UPDATE_NOT_ALLOWED` 지원 답변과 URL 변경, 새 메일을 통한 실제 변경·로그인 확인이 남아 있다. 이 통합 브랜치로 가져오지 않았다.
3. **실제 기기 통합 확인:** [체크리스트의 사용자 통합 실행 시나리오](mvp_test_checklist.md#11-사용자-통합-실행-시나리오)를 따른다. 테스트 계정으로 실제 지도·권한·외부 데이터·사진·앱 복귀·두 기기 동기화와 원격 탈퇴를 확인한다. 자동 검사 결과로 수동 체크를 완료 처리하지 않았다.

Android `applicationId`와 로컬 Firebase Android 등록 파일의 패키지는 모두 `com.jinhwan.fishing_build`이며 Firebase 프로젝트 ID는 `fishingbuild`로 일치한다. 실제 기기 연결·로그인이나 운영 서비스의 가용성을 이 설정 확인만으로 보증하지 않는다.
