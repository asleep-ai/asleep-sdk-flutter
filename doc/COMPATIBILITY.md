# Compatibility and Release Readiness

Verified on: 2026-07-29

## Status Summary

| Layer | Local development baseline | Publication status |
|---|---|---|
| Dart package | `asleep_sdk_flutter`, local version `0.1.0-dev.1` | Provisional; package ownership and final version are UNKNOWN |
| Dart SDK | `^3.12.2` in the generated local scaffold | Provisional; intended consumer fleet is UNKNOWN |
| Flutter | `>=3.44.0` | Conservative local floor matching the Dart 3.12 toolchain; consumer fleet remains UNKNOWN |
| Android | API 24, pinned `ai.asleep:asleepsdk:3.2.1` | Local Kotlin compile, unit tests, and example APK build verified |
| iOS | iOS 15, pinned `AsleepSDK 3.2.0`, CocoaPods-only | Full pod lint and Swift compile verified with Xcode 26.6; clean CI remains required |
| Public repository | Local-only package | UNKNOWN |
| License | Explicit proprietary/license-pending local notice | Legal grant and copyright holder are UNKNOWN |

This repository is a local implementation candidate, not a published or
publication-approved SDK.

## Verified Source Snapshots

| Project | Branch/ref | Commit | Cleanliness and interpretation |
|---|---|---|---|
| [asleep-sdk-react-native](https://github.com/asleep-ai/asleep-sdk-react-native) | fetched `origin/main` | `58ec6aa727d924aedc67bce196314aa7c5093ba6` | Current public contract reviewed as package `1.2.0`. The local checked-out `main` is older and has unrelated example changes, so it was not used as the current baseline. |
| [asleep-sdk-android-src](https://github.com/asleep-ai/asleep-sdk-android-src) | tag `v3.2.1` / `main` | `c22adc123a71a1b22ec6fecd7ad1153a169e9209` | Tagged version bundled by RN 1.2. |
| [asleep-sdk-android-src](https://github.com/asleep-ai/asleep-sdk-android-src) | local `feature/github-packages-publish` | `a58774fc2232822dc14575bf33ec59850ce6e22f` | Clean checkout. Contains merged 3.3 source and reports version `3.3.0`, but is not a 3.3 tag. |
| [asleep-sdk-ios-src](https://github.com/asleep-ai/asleep-sdk-ios-src) | `main`, tag `3.2.0` | `b9d3768006a6c15cd35deb352b73eababb3f14a9` | Clean checkout exactly at the 3.2.0 tag. |

The RN snapshot pins Android `ai.asleep:asleepsdk:3.2.1` and iOS
`AsleepSDK 3.2.0`. Its Android wrapper uses min SDK 24 and compile/target SDK 34;
its iOS podspec declares iOS 14. See the exact
[Android build file](https://github.com/asleep-ai/asleep-sdk-react-native/blob/58ec6aa727d924aedc67bce196314aa7c5093ba6/android/build.gradle)
and
[iOS podspec](https://github.com/asleep-ai/asleep-sdk-react-native/blob/58ec6aa727d924aedc67bce196314aa7c5093ba6/ios/Asleep.podspec).

## Native Version Policy

The first Flutter release must select one explicit native compatibility policy:

1. **Parity baseline:** Android 3.2.1 and iOS 3.2.0, matching RN 1.2.
   This conservative behavioral baseline is selected by the local draft.
2. **Forward Android baseline:** Android 3.3 plus iOS 3.2.0.
   This requires a verified, consumer-accessible 3.3 Android artifact and
   explicit documentation of features that remain Android-only.
3. **Version range:** unsupported until binary/source compatibility has been
   demonstrated across every included native version.

Do not use a dynamic native dependency. A Flutter release must pin exact native
versions and record them in the changelog and this matrix.

## Platform Compatibility

### Android

| Item | Current conservative value | Evidence / decision |
|---|---|---|
| Minimum API | 24 | Verified by the pinned 3.2.1 plugin compile and example build |
| Compile/target API | Flutter 3.44.8 generated values for the example | Final public build matrix remains required |
| Language/build | Kotlin/Gradle plugin scaffold | Exact supported AGP, Gradle, Kotlin, and Java ranges require a clean consumer build matrix |
| Foreground service | Required for tracking | Manifest must declare microphone foreground-service type |
| Runtime microphone | Required | Check and request are separate API calls |
| Notification permission | Android 13+ visibility concern | Denial must not be misreported as microphone denial |
| FGS microphone permission | Relevant on Android 14+ | Check using the platform API level where the permission exists |
| Battery exemption | Operational prerequisite | Request opens settings and does not guarantee the user changed the setting |
| Process restore | Supported by native service | Flutter adapter must reconnect callbacks after UI-process recreation |

The 3.3 source reports version `3.3.0` locally at
[Version.kt at the verified Android source commit](https://github.com/asleep-ai/asleep-sdk-android-src/blob/a58774fc2232822dc14575bf33ec59850ce6e22f/AsleepSDK/src/main/java/ai/asleep/asleepsdk/Version.kt#L5),
but the newest verified release tag in this checkout is `v3.2.1`. Source
availability is not proof of consumer artifact availability.

### iOS

| Item | Current conservative value | Evidence / decision |
|---|---|---|
| Minimum iOS | 15 | Follows the current iOS 3.2.0 native project and local plugin podspec |
| Native SDK | 3.2.0 | Local `main` equals tag `3.2.0` |
| Linking | CocoaPods static framework | Full pod lint and Swift compile verified with Xcode 26.6; no verified SPM distribution path |
| Microphone usage text | Required in consuming app | `NSMicrophoneUsageDescription` |
| Background mode | Required for overnight tracking | `UIBackgroundModes = audio` |
| Audio input | Built-in microphone | Native 3.2.0 source states Bluetooth microphone input is unsupported |
| Extra session options | Four verified options | `duckOthers`, `allowAirPlay`, `allowBluetooth`, `allowBluetoothA2DP` |
| Foreground recovery | Supported | `resumeTracking()` is iOS-only |
| Numeric errors | `error.errorCode.code` | Never use bridged `NSError.code` enum ordinal |

The native error accessor is documented in
[Asleep.Interface.swift at the verified iOS source commit](https://github.com/asleep-ai/asleep-sdk-ios-src/blob/b9d3768006a6c15cd35deb352b73eababb3f14a9/AsleepSDK/Asleep.Interface.swift#L471).

## Behavioral Compatibility With React Native 1.2

The Flutter SDK preserves these developer-facing contracts:

- one client/state source instead of parallel facades;
- immutable lifecycle state plus explicit events;
- setup/configuration, restore, battery check, permission check/request, then
  tracking;
- no permission dialog or application UI from `startTracking()`;
- `idle`, `tracking`, `paused`, and `recoveryRequired` tracking states;
- reports throw structured failures rather than returning null failure
  sentinels;
- empty report list remains valid data;
- portable analysis results arrive through an event;
- Android immediate analysis can additionally appear on the command result;
- iOS returns an acknowledgement before the analysis event;
- app-owned wall-clock duration, persistence, UI, analytics, and retry policy;
- explicit listener/client disposal.

Intentional Dart translations:

- `AsleepClient.state` replaces a React hook snapshot.
- `AsleepClient.states` replaces reactive hook/store subscription.
- `AsleepClient.events` replaces stringly event listeners.
- sealed Dart events and typed models replace public channel maps.
- `AnalysisRequest` makes the Android-result/iOS-ack distinction explicit.
- third-party application state packages are not runtime dependencies.

## Known Cross-Platform Gaps

| Capability | Android | iOS | Compatibility treatment |
|---|---|---|---|
| Persistent tracking restore | Foreground service can survive UI process | No equivalent persistent service in RN baseline | `RestoreResult` remains cross-platform; normally false on iOS |
| Battery optimization | Real system setting | Not applicable | iOS returns exempt |
| Foreground notification configuration | Required/supported | Not applicable | Nested Android option |
| Extra audio-session options | Not applicable | Supported | Nested iOS option |
| `resumeTracking` | Unsupported | Supported | Typed unsupported-platform failure |
| Interruption/resume callbacks | Not exposed by Android 3.2.1 RN wrapper | Supported | Events may be iOS-only |
| User-deleted callback | Not emitted by Android 3.2.1 RN wrapper | Supported | Do not promise Android delivery |
| Analysis command result | Full result and event | Ack, then event | `AnalysisRequest` plus event stream |
| Android 3.3 token auth/metadata/completion | New source APIs | No verified parity | Not in initial portable public surface |

## Serialization Compatibility

- JSON/date inputs from both platforms are normalized before model creation.
- Required model fields reject malformed payloads with a typed exception.
- Optional/unknown native fields remain forward-compatible.
- Native SDK numeric codes are retained separately from stable string codes.
- Swift enum ordinals are never exposed as authoritative numeric SDK codes.
- New native events are delivered as `UnknownNativeEvent` until the Dart API
  adds a typed event.

## Publication Metadata: UNKNOWN

The following values must not be guessed:

- final pub.dev package name and ownership;
- package version and stability promise;
- public repository URL and source visibility;
- homepage, issue tracker, documentation URL, topics, and funding metadata;
- copyright holder and approved license text;
- publishing organization and pub.dev automated-publishing identity;
- Maven/CocoaPods/SPM artifact coordinates intended for third-party consumers;
- whether native repositories and artifacts may be redistributed;
- support contact and security-reporting channel;
- supported Flutter/Dart lower bounds for the real consumer fleet;
- supported Android/iOS version matrix and deprecation policy.

The package uses the verified Asleep product homepage and an explicit
license-pending notice. A public repository URL, issue tracker, approved
license grant, and copyright holder remain release blockers.

## Release Blockers

A public package must not be published until all of the following are resolved:

1. Product/legal approval for package name, source visibility, license, and
   redistribution of both native SDKs.
2. A tagged and consumer-accessible Android artifact is selected. If Android
   3.3 is selected, a source branch and internal GitHub Packages change are not
   sufficient evidence of public availability.
3. iOS 3.2.0 artifact access has been proven locally by full pod lint, but must
   also be proven from a clean CI runner without developer-local credentials.
4. Native artifact credentials and repository configuration are documented
   without committing secrets.
5. The conservative Dart `^3.12.2` and Flutter `>=3.44.0` floors are internally
   consistent, but must be checked against the intended consumer fleet.
6. Android min/compile/target API, AGP, Gradle, Kotlin, and Java compatibility
   are verified in clean example builds.
7. iOS 15, Swift 5, static CocoaPods linking, and Swift compilation are locally
   verified. Clean example/CI verification and application capabilities remain.
8. Android cold-start, permission-denied, API 33 notification-denied, API 34
   foreground microphone, process-restore, and battery-setting paths are
   exercised on devices/emulators.
9. iOS cold-start, denied microphone, background tracking, interruption,
   foreground recovery, duplicate resume, and analysis-ack/event paths are
   exercised on a device.
10. Error-code fixtures prove iOS uses `error.errorCode.code` and Android uses
    the native callback code, including unknown-code fallback.
11. Package metadata, README, changelog, API docs, example, tests, and generated
    Pigeon code agree on the selected native versions.
12. The public repository, CI, signing, pub.dev publishing, and support process
    are explicitly authorized.

## Compatibility Verification Checklist

Before each release:

- record exact Flutter, Dart, Pigeon, Android SDK, iOS SDK, Xcode, CocoaPods,
  Gradle, AGP, Kotlin, and Java versions;
- run formatting, analysis, unit tests, serialization tests, and channel
  contract tests;
- build the Android and iOS examples from clean dependency caches;
- test cold start before warm start on both platforms;
- test one full tracking lifecycle and report retrieval on real devices;
- verify background and restore behavior;
- verify every permission path without pre-granted permissions;
- compare all native listener methods and error cases against the previous
  pinned versions;
- update `CONTRACT_MATRIX.md`, this document, and the changelog together;
- publish nothing until credentials, metadata, and legal blockers are closed.
