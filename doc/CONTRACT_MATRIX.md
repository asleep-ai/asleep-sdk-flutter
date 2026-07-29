# Asleep Flutter SDK Contract Matrix

Verified on: 2026-07-29

## Contract Baselines

| Source | Verified snapshot | Role in this package |
|---|---|---|
| [React Native SDK](https://github.com/asleep-ai/asleep-sdk-react-native/tree/58ec6aa727d924aedc67bce196314aa7c5093ba6) | `origin/main` at `58ec6aa727d924aedc67bce196314aa7c5093ba6`; package `1.2.0` | Primary developer journey, public state, error, event, and result semantics |
| [Android SDK 3.2.1](https://github.com/asleep-ai/asleep-sdk-android-src/tree/c22adc123a71a1b22ec6fecd7ad1153a169e9209) | `main` at `c22adc123a71a1b22ec6fecd7ad1153a169e9209`; tag `v3.2.1` | Native version bundled by the React Native baseline |
| [Current Android 3.3 source](https://github.com/asleep-ai/asleep-sdk-android-src/tree/a58774fc2232822dc14575bf33ec59850ce6e22f) | `feature/github-packages-publish` at `a58774fc2232822dc14575bf33ec59850ce6e22f`; contains merged 3.3 work and reports `3.3.0`, but has no 3.3 release tag | Forward-compatibility review only; not yet a safe published dependency baseline |
| [iOS SDK 3.2.0](https://github.com/asleep-ai/asleep-sdk-ios-src/tree/b9d3768006a6c15cd35deb352b73eababb3f14a9) | `main` at `b9d3768006a6c15cd35deb352b73eababb3f14a9`; tag `3.2.0` | Native version bundled by the React Native baseline |

The local React Native checkout is on an older `main` worktree at `v1.0.18`.
This document therefore cites the verified `origin/main` commit by URL rather
than treating the local worktree as the current public contract.

## Developer Journey

The Flutter API translates the React Native v1.2 journey without copying its
React-specific hook:

1. Create one `AsleepClient`.
2. Call `initialize(AsleepSetupOptions)` for setup/ODA, or
   `configure(AsleepConfiguration)` for normal configuration.
3. Call `checkAndRestoreTracking()` at application startup.
4. Call `checkBatteryOptimization()`.
5. Call `hasRequiredPermissions()` without showing UI.
6. From a user-initiated flow, call `requestRequiredPermissions()` if required.
7. Call `startTracking()`.
8. Observe immutable `state`, broadcast `states`, and typed `events`.
9. Call `stopTracking()` and query reports.
10. Call `dispose()` to detach native event subscriptions and close streams.

Exactly one Flutter engine may own the process-global native Asleep SDK.
Concurrent initialization from another engine fails immediately and does not
replace the active engine's native listeners.

The SDK is headless. Applications own permission explanation UI, alarms,
retry policy, persistence, authentication beyond native SDK configuration,
analytics, wall-clock tracking duration, and product-specific state management.

## Public Command Matrix

| Flutter command | React Native v1.2 contract | Android native contract | iOS native contract | Flutter contract |
|---|---|---|---|---|
| `initialize(options)` | `setup(apiKey, baseUrl?, callbackUrl?, service?, enableODA?)` | Setup listener emits progress, completion, or numeric failure. Android 3.3 additionally has an app ID/app secret overload; it is not exposed in this initial Flutter surface. | `Asleep.setup` takes the same API-key fields and a delegate. | Completes only after setup and native configuration managers are ready. Progress and the authoritative projected lifecycle remain available through `SetupCompletedEvent` and `state.setupStatus`. |
| `configure(configuration)` | `initAsleepConfig(apiKey, userId?, baseUrl?, callbackUrl?)` | Callback returns `userId` and `AsleepConfig`; the wrapper creates reports from the config. | Delegate returns `userId` and `Asleep.Config`; the wrapper creates tracking and report managers. | Returns `Future<void>`; joined user identity is delivered through `UserJoinedEvent` and state. |
| `checkAndRestoreTracking()` | Probe service, reconnect only on Android, return `{hasActiveSession}`. | `isSleepTrackingAlive(context)` plus `connectSleepTracking(listener)` reconnects to the foreground-service process. | No persistent Android-style service; the RN wrapper returns `false`. | Returns `RestoreResult`. A true result projects `TrackingStatus.tracking`. |
| `checkBatteryOptimization()` | Required before start on both platforms for a uniform journey. | Uses `PowerManager.isIgnoringBatteryOptimizations`. | Not applicable. | Returns `BatteryOptimizationStatus`; iOS resolves `exempted: true`. |
| `requestBatteryOptimizationExemption()` | Opens Android settings; iOS is a successful no-op. | Returns `true` when already exempt, `false` after opening settings. | Not applicable. | Returns `Future<bool>` with the same meaning. It does not wait for the user to change the setting. |
| `hasRequiredPermissions()` | Non-interactive check. | Requires `RECORD_AUDIO`; API 34+ foreground microphone service requirements must also be satisfied. | Checks microphone recording permission. | Returns `Future<bool>` and never opens UI. |
| `requestRequiredPermissions()` | Explicit request, separate from start. | Requests microphone permission. Android 13+ notification permission affects foreground-notification visibility, not whether audio tracking can run. | Requests microphone permission. | Returns whether tracking-required permission is granted. Notification denial must not be reported as microphone denial. |
| `startTracking(options)` | Rejects missing prerequisites and permissions; does not request permission. | Starts foreground-service tracking with title, text, and icon notification options. | Starts the tracking manager with additional audio-session options. | Returns `Future<void>`; session identity and authoritative start are event-driven. |
| `resumeTracking()` | iOS-only foreground recovery command. | Unsupported. | Calls `SleepTrackingManager.resumeTracking()`. | Allowed only for `paused` or `recoveryRequired`; otherwise rejects with a typed exception. |
| `stopTracking()` | Ends current tracking and eventually closes the session. | Calls `endSleepTracking`; close callback supplies session ID. | Calls `SleepTrackingManager.stopTracking()`. | Returns `Future<void>`; `TrackingClosedEvent` is the authoritative close signal. |
| `requestAnalysis()` | Android may return a result immediately; iOS returns an acknowledgement and emits the result later. | `getCurrentSleepData` resolves a session and emits it. | `requestAnalysis()` is fire-and-event; the RN wrapper synthesizes `{status: requested, timestamp}`. | Returns `AnalysisRequest(status, timestamp?, immediateResult?)`; consumers must observe `AnalysisResultEvent` for the portable result path. |
| `getReport(sessionId)` | Throws on failure or missing report; no null failure sentinel. | Callback returns serialized `Report`. | Async reports API returns an encodable report. | Returns typed `AsleepReport`; malformed or absent data rejects. |
| `getReportList(fromDate, toDate)` | Empty list is valid; failures throw. Limit is 100 in the RN wrapper. | Callback returns `List<SleepSession>?`. | Async reports API returns `[SleepSession]`. | Returns `List<AsleepSession>` with normalized identifiers and dates. |
| `getAverageReport(fromDate, toDate)` | Throws on failure or absent payload. | Callback returns `AverageReport?`. | Async reports API returns encodable average report. | Returns typed `AsleepAverageReport`. |
| `deleteSession(sessionId)` | Native success payloads are discarded. | Callback success may include a string/session ID. | Async delete returns no value. | Returns `Future<void>`. |
| `setLoggingEnabled(enabled)` | Enables opt-in wrapper/native logs. | Wrapper logging is callback-based. | Logger forwarding is gated before crossing the bridge. | Returns `Future<void>`; debug text is exposed only through `DebugLogEvent`. |
| `clearError()` | Clears the projected error only. | No native call. | No native call. | Synchronous state operation. |
| `dispose()` | RN uses ref-counted listener teardown. | Detaches Flutter channel/event resources; must not stop tracking implicitly. | Detaches Flutter channel/event resources; must not stop tracking implicitly. | Idempotent. It closes client-owned streams and rejects subsequent commands. |

The React Native native-wrapper method names and payloads are visible in
[its current iOS adapter](https://github.com/asleep-ai/asleep-sdk-react-native/blob/58ec6aa727d924aedc67bce196314aa7c5093ba6/ios/AsleepModule.swift)
and
[Android adapter](https://github.com/asleep-ai/asleep-sdk-react-native/blob/58ec6aa727d924aedc67bce196314aa7c5093ba6/android/src/main/java/ai/asleep/reactnative/AsleepModule.kt).

## State Contract

`AsleepSnapshot` is an immutable projection of native facts.

| State | Meaning |
|---|---|
| `setupStatus` | `idle`, `inProgress`, or `complete` |
| `trackingStatus` | `idle`, `tracking`, `paused`, or `recoveryRequired` |
| `isTracking` | True for every tracking status except `idle`; a recovery-required session is still live |
| `userId` / `sessionId` | Current identifiers reported by native callbacks |
| `analysisResult` | Most recent normalized analysis event |
| `error` | Most recent structured `AsleepError`, or null |
| `didClose` | Whether the last observed terminal lifecycle transition closed the session |
| `batteryOptimizationChecked` | Whether the prerequisite check has run in this client |

The runtime package exposes Dart `Stream` and immutable values only. It does not
depend on Riverpod, Bloc, Signals, or another application state framework.

## Event Matrix

| Flutter event | Native payload | Platform behavior |
|---|---|---|
| `TrackingCreatedEvent` | Optional `sessionId` | Android supplies the ID from `onStart`. iOS may emit creation before the ID becomes observable, so it remains optional. |
| `TrackingUploadedEvent` | `sequence` | Both platforms. This is progress, not a report-completion signal. |
| `TrackingClosedEvent` | `sessionId` | Both platforms. Android native may provide null; the wrapper must reject or normalize deliberately rather than silently inventing identity. |
| `TrackingFailedEvent` | Structured `AsleepError` | Both platforms. Error category determines whether tracking is dead, recoverable, or unchanged. |
| `TrackingInterruptedEvent` | Unit/empty payload | iOS callback; Android 3.2.1 does not provide equivalent interruption callbacks. |
| `TrackingResumedEvent` | Unit/empty payload | iOS callback. Duplicate native resume notifications must not produce contradictory state. |
| `MicrophonePermissionDeniedEvent` | Unit/empty payload | iOS callback; Android permission rejection is primarily command-based. |
| `UserJoinedEvent` | `userId` | Both platforms after configuration. |
| `UserJoinFailedEvent` | Structured `AsleepError` | Android supplies numeric code/detail; iOS supplies `AsleepError`. |
| `UserDeletedEvent` | `userId` | iOS exposes the callback. Android 3.2.1 RN wrapper declares but does not emit it. |
| `SetupCompletedEvent` | Unit/empty payload | Both platforms. |
| `SetupFailedEvent` | Structured `AsleepError` | Both platforms. |
| `SetupProgressEvent` | Numeric progress | Both platforms; treated as percentage-like progress, without assuming an undocumented range beyond observed 0-100 use. |
| `AnalysisResultEvent` | Normalized `AsleepAnalysisResult` | Portable analysis result path on both platforms. |
| `DebugLogEvent` | `message` | Opt-in diagnostic text. It is not an error channel. |
| `UnknownNativeEvent` | Original type and map payload | Forward-compatible fallback for new native callbacks. |

## Serialization and Result Semantics

- Native maps are normalized recursively from snake case to Dart field names.
- Android Gson payloads and iOS `JSONEncoder` payloads must produce the same
  public Dart models.
- Dates are parsed as ISO-8601. The iOS analysis acknowledgement timestamp is
  milliseconds since the Unix epoch.
- Report-list aliases are normalized:
  `sessionId -> id`, `sessionStartTime -> startTime`, and
  `sessionEndTime -> endTime`.
- Empty report lists are valid. Query failure, a missing single report, and a
  malformed required field are errors.
- Unknown fields are ignored or retained in explicit raw/platform-detail maps;
  unknown enum-like values must not crash event delivery.
- There is no native per-command cancellation contract in the verified
  baselines. Cancelling a Dart `Future` must not be advertised. `dispose()`
  cancels subscriptions only.

## Permissions, Audio, and Background Ownership

### Android

- The application/library manifest needs internet, record-audio, foreground
  service, foreground-service microphone, notification, and battery-exemption
  declarations appropriate to the selected native artifact.
- Tracking runs in a foreground-service process and can survive an application
  UI process restart. Restore must reconnect the listener.
- Notification title, text, and icon belong to each tracking start.
- Battery exemption is a reliability prerequisite for an overnight session.
- Android 3.3 adds token authentication, additional tracking overloads,
  configurable notification objects, recording paths, completion polling, and
  metadata APIs. These are not silently added to the initial cross-platform
  Flutter contract because iOS/RN parity and a published 3.3 dependency are not
  yet established. See
  [Android 3.3 authentication](https://github.com/asleep-ai/asleep-sdk-android-src/blob/a58774fc2232822dc14575bf33ec59850ce6e22f/docs/SDK_3.3.0.md#L23)
  and
  [Android 3.3 tracking changes](https://github.com/asleep-ai/asleep-sdk-android-src/blob/a58774fc2232822dc14575bf33ec59850ce6e22f/docs/SDK_3.3.0.md#L276).

### iOS

- The consuming application must provide
  `NSMicrophoneUsageDescription` and the `audio` background mode.
- The SDK owns its recording `AVAudioSession` lifecycle while tracking.
- `iosAudioSessionOptions` are additive options:
  `duckOthers`, `allowAirPlay`, `allowBluetooth`, and
  `allowBluetoothA2DP`.
- The verified native source explicitly states that tracking uses the built-in
  microphone; Bluetooth microphone input is not supported. See
  [the verified native interface](https://github.com/asleep-ai/asleep-sdk-ios-src/blob/b9d3768006a6c15cd35deb352b73eababb3f14a9/AsleepSDK/SleepTrackingManager/Asleep.SleepTrackingManager.Interface.swift#L11).
- `cannotActivateInBackground` leaves a live session that requires an explicit
  foreground `resumeTracking()`. A later successful upload is stronger recovery
  evidence than an early/duplicate resume callback.

## Error Semantics

`AsleepError` contains:

- stable string `code`;
- human-readable `message`;
- objective `category`;
- official native `numericCode`, when available;
- raw `platformDetails` for diagnostics and forward compatibility.

| Category | Native fact | Required state treatment |
|---|---|---|
| `terminal` | Native session is gone and a close callback may not follow | Move to idle and mark closed |
| `recordingDead` | Recorder is gone; session cleanup/restart is required | Move to idle without claiming a normal close |
| `recoveryRequired` | Session is live but needs foreground recovery | Keep `isTracking` true and expose `recoveryRequired` |
| `transient` | Session survived the failure | Preserve tracking state |
| `unknown` | Recovery semantics are not classified | Preserve raw details and avoid assuming safety |

On iOS, never use `(error as NSError).code` as the public numeric SDK code.
Swift enum bridging yields a declaration ordinal that can change when cases are
reordered. Use `error.errorCode.code`, the native SDK's documented accessor.
The accessor and migration guidance are implemented at
[the verified iOS source commit](https://github.com/asleep-ai/asleep-sdk-ios-src/blob/b9d3768006a6c15cd35deb352b73eababb3f14a9/AsleepSDK/Asleep.Interface.swift#L471).

Android error callbacks already provide the native numeric code. Semantic string
classification must win over a colliding platform number; the same number can
represent different platform facts.

## Android 3.2.1 Versus Current 3.3 Source

| Area | RN-bundled Android 3.2.1 | Current 3.3 source | Initial Flutter decision |
|---|---|---|---|
| Distribution baseline | Tagged `v3.2.1` | Source reports `3.3.0`, 69 commits after `v3.2.1`, no verified 3.3 release tag | Pinning remains blocked pending artifact decision |
| Authentication | API key | API key plus app ID/app secret token flow | Expose API key only initially |
| Tracking listener | Existing FGS listener | Adds completable listener/overloads | Preserve common lifecycle events only |
| Completion | Close callback/report query | Optional COMPLETE polling, 30-second timeout, code `28000` | Do not imply completion polling until adopted explicitly |
| Notification | Individual fields | Adds `AsleepNotificationConfig` | Keep typed title/text/icon options |
| Recording files/metadata | Not in RN public contract | New recording-manager and metadata APIs | Out of initial public scope |
| Build target | RN wrapper compiles/targets API 34 | 3.3 document reports target/compile API 35 | Decide with the selected artifact before release |
