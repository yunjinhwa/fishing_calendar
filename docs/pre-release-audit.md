# 최종 빌드 전 코드 감사 — 최초 점검 결과

기준: 2026-11-09, `chore/pre-release-audit`, HEAD `7929bf8`.

**현재 상태에서 바로 최종 빌드로 넘어가기보다 High 2건과 데이터 검증 문제부터 수정하는 것이 좋다.** Critical은 이번 조사에서 확인하지 못했다. 이는 미검토 경로까지 결함이 없다는 보증이 아니다.

감사에서 앱·테스트·설정 코드는 수정하지 않았다. 감사 실행 종료 시 기준 HEAD의 추적 파일 452개를 최초 SHA-256과 비교해 모두 일치함을 확인했다. Flutter가 재생성한 macOS 플러그인 등록 파일의 줄바꿈은 최초 해시와 정확히 일치하는 바이트로 복원했다. 이후 감사 브랜치를 마무리하면서 이 보고서, 파일별 검토 범위, 추가 요구사항 문서 3개를 `docs`에 추가했다. 최종 앱 빌드, 배포, 운영 Firebase 쓰기, 기기 조작, 브랜치 변경, 커밋은 하지 않았다.

실행 로그와 진단용 테스트·에뮬레이터 설정은 로컬 `.dart_tool/pre_release_audit/` 및 `.dart_tool/pre_release_*.log`에 보관하며 커밋 대상에 포함하지 않았다. 아래 재현 파일명은 이 로컬 보조 자료를 가리킨다.

추가 화면·기능 요청과 권장 작업 묶음은 [추가 요구사항](pre-release-additional-requirements.md)에 정리했다.

## 구조와 의존성

| 영역 | 현재 구현 |
|---|---|
| 시작 | [lib/main.dart](../lib/main.dart): Firebase 구성 → 세션·SQLite·Outbox·충돌·이전 상태 복구 → 서비스 시작 → `runApp` |
| 앱/탭 | [lib/app.dart](../lib/app.dart), `presentation/shell/app_shell.dart`; StatefulWidget, ChangeNotifier, Navigator, IndexedStack |
| 기록 쓰기 | 화면 → `RecordMutationService` → SQLite 기록·Outbox/무료 변경 이력 트랜잭션 → 저장소 갱신 |
| 동기화 | `RecordSyncService` → `FirestoreRecordSyncGateway`; 버전 비교, 영수증을 통한 중복 처리 방지, 증분/기간 조회, 수동 충돌 해결 |
| 인증/요금제 | `AuthSessionRepository`, `FirebaseAuthGateway`, `PlanPolicyService`; Firebase UID별 로컬 분리, 서버 entitlement, 탈퇴 표식 |
| 영속 저장 | sqflite/FFI, DB 스키마 v6, SharedPreferences; 사진은 앱 전용 디렉터리의 파일 |
| 외부 정보 | Dio 기반 기상청·해양조사원·어류 정보 서비스, Kakao 지도, 위치 권한, 수역 타일 판별 |
| 출력 | 기록어 집계, RepaintBoundary 이미지 생성, share_plus/gal/file_selector |
| 주요 검증 | Flutter 단위·위젯 테스트, Python 수집 파서 테스트, Auth/Firestore 로컬 에뮬레이터 규칙 검사 |

사용 SDK는 Flutter 3.41.9 / Dart 3.11.5이다. `lib` 165개·41,307줄, `test` 102개·42,144줄, `tool` 10개·4,882줄이다. 줄 수는 최초 파일 목록 기준이며 주석·빈 줄을 포함한다. 앱 코드와 테스트 코드를 합쳐 제품 구현량으로 계산하지 않았다.

## 발견 사항

### A-01 · High · 이전 회원가입의 실패 정리가 나중에 로그인한 계정을 삭제할 수 있음

