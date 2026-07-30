# Verification Record

Record updated: 2026-07-30

Toolchain:

- Flutter 3.44.8
- Dart 3.12.2
- Pigeon 27.3.0
- Android Gradle Plugin 9.0.1
- Android SDK 36, minimum API 24
- Xcode 26.6 at `/Applications/Xcode.app`
- CocoaPods 1.17.0

The source, package, native build, and archive results below were rerun against
the signed experimental 0.1.0 candidate on 2026-07-30. They must be repeated if
the release commit changes before manual publish.

| Boundary | Command | Result / currency |
|---|---|---|
| Dart format | `dart format --output=none --set-exit-if-changed lib test example/lib example/test example/integration_test pigeons` | Pass |
| Static analysis | `flutter analyze` | Pass with no issues |
| Dart contract tests | `flutter test` | Pass, 51 tests |
| Example widget test | `(cd example && flutter test)` | Pass, 1 test |
| Dart API docs | `dart doc` | Pass with no warnings or errors |
| API baseline | `dart pub global run dart_apitool:main extract --input . --set-exit-on-missing-export --force-use-flutter` with 0.23.2 | Pass |
| Dependency freshness | `flutter pub outdated` | All dependencies are the newest resolvable versions; 8 newer versions are incompatible with the selected SDK constraints |
| Pub score | pana 0.23.15 against a disposable package copy | 140/160: 20/30 conventions, 20/20 documentation, 10/20 platform support, 50/50 static analysis, 40/40 dependencies |
| Package validation | `dart pub publish --dry-run` in a clean `git archive HEAD` package copy | Pass with 0 warnings; compressed public archive is approximately 89 KB |
| Archive inspection | Sensitive filename and credential-pattern scan of the clean `git archive HEAD` package copy | Pass |
| Workflow lint | `actionlint .github/workflows/*.yml` | Pass |
| Android bridge | Gradle compile, unit tests, lint, manifest processing | Pass, including 16 bridge tests, release lint, and a merged manifest without forced battery-exemption permission |
| Android example | `flutter build apk --debug` and `flutter build apk --release` from `example` | Pass; release APK is approximately 93.8 MB |
| Android device launch | `android run --device=R5KL105975E --apks=.../app-debug.apk`, then `android layout` | The earlier baseline passed on `SM-X236N`, Android 16; no current-candidate device runtime verification |
| CocoaPods plugin | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer pod lib lint asleep_sdk_flutter.podspec --allow-warnings --skip-tests` | Pass with the pinned `AsleepSDK` 3.2.0; the upstream pod still warns about its missing license file |
| iOS example | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer flutter build ios --release --no-codesign` from `example` | Pass; unsigned device app is approximately 45.9 MB |

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
error in a future Flutter release. Experimental 0.1.0 does not claim SPM
support; SPM can be added only after the native SDK has an authorized,
consumer-accessible SPM artifact.

The example Podfile now declares and applies the plugin's iOS 15 minimum to all
Pod targets. This removes Xcode 26.6 target-integrity failures from generated
Flutter and dependency targets without changing the plugin's documented
minimum.

The iOS restore bridge deliberately returns `hasActiveSession: false`.
AsleepSDK 3.2.0 retains a session ID after close, so the public identifier
cannot prove that a process-persistent tracking session exists. The current
Swift implementation, complete pagination, pod lint, and unsigned release
build pass locally.

Android restoration now performs an attachment-time
`isSleepTrackingAlive(context)` probe before setup/configuration can assign the
native SDK's process-global context. Restore then performs a fresh liveness
check and connects the listener only when the service remains alive. Unit tests
cover the initial probe and stale-probe false-positive case; process-death
restoration still requires device verification.

The prior CocoaPods warnings came from external build inputs:

- the CocoaPods lint Flutter stub declares iOS 11 while Xcode 26.6 supports iOS
  12 and later;
- the upstream `AsleepSDK 3.2.0` pod references a missing license file.

No physical-device tracking, microphone, background, process-restoration, or
real sleep-session test was performed. Those runtime checks require an issued
API key, supported devices, and product QA authorization.

In the prior baseline, the rebuilt APK was reinstalled and its activity was
activated successfully after the multi-engine ownership patch. That result
predates the current lifecycle changes and is not current device proof.
