# 미사용 코드·의존성 정리

브랜치: `chore/remove-unused-code` · 대상: [최초 감사](pre-release-audit.md)의 A-08.

## 제거한 항목

현재 앱·테스트·도구의 import/export/part, 패키지 API 사용, 설정과 실행 스크립트를 확인했다. 과거 감사 문서에 이름이 있다는 이유만으로 제거하지 않았다.

| 구분 | 제거 항목 | 확인 근거 |
| --- | --- | --- |
| 앱 직접 의존성 7개 | `cupertino_icons`, `go_router`, `flutter_riverpod`, `freezed_annotation`, `json_annotation`, `table_calendar`, `intl` | 현재 소스에서 사용하지 않음. 캘린더는 자체 Flutter 위젯·DateTime 기반으로 구현 |
| 개발 의존성 3개 | `build_runner`, `freezed`, `json_serializable` | 생성 코드·어노테이션·build 설정·실행 스크립트에서 사용하지 않음 |
| 미연결 화면 2개 | `PlaceholderScreen`, `CalendarSettingsPage` | 실제 import·화면 이동·테스트 참조 없음. 캘린더 설정 진입 코드는 주석 처리된 상태 |

`calendar_page.dart`에 남아 있던 캘린더 설정 import와 버튼의 주석 코드도 제거했다. 실제 표시 중인 캘린더와 이동 기능은 유지한다. 향후 캘린더 설정 기능은 별도 요구사항에 따라 구현할 수 있다.

`Dio` 등 실제 사용하는 패키지와 `flutter_lints`는 유지했다. `tool/generate_catches_rules.dart` 같은 자체 생성 도구는 Dart 코드로 직접 실행되므로 제거한 코드 생성 패키지를 필요로 하지 않는다.

## 잠금 파일 변경

`flutter pub get --offline`으로 현재 캐시와 잠금 파일을 기준으로 의존성을 다시 계산했다.

- `pubspec.yaml`의 직접 선언 10개 제거.
- `pubspec.lock`의 전체 해석 패키지 수는 188개에서 146개로 감소.
- 제거된 직접 의존성과 더 이상 필요하지 않은 전이 의존성을 합쳐 42개 제거.
- 패키지 추가 없음. 남은 패키지의 버전 변경 없음.

전이 의존성은 잠금 파일에서 수동으로 골라 지우지 않고 패키지 관리자가 계산한 결과를 사용했다. 앱 용량·실행 성능·빌드 시간의 변화는 측정하지 않았다.

## 검증

기존 동작을 바꾸는 작업이 아니므로 정리 내용을 그대로 검사하는 신규 테스트는 추가하지 않는다. 기존 전체 테스트와 분석, 자체 규칙 생성 도구로 필요한 패키지나 참조가 빠지지 않았는지 확인한다.

```powershell
flutter pub get --offline
dart analyze --fatal-infos
flutter test --no-pub
dart run tool/generate_catches_rules.dart --check
```

2026-11-16 **전체 Flutter 테스트 1,484개와 정적 분석이 통과**했다. 조과 규칙 생성 도구의 `--check`도 Dart 코덱과 일치함을 확인했다. 삭제 대상의 실행 코드 참조 재검색, 변경 Dart 파일 포맷 검사와 `git diff --check`도 통과했다.

실제 기기 조작과 최종 앱 빌드·배포는 실행하지 않았다.

실기기에서는 앱 실행, 기본 탭 이동, 캘린더 월 이동과 날짜 선택을 간단히 확인할 수 있다.