- **근거:** [lib/data/repositories/auth_session_repository.dart:668](../lib/data/repositories/auth_session_repository.dart:668), `:709`, `:1925`, 특히 `:1943`; [lib/data/auth/firebase_auth_gateway.dart:501](../lib/data/auth/firebase_auth_gateway.dart:501); [lib/presentation/auth/signup_page.dart:293](../lib/presentation/auth/signup_page.dart:293).
- **발생 조건:** A 계정 가입이 Firebase 계정 생성 후 닉네임 검사에서 대기한다. 그 사이 가입 화면의 로그인 링크나 뒤로 이동으로 B 계정에 로그인한다. A의 닉네임 중복 응답이 늦게 도착한다.
- **원인:** 가입/로그인 전체 흐름을 구분하는 작업 식별자나 직렬화가 없다. 롤백은 생성한 `user.uid`를 전달받지만 삭제할 때는 `gateway.deleteCurrentUser()`를 호출한다. 실제 게이트웨이도 호출 시점의 `_auth.currentUser`를 삭제한다. 가입 버튼만 비활성화되고 다른 인증 화면으로 이동하는 링크는 활성 상태다.
- **영향:** 가입에 실패한 A 대신 B의 Authentication 계정이 삭제될 수 있다. 닉네임·Firestore 데이터의 정식 탈퇴 정리도 거치지 않아 잔여 데이터가 생길 수 있다. B는 방금 로그인했으므로 최근 로그인 요구만으로 이 경합을 막을 수 있다고 볼 수 없다.
- **확인 수준:** **격리 재현 완료.** 기존 FakeAuthGateway를 확장해 닉네임 응답을 지연시켰다. 실제 삭제 대상 목록이 `['existing-victim']`가 됐다. 운영 Firebase 계정 삭제나 실제 기기의 화면 조작은 실행하지 않았다.
- **수정 방향:** 인증 작업 단위의 실행 제한/세대 번호를 저장소에서 적용하고 모든 await 이후 결과 적용을 검증한다. 롤백은 해당 작업이 생성한 UID에만 적용하도록 게이트웨이 계약을 바꾼다. UID 확인과 삭제 사이에도 다른 인증 작업이 끼어들지 않게 해야 한다. UI의 인증 화면 이동 제한은 보조 수단이다. 실패한 이전 작업이 새 세션을 로그아웃시키는 경로도 함께 보호한다.
- **필요 회귀 테스트:** 가입 대기 중 다른 계정 로그인, 로그인 A/B 응답 역전, 화면 종료 후 가입 실패, 같은 UID 재로그인 후 이전 작업 완료.
- **재현 파일:** `auth_race_probe_test.dart`, 결과 `auth_probe.log`.

### A-02 · High · 첫 서버 동기화의 이전 충돌을 해결해도 다음 동기화가 막힘

- **근거:** [lib/data/services/conflict_resolution_service.dart:120](../lib/data/services/conflict_resolution_service.dart:120); [lib/data/services/record_sync_service.dart:317](../lib/data/services/record_sync_service.dart:317), `:886`, `:779`; [lib/data/local/app_database.dart:475](../lib/data/local/app_database.dart:475); [lib/data/repositories/conflict_repository.dart:70](../lib/data/repositories/conflict_repository.dart:70).
- **발생 조건:** 첫 실제 서버 동기화가 완료되지 않은 기기에서 무료→유료 이전 기록이 서버 기록과 충돌하고, 사용자가 ‘서버 기록 사용’을 선택한 뒤 다시 동기화한다.
- **원인:** 해결 과정에서 이전 Outbox 항목을 `succeeded`로 남기지만 기존 `baseVersionNo`를 유지한다. 첫 동기화 준비 코드는 모든 succeeded 항목을 재전송 대상으로 바꾼다. 이 항목은 서버에서 처리된 요청의 영수증이 없고 기준 버전도 오래되어 다시 충돌한다. 새 충돌 행을 넣을 때 이미 해결된 충돌의 `(owner_key, outbox_id)` UNIQUE 제약과 충돌한다.
- **영향:** 화면에서는 충돌 해결과 이전 완료로 보이지만 다음 동기화는 일반 오류로 실패한다. 재현 시 Outbox가 `sending`, 충돌 이력은 `resolved`, 미해결 충돌 목록은 빈 상태였다. 해당 대기열 이후 기록 전송도 막힐 수 있다. 이번 재현에서는 서버/로컬 기록 유실을 확인한 것은 아니다.
- **확인 수준:** **공개 서비스 경로 + 실제 메모리 SQLite + 모의 서버로 재현 완료.** 같은 Outbox ID가 두 번 전송되고 다음 sync 결과가 실패했다. 실제 Firestore 게이트웨이에도 동일한 기준 버전 불일치 검사(`:100`)가 있음을 확인했다. 운영 두 기기 재현은 미실행이다.
- **수정 방향:** 서버에서 실제 커밋된 항목, 과거 모의 성공 항목, 사용자가 서버본을 채택해 종결한 항목을 구분한다. 서버본 채택을 재전송 대상으로 되살리지 않는다. 기존 데이터의 막힌 항목을 안전하게 복구하는 경로와, 같은 요청에 대한 충돌 감지의 멱등성도 검토한다. 전체 초기 동기화 완료 표식만 임의로 앞당겨 미전송 데이터를 건너뛰면 안 된다.
- **필요 회귀 테스트:** ‘서버 기록 사용’ 후 다음 동기화/재실행, 서버 삭제본 채택, 여러 이전 기록 중 하나만 충돌, 다른 기록의 후속 전송.
- **재현 파일:** `data_integrity_probe_test.dart`, 결과 `data_probe.log`.

