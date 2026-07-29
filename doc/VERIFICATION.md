# Verification Record

Verified on: 2026-07-29

Toolchain:

- Flutter 3.44.8
- Dart 3.12.2
- Pigeon 27.3.0
- Android Gradle Plugin 9.0.1
- Android SDK 36, minimum API 24
- Xcode 26.6 at `/Applications/Xcode.app`
- CocoaPods 1.17.0

| Boundary | Command | Result |
|---|---|---|
| Dart format | `dart format --output=none --set-exit-if-changed lib test example/lib example/test example/integration_test pigeons` | Pass |
| Static analysis | `flutter analyze` | Pass, no issues |
| Dart contract tests | `flutter test` | Pass, 13 tests |
| Example widget test | `(cd example && flutter test)` | Pass, 1 test |
| Dart API docs | `dart doc` | Pass, 0 warnings and 0 errors |
| API baseline | `dart pub global run dart_apitool:main extract --input . --set-exit-on-missing-export --force-use-flutter` with 0.23.2 | Pass |
| Dependency freshness | `flutter pub outdated` | Pass; direct and transitive packages use the newest versions resolvable by the current Flutter SDK |
| Pub score | pana 0.23.15 against a disposable copy | 140/160; 91/254 API elements documented; expected license and iOS SPM deficits remain |
| Package validation | `dart pub publish --dry-run` in a disposable copy | Pass, 0 warnings, 100 KB compressed archive; no package was published |
| Archive inspection | Sensitive filename and credential-pattern scan of the disposable copy and dry-run list | Pass; no credential pattern and no sensitive file in the archive list |
| Workflow lint | `actionlint .github/workflows/*.yml` | Pass |
| Android bridge | `./gradlew :asleep_sdk_flutter:compileDebugKotlin :asleep_sdk_flutter:testDebugUnitTest` from `example/android` with Android Studio JBR and Android SDK | Pass, 3 transport and process-ownership tests |
| Android example | `flutter build apk --debug` from `example` | Pass; `build/app/outputs/flutter-apk/app-debug.apk` |
| Android device launch | `android run --device=R5KL105975E --apks=.../app-debug.apk`, then `android layout` | Pass on `SM-X236N`, Android 16; fresh install launched and rendered the explicit idle SDK journey |
| CocoaPods plugin | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer pod lib lint asleep_sdk_flutter.podspec --allow-warnings --skip-tests` | Pass; resolves and compiles `AsleepSDK 3.2.0` |
| iOS example | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer flutter build ios --simulator --debug` from `example` | Pass; `build/ios/iphonesimulator/Runner.app` |

## Important verification notes

The shell initially selected a locally installed Xcode 27 beta. Its simulator
toolchain rejected the
older deployment targets declared by the CocoaPods lint Flutter stub and
AsleepSDK dependency before Swift compilation. Selecting installed stable
Xcode 26.6 exposed and allowed correction of a Pigeon configuration bug, then
completed the full Swift compile successfully.

The iOS plugin is intentionally CocoaPods-only because no supported public
Swift Package Manager distribution for `AsleepSDK 3.2.0` was verified. Flutter
3.44 warns that plugins without Swift Package Manager support may become an
error in a future Flutter release. Adding SPM support is a publication blocker
until the native SDK has an authorized, consumer-accessible SPM artifact.

The example Podfile now declares and applies the plugin's iOS 15 minimum to all
Pod targets. This removes Xcode 26.6 target-integrity failures from generated
Flutter and dependency targets without changing the plugin's documented
minimum.

The iOS restore bridge now uses the public
`getTrackingStatus().sessionId` accessor from AsleepSDK 3.2.0 and the same
contract as the React Native bridge. The rebuilt simulator application compiled
successfully after this change. The native accessor cannot distinguish its
internal open and closed states; that upstream ambiguity remains documented in
the compatibility notes.

The first remote `main` CI run completed the Android APK build, all three
Android unit tests, and the 90 MB artifact upload, then GitHub marked the job
cancelled during cache cleanup at its former 30-minute timeout. The Android job
timeout is now 45 minutes so successful first-cache builds can finish cleanup;
the pull request run is the release-readiness proof for that adjustment.

The remaining warnings come from external build inputs:

- the local podspec uses `s.source = { :path => '.' }` because the public source
  repository is UNKNOWN;
- the CocoaPods lint Flutter stub declares iOS 11 while Xcode 26.6 supports iOS
  12 and later;
- the upstream `AsleepSDK 3.2.0` pod references a missing license file.

No physical-device tracking, microphone, background, process-restoration, or
real sleep-session test was performed. Those runtime checks require an issued
API key, supported devices, and product QA authorization.

After the final multi-engine ownership patch, the rebuilt APK was reinstalled
and its activity was activated successfully on the same device with no crash.
The device display was sleeping, so the final rebuild did not produce a second
useful UI layout capture; the rendered idle-journey layout above was captured
from the immediately preceding build before that native-only lifecycle patch.
