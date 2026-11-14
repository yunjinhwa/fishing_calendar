# 감사 파일별 검토 범위

HEAD `7929bf8`. 전체 파일의 정밀 수동 검토를 뜻하지 않는다. 구조 검색은 구문·import·선별 패턴 검사이며 각 파일 의미 검증이 아니다. 파일별 실제 검토 깊이와 미검토 범위는 아래와 같다.

- 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님): 71개
- 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료: 124개
- 목록/해시만 확인; 바이너리 내용 검토 미실행: 37개
- JSON 파싱·목록/해시 확인; 개별 데이터 전수 검증 미실행: 2개
- 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료: 122개
- 전체 suite 실행·정적 분석; 본문 수동 검토 미완료: 96개

| 파일 | 검토 수준 |
|---|---|
| `.gitignore` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `.metadata` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `README.md` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `analysis_options.yaml` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/.gitignore` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/build.gradle.kts` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `android/app/google-services.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/src/debug/AndroidManifest.xml` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/src/main/AndroidManifest.xml` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `android/app/src/main/kotlin/com/example/fishing_build/MainActivity.kt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/src/main/res/drawable-v21/launch_background.xml` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/src/main/res/drawable/launch_background.xml` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/src/main/res/mipmap-hdpi/ic_launcher.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `android/app/src/main/res/mipmap-mdpi/ic_launcher.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `android/app/src/main/res/values-night/styles.xml` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/src/main/res/values/styles.xml` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/app/src/profile/AndroidManifest.xml` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/build.gradle.kts` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/build/reports/problems/problems-report.html` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/gradle.properties` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/gradle/wrapper/gradle-wrapper.properties` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `android/settings.gradle.kts` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `assets/data/fish_catalog.json` | JSON 파싱·목록/해시 확인; 개별 데이터 전수 검증 미실행 |
| `assets/data/fish_enrichment.json` | JSON 파싱·목록/해시 확인; 개별 데이터 전수 검증 미실행 |
| `assets/images/share_record_background.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `assets/legal/privacy.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `assets/legal/terms.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/account_deletion.md` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `docs/app_info_and_licenses.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/calendar_record_range.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/firebase_auth_setup.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/firestore_record_sync.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/fish_data_coverage.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/fish_encyclopedia_api.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/fish_enrichment_inventory.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/historical_external_data.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/incremental_record_sync.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/kakao_map_setup.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/local_photo_cleanup.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/location_coordinates.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/mvp_integration_check.md` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `docs/mvp_test_checklist.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/optional_record_conditions.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/paid_cache_policy.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/personal_best_accuracy.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/plan_migration_integrity.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/project-health-audit.md` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `docs/record_edit_version.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/record_save_recovery.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/server_plan_entitlement.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/share_record_background.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/share_record_image.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/terms_and_privacy.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/tide_api_setup.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/water_area_detection.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/water_temperature_api_setup.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `docs/weather_api_setup.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `firebase.json` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `firestore.indexes.json` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `firestore.rules` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `fish.example.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/.gitignore` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Flutter/AppFrameworkInfo.plist` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Flutter/Debug.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Flutter/Release.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcodeproj/project.pbxproj` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcodeproj/project.xcworkspace/contents.xcworkspacedata` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcworkspace/contents.xcworkspacedata` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/AppDelegate.swift` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/Base.lproj/LaunchScreen.storyboard` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/Base.lproj/Main.storyboard` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/Info.plist` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `ios/Runner/Runner-Bridging-Header.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/Runner/SceneDelegate.swift` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `ios/RunnerTests/RunnerTests.swift` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `kakao.example.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `lib/app.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/core/theme/app_theme.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/core/validation/auth_input_validator.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/core/validation/fishing_record_validator.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/app_info/app_info_gateway.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/app_info/app_licenses.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/app_info/app_source.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/app_info/app_source_catalog.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/app_info/fish_attribution_repository.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/auth/auth_gateway.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/auth/firebase_auth_bootstrap.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/auth/firebase_auth_gateway.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/auth/nickname_policy.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/fish/bundled_fish_descriptions.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/bundled_fish_enrichment.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/composite_fish_detail_provider.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/fish/fish_api_configuration.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/fish_catalog_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/fish_photo_validation.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/fish_size_summary.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/fish_taxonomy_resolver.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/inaturalist_fish_photo_provider.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/keyless_fish_catalog_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/mbris_fish_detail_provider.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/nifs_naris_fish_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/recovering_fish_detail_provider.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/reviewed_fish_photos.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/fish/wikimedia_fish_detail_provider.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/history/historical_conditions.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/history/historical_conditions_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/history/khoa_historical_water_temperature_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/history/kma_historical_weather_configuration.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/history/kma_historical_weather_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/local/app_database.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/local/data_owner_key.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/local/database_factory.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/local/database_factory_io.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/local/database_factory_stub.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/local/local_data_migration_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/local/local_data_store.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/local/local_identity_migration_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/current_location_gateway.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/geolocator_current_location_gateway.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/kakao_map_configuration.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/kakao_map_search_gateway.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/map_location.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/map_search_gateway.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/open_map_water_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/maps/water_area.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/maps/water_area_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/conflict_item.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/external_data.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/models/fish_species.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/fishing_record.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/models/local_record_change.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/outbox_item.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/personal_best_record.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/plan_entitlement.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/models/record_cache_policy.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/record_edit_snapshot.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/record_range_cursor.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/record_sync_checkpoint.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/record_sync_metadata.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/share_record_data.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/user_plan.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/models/user_plan_policy.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/photos/record_photo_file_store.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/photos/record_photo_file_store_io.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/photos/record_photo_file_store_stub.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/photos/record_photo_file_store_types.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/photos/record_photo_file_store_utils.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/remote/firebase_record_sync_bootstrap.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/remote/firestore_record_sync_gateway.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/remote/record_sync_gateway.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/repositories/auth_session_repository.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/repositories/conflict_repository.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/repositories/fish_species_repository.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/repositories/fishing_record_repository.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/repositories/outbox_repository.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/repositories/personal_best_repository.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/services/account_deletion_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/services/conflict_resolution_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/services/external_data_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/services/kma_weather_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/services/network_status_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/services/paid_record_cache_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/services/plan_policy_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/services/record_mutation_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/services/record_photo_cleanup_coordinator.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/services/record_photo_cleanup_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/services/record_refresh_watcher.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/services/record_sync_service.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/sharing/share_image_exporter.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/sharing/share_image_exporter_io.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/data/sharing/share_image_exporter_stub.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/sharing/share_image_exporter_types.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/khoa_tide_configuration.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/khoa_tide_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/khoa_tide_stations.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/korean_lunar_date.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/tide_convention.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/tide_models.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/tide_name.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/tide_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/tides/tide_station_catalog.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/water_temperature/khoa_water_temperature_configuration.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/water_temperature/khoa_water_temperature_day_client.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/water_temperature/khoa_water_temperature_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/water_temperature/khoa_water_temperature_stations.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/water_temperature/water_temperature_models.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/water_temperature/water_temperature_service.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/weather/kma_forecast_time.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/weather/kma_grid.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/data/weather/kma_weather_configuration.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/firebase_options.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/main.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/app_info/app_info_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/auth/auth_access_guard.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/auth/auth_error_message.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/auth/login_choice_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/auth/login_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/auth/signup_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/calendar/calendar_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/calendar/calendar_record_layout.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/calendar/calendar_settings_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/calendar/daily_record_list_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/common/hold_to_reveal_password_field.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/common/placeholder_screen.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/fish_dictionary/fish_dictionary_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/fish_dictionary/fish_species_detail_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/fish_dictionary/fish_species_photo.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/fish_dictionary/fish_thumbnail_loader.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/legal/policy_document_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/kakao_map_canvas.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/location_conditions_card.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/map/map_detail_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/map_fallback_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/map_history_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/map_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/map/map_selection_controller.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/tide_data_card.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/tide_panel.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/map/weather_data_card.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/my_page/my_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/offline/network_status_widgets.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/offline/offline_free_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/offline/offline_guest_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/offline/offline_mode_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/offline/offline_paid_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/personal_best/personal_best_detail_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/personal_best/personal_best_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/personal_best/personal_best_photo.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/plan/plan_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/record/record_detail_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/record/record_form_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/record/record_history_scope.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/record/record_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/search/record_search_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/share/share_image_capture.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/share/share_record_card.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/share/share_record_page.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/shell/app_shell.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `lib/presentation/sync/conflict_detail_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/sync/outbox_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `lib/presentation/sync/sync_conflict_page.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `linux/.gitignore` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/CMakeLists.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/flutter/CMakeLists.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/flutter/generated_plugin_registrant.cc` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/flutter/generated_plugin_registrant.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/flutter/generated_plugins.cmake` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/runner/CMakeLists.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/runner/main.cc` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/runner/my_application.cc` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `linux/runner/my_application.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/.gitignore` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Flutter/Flutter-Debug.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Flutter/Flutter-Release.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Flutter/GeneratedPluginRegistrant.swift` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner.xcodeproj/project.pbxproj` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner.xcworkspace/contents.xcworkspacedata` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/AppDelegate.swift` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `macos/Runner/Base.lproj/MainMenu.xib` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Configs/AppInfo.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Configs/Debug.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Configs/Release.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Configs/Warnings.xcconfig` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/DebugProfile.entitlements` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Info.plist` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/MainFlutterWindow.swift` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `macos/Runner/Release.entitlements` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `macos/RunnerTests/RunnerTests.swift` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `pubspec.lock` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `pubspec.yaml` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `test/account_deletion_local_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/account_deletion_widget_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/app_info_gateway_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/app_info_page_test.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `test/app_licenses_test.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `test/app_source_catalog_test.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `test/bundled_fish_enrichment_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/calendar_record_layout_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/calendar_record_range_widget_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/composite_fish_detail_provider_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/current_location_gateway_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/firebase_auth_test.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `test/firestore_incremental_codec_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/firestore_record_codec_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/firestore_record_range_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_attribution_repository_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_catalog_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_detail_audit_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_dictionary_page_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_size_summary_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_species_repository_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_species_size_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fish_taxonomy_resolver_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/fishing_record_validator_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/historical_record_prefill_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/historical_water_temperature_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/historical_weather_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/inaturalist_fish_photo_provider_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/incremental_record_repository_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/incremental_record_sync_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/kakao_map_gateway_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/keyless_fish_catalog_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/korean_lunar_date_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/local_database_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/location_conditions_card_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/location_coordinates_conflict_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/location_coordinates_firestore_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/location_coordinates_form_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/location_coordinates_model_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/location_coordinates_storage_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/location_coordinates_sync_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/map_history_page_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/map_page_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/map_selection_controller_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/map_water_scope_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/mbris_fish_detail_provider_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/mvp_record_flow_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/mvp_sync_status_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/network_status_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/open_map_water_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/optional_record_conditions_sync_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/optional_record_conditions_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/outbox_partial_update_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/paid_cache_history_widget_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/paid_cache_identity_migration_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/paid_cache_photo_storage_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/paid_cache_record_repository_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/paid_cache_sync_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/paid_record_cache_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/password_visibility_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/personal_best_page_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/personal_best_repository_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/plan_migration_integrity_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/plan_policy_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/policy_documents_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_cache_policy_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_edit_version_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_edit_version_widget_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_photo_cleanup_coordinator_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_photo_cleanup_file_store_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_photo_cleanup_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_photo_cleanup_widget_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_photo_file_store_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_photo_ui_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_refresh_timing_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_save_recovery_widget_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_save_transaction_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_sync_checkpoint_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/record_sync_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/recovering_fish_detail_provider_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/reviewed_fish_photos_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/share_image_exporter_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/share_record_card_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/share_record_data_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/share_record_page_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/support/fake_record_sync_gateway.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `test/support/fixed_water_area_service.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/support/incremental_fake_record_sync_gateway.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/support/test_database.dart` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `test/tide_catalog_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/tide_convention_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/tide_panel_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/tide_record_reference_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/tide_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/water_temperature_map_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/water_temperature_prefill_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/water_temperature_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/weather_grid_time_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/weather_prefill_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/weather_service_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/widget_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `test/wikimedia_fish_detail_provider_test.dart` | 전체 suite 실행·정적 분석; 본문 수동 검토 미완료 |
| `third_party/fish_encyclopedia_NOTICE.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `third_party/klc_LICENSE.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `third_party/open_map_water_NOTICE.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `tide.example.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `tool/audit_fish_details.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `tool/build_fish_enrichment.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `tool/collect_all_fish_photos.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `tool/collect_all_mbris_fish.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `tool/collect_all_wiki_fish.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `tool/collect_nifs_fish_photos.py` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `tool/firestore_rules_smoke.mjs` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `tool/test_collect_nifs_fish_photos.py` | 핵심 경로 및 관련 구간 수동 검토 (파일 전체 정독 보장 아님) |
| `tool/update_fish_catalog.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `tool/write_fish_inventory.dart` | 정적 분석·import/위험 패턴 검색; 본문 수동 검토 미완료 |
| `weather.example.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `web/favicon.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `web/icons/Icon-192.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `web/icons/Icon-512.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `web/icons/Icon-maskable-192.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `web/icons/Icon-maskable-512.png` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `web/index.html` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `web/manifest.json` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/.gitignore` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/CMakeLists.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/flutter/CMakeLists.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/flutter/generated_plugin_registrant.cc` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/flutter/generated_plugin_registrant.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/flutter/generated_plugins.cmake` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/CMakeLists.txt` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/Runner.rc` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/flutter_window.cpp` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/flutter_window.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/main.cpp` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/resource.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/resources/app_icon.ico` | 목록/해시만 확인; 바이너리 내용 검토 미실행 |
| `windows/runner/runner.exe.manifest` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/utils.cpp` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/utils.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/win32_window.cpp` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
| `windows/runner/win32_window.h` | 목록/해시·텍스트 구조 검색; 본문 수동 검토 미완료 |