### A-03 · Medium · 서버가 허용하는 조과 형식과 앱이 읽을 수 있는 형식이 다름

- **근거:** `firestore.rules:254`; [lib/data/remote/firestore_record_sync_gateway.dart:530](../lib/data/remote/firestore_record_sync_gateway.dart:530), `:721`, `:743`.
- **발생 조건:** 유료 사용자의 유효한 인증으로 직접 API를 호출하거나 다른/구버전 클라이언트가 `catches: [42]` 같은 잘못된 배열을 저장한다. 현재 정상 앱 폼은 이런 값을 만들지 않는다.
- **원인:** 규칙은 `catches`가 리스트이고 100개 이하인지 검사하지만 개별 조과의 객체 형태·필드 타입을 검사하지 않는다. 앱 디코더는 각 항목을 Map으로 변환하며, 한 문서의 변환 실패가 snapshot/page 읽기 전체의 실패로 전파된다.
- **영향:** 서버에는 저장됐지만 앱은 읽을 수 없는 기록이 생긴다. 해당 계정의 전체/해당 페이지 동기화를 중단시킬 수 있다. 다른 계정에 쓰기가 가능해진다는 의미는 아니다.
- **확인 수준:** **로컬 Auth/Firestore 에뮬레이터에서 비관리자 사용자 토큰으로 저장 HTTP 200 확인.** 같은 형태의 데이터를 앱 snapshot 디코더에 넣으면 `invalid-server-data`로 거절되는 것도 테스트로 확인했다.
- **수정 방향:** 쓰기 경계의 스키마 계약을 맞춘다. Firestore Rules의 반복·평가 제한을 고려해 검증 가능한 저장 구조나 신뢰할 수 있는 검증 경로를 선택한다. 읽기 실패 시 문제 문서를 식별·복구할 수 있게 하고, 부분 데이터를 완전한 서버 snapshot으로 취급해 정상 로컬 기록을 삭제하지 않도록 한다. 무조건 예외를 무시하고 진행하는 수정은 부적절하다.
- **필요 회귀 테스트:** 숫자/문자열 조과 항목, 필수 필드 누락, 잘못된 크기·무게, 정상 100개 조과, 손상 문서가 있는 페이지의 정상 기록 보존.
- **재현 파일:** `rules_shape_probe.mjs` / `rules_shape_probe.log`, `cloud_shape_probe_test.dart` / `cloud_shape_probe.log`.

### A-04 · Medium · 초기 DB 열기 실패 시 복구 화면까지 도달하지 못함

