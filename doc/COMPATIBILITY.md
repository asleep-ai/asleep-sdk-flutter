# Compatibility and Release Readiness

Verified on: 2026-07-30

## Status Summary

| Layer | Experimental 0.1.0 baseline | Publication status |
|---|---|---|
| Dart package | `asleep_sdk_flutter` 0.1.0 | Experimental public version selected; `asleep.ai` verified publisher exists; first publish has not been performed |
| Dart SDK | `^3.12.2` | Experimental floor matching the verified toolchain; broader consumer-fleet validation remains |
| Flutter | `>=3.44.0` | Experimental floor matching Dart 3.12.2; broader consumer-fleet validation remains |
| Android | API 24, pinned `ai.asleep:asleepsdk:3.2.1` | Kotlin compile, lint, merged-manifest policy, and 16 Android bridge tests pass on the current implementation |
| iOS | iOS 15, pinned `AsleepSDK` 3.2.0, CocoaPods-only | Existing commercial runtime baseline; wrapper pod lint and unsigned release build pass, with a native privacy-manifest follow-up |
| Source distribution | Private GitHub repository, public pub.dev archive | `.pubignore` excludes internal `doc/` and Pigeon schema files from the archive |
| License | Proprietary notice copied from the RN 1.2 package | Release owner approved applying the existing Asleep notice to this Flutter archive on 2026-07-30 |

This repository contains the experimental 0.1.0 implementation candidate. It
is not yet published, and the experimental label does not waive the legal,
archive-review, release-CI, or runtime-QA gates below.

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

The experimental 0.1.0 release selects the conservative parity baseline:
Android 3.2.1 and iOS 3.2.0, matching RN 1.2.

Future releases may consider:

1. **Forward Android baseline:** Android 3.3 plus iOS 3.2.0.
   This requires a verified, consumer-accessible 3.3 Android artifact and
   explicit documentation of features that remain Android-only.
2. **Version range:** unsupported until binary/source compatibility has been
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
| Process restore | Supported by native service | The plugin probes `isSleepTrackingAlive` before setup/configuration can set the process-global context, then rechecks liveness and reconnects the listener during restore |

The 3.3 source reports version `3.3.0` locally at
[Version.kt at the verified Android source commit](https://github.com/asleep-ai/asleep-sdk-android-src/blob/a58774fc2232822dc14575bf33ec59850ce6e22f/AsleepSDK/src/main/java/ai/asleep/asleepsdk/Version.kt#L5),
but the newest verified release tag in this checkout is `v3.2.1`. Source
availability is not proof of consumer artifact availability.

### iOS

| Item | Current conservative value | Evidence / decision |
|---|---|---|
| Minimum iOS | 15 | Follows the current iOS 3.2.0 native project and local plugin podspec |
| Native SDK | 3.2.0 | Local `main` equals tag `3.2.0` |
| Linking | CocoaPods static framework | Native `AsleepSDK` 3.2.0 has no verified consumer-accessible Swift Package Manager artifact |
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
- report lists page through both native APIs until the first partial page
  instead of inheriting a single-page cap;
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
| Persistent tracking restore | Foreground service can survive UI process; the plugin performs a pre-setup liveness probe and later reconnects the listener | No process-persistent service; the bridge returns `false` | Only Android can project a restored tracking session |
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

AsleepSDK iOS 3.2.0 retains a session ID after close, so that identifier cannot
prove that tracking is active. The iOS bridge therefore returns
`hasActiveSession: false` instead of inventing a restorable session. A future
native SDK can add iOS restoration only after it exposes an explicit active
session signal.

## Publication Metadata

The selected values are:

- package `asleep_sdk_flutter` version 0.1.0;
- experimental `0.x` stability policy;
- verified publisher `asleep.ai`;
- Android 3.2.1 and iOS 3.2.0 native dependencies;
- Android API 24, iOS 15, Dart `^3.12.2`, and Flutter `>=3.44.0` experimental
  floors.

The following values remain unresolved and must not be guessed:

- public source repository and issue tracker URLs; the current private GitHub
  URLs are intentionally omitted from public package metadata;
- documentation URL, final topics, and funding metadata;
- whether native repositories and artifacts may be redistributed;
- support contact and security-reporting channel;
- long-term platform support and deprecation policy.

The package uses the verified Asleep product homepage, conservative topics, and
the proprietary notice already used by the RN 1.2 package. The release owner
approved applying that notice to the Flutter archive on 2026-07-30. Private
source and issue URLs must not be published as broken public links.

## Release Blockers

A public package must not be published until all of the following are resolved:

1. Product approval for public source distribution and external use of both
   native SDK dependency paths.
2. Recheck Android 3.2.1 and iOS 3.2.0 from clean release-CI
   runners without developer-local credentials.
3. Confirm public support, issue, security, and source links.
4. Inspect the final `.pubignore` archive and run the package, credential, and
   license gates from the exact release commit.
5. Android cold-start, permission-denied, API 33 notification-denied, API 34
   foreground microphone, process-restore, and battery-setting paths are
   exercised on devices/emulators.
6. iOS cold-start, denied microphone, background tracking, interruption,
   foreground recovery, duplicate resume, and analysis-ack/event paths are
   exercised on a device.
7. Error-code fixtures prove iOS uses `error.errorCode.code` and Android uses
   the native callback code, including unknown-code fallback.
8. Package metadata, README, changelog, API docs, example, tests, and generated
    Pigeon code agree on the selected native versions.
9. CI, signing, pub.dev publishing, and support processes are explicitly
    authorized.

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
- publish nothing until credentials, metadata, legal blockers, release CI, and
  the approved runtime QA scope are closed.
