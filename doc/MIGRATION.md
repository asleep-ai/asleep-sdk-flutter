# Migration from `react-native-asleep`

This document maps the React Native 1.2 developer journey to experimental
Flutter 0.1.0. It is not a promise of one-to-one naming compatibility.

| React Native 1.2 | Flutter 0.1.0 | Notes |
|---|---|---|
| `useAsleep()` | `AsleepClient.state`, `states`, `events` | Flutter does not expose a React-shaped hook or third-party store. |
| `Asleep.initialize()` | Construct one `AsleepClient`; check restoration, then call `initialize()` or `configure()` | Dispose the client when its application owner is destroyed. |
| `setup(config)` | `initialize(AsleepSetupOptions)` | The future completes after native setup and configuration are ready; progress and the projected lifecycle remain event-driven. |
| `initAsleepConfig(config)` | `configure(AsleepConfiguration)` | Use when the user-oriented configuration path is required. |
| `checkAndRestoreTracking()` | Same name | Call before initialization. Configure a surviving Android session; otherwise initialize a fresh session. iOS returns no process-persistent session. |
| `hasRequiredPermissions()` | Same name | This check never opens a system dialog. |
| `requestRequiredPermissions()` | Same name | Call only from an application-controlled user interaction. |
| `startTracking(config)` | `startTracking(options)` | Throws `permissionRequired`; it never requests permission automatically. |
| `resumeTracking()` | Same name | iOS-only recovery operation. |
| `requestAnalysis()` | Same name plus `AnalysisRequest` | Immediate Android data is `immediateResult`; canonical results also arrive as `AnalysisResultEvent`. |
| `getReportList(fromDate, toDate)` | Same name | Flutter pages both native report APIs until the first partial page and returns the complete aggregate list. |
| `useAsleep().trackingStatus` | `AsleepSnapshot.trackingStatus` | `paused` and `recoveryRequired` still represent a live native session. |
| `addEventListener()` | `events.listen()` | Cancel the Dart subscription or dispose the client. |
| `Asleep.subscribe()` | `states.listen()` | Read `state` first when the current value is needed; broadcast streams do not replay. |
| `clearError()` | Same name | Clears only the projected Dart snapshot. |

## Error migration

Use `AsleepError.code` for stable semantic handling and
`AsleepError.numericCode` for native diagnostics. The Flutter bridge maps iOS
numeric errors through `error.errorCode.code`. It does not treat Swift enum
ordinals or `NSError.code` as stable SDK error codes.

Unknown semantic codes, categories, and native fields are retained instead of
causing exhaustive enum decoding to fail.

## State ownership

Product workflow, alarms, persistence, analytics, retry policy, and UI remain
application concerns. Adapt `AsleepClient.states` at the application boundary
to Riverpod, Bloc, signals, ChangeNotifier, or another application architecture
if needed.