- **근거:** [lib/main.dart:38](../lib/main.dart:38), `:40`, `:49`; [lib/data/local/app_database.dart:74](../lib/data/local/app_database.dart:74); [lib/data/repositories/fishing_record_repository.dart:40](../lib/data/repositories/fishing_record_repository.dart:40).
- **발생 조건:** 시작 시 SQLite 열기/마이그레이션이 실패한다. 실제 원인으로 저장 공간·파일 상태·플랫폼 저장소 오류 등이 가능하지만 이번 기기에 그런 장애가 있었다고 확인한 것은 아니다.
- **원인:** 초기 데이터 로딩을 모두 `runApp` 전에 기다리며 바깥쪽 오류 처리나 재시도 화면이 없다.
- **영향:** 초기화 예외가 main 밖으로 전파되어 앱 UI를 열지 못한다. 사용자는 오류 원인과 안전한 재시도 수단을 보지 못할 수 있다.
- **확인 수준:** **DB 열기 오류를 주입한 위젯 테스트에서 재현.** `FishingRecordRepository.loadRecords → main:40` 예외 전파를 확인했다. 실제 디스크 손상/용량 부족 시험은 하지 않았다.
- **수정 방향:** 최소 시작 화면을 먼저 띄우고 단계별 초기화 실패·재시도를 제공한다. 실패 시 원본 DB를 유지한다. 자동 DB 삭제/초기화로 ‘복구’해서는 안 된다.
- **필요 회귀 테스트:** 최초 DB 열기 실패 후 재시도 성공, 스키마 업그레이드 실패와 기존 파일 보존, cleanup 실패와 독립적인 앱 진입.
- **재현 파일:** `startup_probe_test.dart`, 결과 `startup_probe.log`.

### A-05 · Medium · 현재 전체 자동 테스트 3개 실패

- **근거:** [test/app_source_catalog_test.dart:10](../test/app_source_catalog_test.dart:10), `:132`; [test/app_info_page_test.dart:72](../test/app_info_page_test.dart:72); [lib/presentation/app_info/app_info_page.dart:76](../lib/presentation/app_info/app_info_page.dart:76); [lib/data/app_info/app_source_catalog.dart](../lib/data/app_info/app_source_catalog.dart).
- **발생 조건:** 현재 HEAD에서 전체 `flutter test --no-pub` 실행.
- **원인:** 테스트는 제거된 `share_card_background` 항목을 기대한다(2건). 화면 테스트는 ‘API·데이터·이미지 출처’를 찾지만 실제 문구는 ‘API·데이터·사진 출처’다(1건).
- **영향:** 전체 검증이 통과하지 않는다. 이번 세 실패를 앱 자체의 화면 크래시나 출처 누락에 따른 법적 위반으로 해석하지 않았다. 현재 UI 변경과 테스트 계약의 불일치다.
- **확인 수준:** **실제 전체 실행에서 1,279개 중 1,276개 통과·3개 실패.** 개별 실패와 현재 코드가 일치하여 전체 테스트를 반복하지 않았다.
- **수정 방향:** 확정된 화면/출처 정책에 맞춰 기대값을 갱신한다. 출처 링크 안전성, 라이선스 제공, 화면 이동 검증 자체는 유지한다. 필요하면 문구 의존 대신 의미 있는 key를 사용한다.
- **필요 회귀 테스트:** 기존 3건 수정 후 해당 파일 및 전체 suite 통과.
- **결과 파일:** `../pre_release_full_tests.log`.

### A-06 · Medium · 작은 기록 사진 미리보기에서 원본 해상도로 디코딩할 가능성

- **근거:** [lib/presentation/record/record_form_page.dart:1843](../lib/presentation/record/record_form_page.dart:1843), `:1861`; [lib/presentation/record/record_detail_page.dart:517](../lib/presentation/record/record_detail_page.dart:517), `:535`; [lib/core/validation/fishing_record_validator.dart:16](../lib/core/validation/fishing_record_validator.dart:16).
- **발생 조건:** 고해상도 사진 여러 장을 기록에 붙이고 작성/상세 화면을 연다. 파일당 10 MiB·최대 10장 제한 이내에서도 가능하다.
- **원인:** Image.file/Image.memory의 표시 크기는 96/120으로 지정했지만 `cacheWidth/cacheHeight` 또는 ResizeImage가 없다. 압축 파일 크기 제한은 디코딩한 이미지의 픽셀 메모리 제한과 다르다. 기록어·공유·도감에는 이미 ResizeImage를 사용하지만 이 두 경로에는 적용되지 않았다.
- **영향:** 예를 들어 4000×3000 RGBA 한 장의 픽셀 버퍼만 약 45.8 MiB다. 여러 장을 함께 유지하면 메모리 압박·스크롤 끊김·프로세스 종료 위험이 있다. 이것은 해제되지 않는 참조를 입증한 ‘메모리 누수’ 판정이 아니다.
- **확인 수준:** **코드에서 디코딩 크기 지정 누락 확인; 실제 기기 OOM·프레임 저하는 미측정.** Flutter SDK의 Image 구현/문서에서도 decode 크기와 표시 크기가 별개임을 확인했다.
- **수정 방향:** 화면 크기와 DPR에 맞는 디코딩 크기를 지정하고 원본 파일은 유지한다. 편집/상세/기록어의 사진 provider를 공통화할 수 있다. 저사양 기기의 고해상도 10장 시나리오로 최대 메모리를 측정한다.

### A-07 · Medium · 같은 지도 화면에 머무르거나 장시간 백그라운드 후 복귀할 때 현재 정보가 갱신되지 않음

- **근거:** [lib/presentation/map/map_page.dart:135](../lib/presentation/map/map_page.dart:135), `:304`, `:359`; [lib/presentation/map/weather_data_card.dart:41](../lib/presentation/map/weather_data_card.dart:41); [lib/app.dart:62](../lib/app.dart:62).
- **발생 조건:** 지도 탭을 유지한 채 시간이 지나거나 네트워크 상태 변화 없이 오래 후 앱으로 복귀한다.
- **원인:** 지도 진입/위치 변경/네트워크 복구로 조회하지만 시간 경과·resume에 따른 정보 만료 갱신 경로가 없다. 같은 MapLocation 객체면 재조회도 막는다. 앱 resume 처리는 네트워크·요금제·기록 동기화에 한정된다. WeatherDataCard는 현재 예보의 `validAt`을 검사하지 않는다.
- **영향:** 지난 시간의 날씨/기온이 계속 보일 수 있다. 수온은 다시 빌드될 때 유효 기간을 검사해 ‘제공되지 않음’으로 바뀔 수 있지만 최신 자료를 자동으로 다시 요청하지 않는다.
- **확인 수준:** **코드 경로 확인; 실제 기기에서 시간 경과/백그라운드 장기 시험 미실행.** 탭을 다시 들어왔을 때의 조회 경로는 존재하므로 ‘지도는 항상 갱신 안 됨’으로 판단하지 않았다. 기록 자동입력에는 별도의 시간 검증도 있다.
- **수정 방향:** 활성 화면 복귀와 데이터 만료를 기준으로만 갱신하고 진행 중 요청을 합친다. 사용자가 선택한 과거 조석 날짜는 유지한다. 비활성 탭의 주기적 API 호출은 피한다.
- **필요 회귀 테스트:** 같은 위치·연결 상태의 장기 resume, 시간 경계, 자정, 비활성 탭 요청 없음, 과거 날짜 선택 유지.

### A-08 · Low · 사용되지 않는 직접 의존성과 자리표시 화면

- **근거:** `pubspec.yaml:37` 이후 의존성 목록; [lib/presentation/common/placeholder_screen.dart:3](../lib/presentation/common/placeholder_screen.dart:3).
- **발생 조건/원인:** 전체 추적 Dart 소스의 import 검색에서 `go_router`, `flutter_riverpod`, `freezed_annotation`, `json_annotation`, `cupertino_icons`를 직접 사용하는 import가 없었다. PlaceholderScreen 참조도 선언 외에는 없었다.
- **영향:** 기능 장애를 확인한 것은 아니다. 의존성 해석·버전 충돌·유지보수 대상이 불필요하게 늘어날 수 있다. 번들 크기나 빌드 시간이 얼마나 증가하는지는 측정하지 않았다.
- **확인 수준:** **참조 검색 확인.** 각 패키지의 전이 의존성 전체를 감사하거나 제거 실험을 한 것은 아니다.
- **수정 방향:** 실제 사용 및 생성 도구 계획을 확인하고 별도 정리에서 직접 의존성을 제거한다. pubspec과 lock을 함께 갱신한 후 분석·테스트한다. 이 감사에서는 제거하지 않았다.

## 실행한 검증

| 검증 | 결과/한계 |
|---|---|
| `flutter analyze --no-pub` | No issues found, 12.6초 |
| 전체 `flutter test --no-pub --reporter expanded` | 1,276 통과 / 3 실패. 위 A-05 참조 |
| `python -m unittest tool.test_collect_nifs_fish_photos -v` | 4개 통과. 외부 API 수집은 실행하지 않음 |
| 기존 [tool/firestore_rules_smoke.mjs](../tool/firestore_rules_smoke.mjs) | demo 프로젝트의 로컬 Auth/Firestore 에뮬레이터에서 통과, CLI 종료 코드 0 |
| 인증 경합 추가 진단 | A-01의 기대 안전 조건 실패, 다른 계정 삭제 대상 확인 |
| 이전 충돌 후 재동기화 추가 진단 | A-02 재현. 실패 결과·반복 전송 ID·전송 중 상태 확인 |
| 잘못된 조과 쓰기 추가 진단 | HTTP 200. 거절 기대 조건 실패; 앱 decoder 거절 확인 테스트는 통과 |
| 초기 DB 오류 주입 | 복구 UI 도달 기대 조건 실패. main 밖으로 예외 전파 |
| 파일·설정 검사 | 추적 452개 목록/해시, UTF-8 텍스트 415개 구조 검색, 상대 Dart import 대상, 번들 JSON 구문, 대표 권한·플랫폼 설정 확인 |
| 키 패턴 검사 | 추적 텍스트에서 PEM private key / service-account private_key_id / JSON client_secret 패턴 미검출. 완전한 비밀정보 탐지 보증은 아님 |
| 변경 확인 | 감사 실행 종료 시 최초 SHA-256과 기준 추적 파일 전부 일치, `git diff --check` 통과, git status clean. 이후 보고서 문서 3개 추가 |

기존 규칙 검사 로그의 일부 거절 시나리오에서 규칙 평가 횟수 제한 메시지가 나왔다. 검사의 성공 요청들은 통과했고 해당 거절 요청들도 기대값과 맞았다. 그 메시지만으로 정상 요청이 실패한다고 판정하지 않았다. 규칙 보완 시 표현식 한계에 대한 경계 테스트는 유지해야 한다.

추가 진단은 제품의 추적 테스트에 반영하지 않았다. 진단 테스트가 실패한 것은 안전해야 할 기대값과 현재 동작이 달라 문제를 재현했다는 의미다. 기존 전체 suite의 실패 개수와 합산하지 않는다.

## 검토 범위와 제한

전체 추적 파일을 목록화하고 텍스트·Dart 파일의 구조를 조사했다. 인증/계정 삭제/요금제, SQLite·이전·Outbox·버전 충돌, 기록 저장·사진 정리, 외부 데이터와 지도, 공유/기록어, 앱 정보·권한 설정 순서로 위험 경로를 검토했다. **452개 파일의 모든 줄을 수동으로 정밀 검토한 것은 아니다.**

- [파일별 검토 범위](pre-release-audit-coverage.md)에 452개 파일별 검토 수준을 적었다. `핵심 경로 검토`도 해당 파일 모든 줄을 완전히 검증했다는 뜻이 아니다.
- 수동 본문 검토를 하지 않은 Dart 파일은 정적 분석·참조 검색 대상으로만 구분했다. 테스트 실행 성공은 테스트 파일의 모든 assertion을 수동 검토했다는 의미가 아니다.
- 플랫폼 템플릿/생성 파일, 이미지·아이콘 바이너리, 대용량 어류 JSON의 모든 개별 종 내용과 사진 권리 관계는 전부 정밀 검토하지 않았다. JSON 구문과 연결 구조만 확인한 범위가 있다.
- 예전 외부 DOCX/PDF 전체와 이미지 설계 자료를 이번에 다시 전부 대조하지 않았다. 현재 저장소 문서와 사용자가 변경한 정책을 기준으로 했다. 과거 감사 문서의 해결 전 결함 목록을 현재 결함으로 재사용하지 않았다.
- 외부 API의 실제 가용성·응답 정확도·호출량·전체 공급망 취약점/CVE, 운영 Firebase에 배포된 규칙/인덱스/권한, API별 계약·저작권 적합성에 대한 최종 판단은 하지 않았다.
- 실제 Android 기기/두 기기 동기화/OS 권한·카메라·갤러리·프로세스 강제 종료/성능 프로파일링은 실행하지 않았다. Android/iOS/desktop/web 최종 빌드, 서명, 스토어 검증도 실행하지 않았다.

수동 검토한 주요 화면의 컨트롤러·listener·subscription 해제, 공유 캡처 이미지 dispose, 사진 정리의 경로/참조 보호를 확인했다. 이번 범위에서 확정적인 listener 메모리 누수나 다른 UID의 기록에 대한 Firestore 접근 우회는 발견하지 못했다. 모든 경합·플러그인 자원까지 안전하다는 뜻은 아니다.

성능 측정 후 판단할 부분도 있다. `CalendarMonthLayout`의 lane 배치는 같은 주에 매우 많은 겹친 기록이 있으면 선형 `indexWhere`를 반복하여 최악 O(n²)이 될 수 있다(`calendar_record_layout.dart:111`). `PersonalBestRepository.getPersonalBest`도 호출마다 전체 조과를 집계한다(`personal_best_repository.dart:41`). 현재 데이터 규모에서 지연을 측정하지 않았으므로 즉시 장애로 분류하지 않았다. 대량 기록으로 프로파일링한 뒤 lane 자료구조와 기록 변경 버전별 집계 캐시 적용 여부를 결정하는 것이 좋다.

## 이번 결함과 분리한 기존 계획

- Firebase Storage 미사용과 사진의 기기 내 보관은 확정 정책이다. 다른 기기에 사진이 없는 것을 동기화 결함으로 집계하지 않았다.
- 물때·수온은 바다/민물 모두 선택 입력이다. 현재 정책을 유지했다.
- 유료 31일 캐시, 무료 전환 시 다운로드 기록 보존, 재전환 시 무료 기간 삭제 반영, 수동 충돌 해결도 기존 정책으로 취급했다.
- 비밀번호 재설정은 별도 브랜치와 Firebase 지원 문의가 남아 있는 것으로 문서에 명시돼 있다. 이번 감사에서 임의 병합하거나 설정하지 않았다.
- 약관/개인정보 처리방침 운영 정보 확정, Android release 서명·아이콘·앱 표시명 등은 배포 준비 항목이다. 기존 debug 서명을 새로 발생한 런타임 결함으로 집계하지 않았다.
- 서버가 보장하는 탈퇴 완료 작업 없이 클라이언트가 단계별로 삭제한다는 한계는 [docs/account_deletion.md](account_deletion.md)에 이미 기록돼 있다. 중단된 탈퇴의 재개·운영 정리 정책을 출시 전에 확인해야 한다.
- 도감 데이터 공백과 결제/운영 백엔드 범위는 기존 합의 사항이며 이 감사에서 임의로 확장하지 않았다.

## 수정 우선순위와 최종 빌드 전 확인

1. **A-01 인증 작업 경합을 먼저 차단한다.** 기존 계정 삭제 가능성이 가장 큰 영향이다.
2. **A-02 이전 충돌 종결 및 재시도 무결성을 고친다.** 이미 sending 상태로 남은 항목의 안전한 복구도 포함한다.
3. **A-03 서버/앱 스키마 불일치를 해결한다.** 잘못된 기존 서버 문서의 진단·복구 방안과 정상 기록 보존을 함께 검증한다.
4. **A-04 시작 실패 복구, A-05 전체 테스트 실패를 정리한다.** 이후 분석과 전체 테스트, 로컬 규칙 검사를 다시 통과시킨다.
5. **A-06/A-07을 보완하고 실제 기기에서 확인한다.** 고해상도 사진 여러 장, 지도 장기 복귀, 오프라인·재연결, 두 기기 계정 전환/동기화/탈퇴를 포함한다.
6. **출시 설정을 확인한다.** release 서명, 앱 식별자/버전, production Firebase 사용, 외부 API 설정 주입, 운영 규칙·인덱스 준비, 개인정보 문서 확정, 비밀번호 재설정의 출시 범위를 확인한 후 별도 빌드 단계로 간다.

이 보고서는 최초 조사 결과이며 수정 완료 보고서가 아니다. 자동 테스트 통과만으로 최종 배포 가능 판정을 내리지 않았다.
