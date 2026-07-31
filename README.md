# Asleep SDK for Flutter

Experimental Android and iOS Flutter plugin for Asleep audio-based sleep
tracking.

> **EXPERIMENTAL — NOT RECOMMENDED FOR PRODUCTION USE**
>
> This `0.x` package is an early preview. APIs, behavior, platform
> requirements, and native SDK compatibility may change without notice.
> Deployment requires Asleep credentials and application review. App Store
> privacy readiness and unattended overnight tracking have not been certified
> for this release.

## Contract snapshot

| Layer | Experimental 0.1.0 baseline |
|---|---|
| React Native developer journey | `react-native-asleep` 1.2.0 |
| Android native artifact | `ai.asleep:asleepsdk:3.2.1` |
| iOS native artifact | `AsleepSDK` 3.2.0 |
| Flutter toolchain | Flutter 3.44.2 minimum; 3.44.8 current / Dart 3.12.2 |
| Minimum platforms | Android API 24 / iOS 15 |
| State surface | Immutable snapshot + `Future` commands + broadcast `Stream` |
| Transport | Pigeon 27.3.0, internal generated API |

## Developer journey

Create one client for the application owner that controls sleep tracking:

```dart
final asleep = AsleepClient();

final stateSubscription = asleep.states.listen((snapshot) {
  print(snapshot.trackingStatus);
  print(snapshot.isOnDeviceAnalysisEnabled);
});

final eventSubscription = asleep.events.listen((event) {
  switch (event) {
    case AnalysisResultEvent(:final result):
      print(result.id);
    case TrackingFailedEvent(:final error):
      print('${error.code}: ${error.numericCode}');
    default:
      break;
  }
});
```

Restore, initialize or reconnect, and check platform prerequisites:

```dart
final restore = await asleep.checkAndRestoreTracking();
if (restore.hasActiveSession) {
  await asleep.configure(
    const AsleepConfiguration(apiKey: 'provided-at-runtime'),
  );
} else {
  await asleep.initialize(
    const AsleepSetupOptions(
      apiKey: 'provided-at-runtime',
      enableOnDeviceAnalysis: true,
    ),
  );
}

final battery = await asleep.checkBatteryOptimization();

if (!battery.exempted) {
  // Call from an app-controlled user interaction, then recheck after return.
  await asleep.requestBatteryOptimizationExemption();
  return;
}

if (!await asleep.hasRequiredPermissions()) {
  // Call from an app-controlled user interaction.
  final granted = await asleep.requestRequiredPermissions();
  if (!granted) {
    // Render the app's permission-denied UI.
  }
}
```

Start and stop tracking:

```dart
await asleep.startTracking(
  const AsleepTrackingOptions(
    androidNotification: AndroidNotificationOptions(
      title: 'Sleep tracking',
      text: 'Monitoring sleep',
    ),
    iosAudioSessionOptions: <IosAudioSessionOption>[
      IosAudioSessionOption.allowBluetoothA2DP,
    ],
  ),
);

await asleep.stopTracking();
```

Dispose subscriptions and the client from the same application owner:

```dart
await stateSubscription.cancel();
await eventSubscription.cancel();
await asleep.dispose();
```

The state stream is broadcast and does not replay the current value. Read
`asleep.state` before subscribing when an immediate snapshot is required.

The native Asleep SDK is process-global. Exactly one Flutter engine may own it
at a time. The first engine that initializes or configures the SDK owns it until
that engine detaches with no unresolved native initialization attempt; another
engine receives an immediate native failure.

On iOS, each native setup phase and user-join/configuration phase has a
30-second completion bound. A timeout rejects the command with native code
`INITIALIZATION_TIMEOUT`; its details identify the timed-out phase as `setup`
or `configuration`. The client returns to an uninitialized state, but the
process-global native initialization lane remains quarantined until that
attempt delivers a terminal callback. A retry during that interval fails with
native code `INITIALIZATION_RECOVERY_REQUIRED`; retry after the terminal
callback is accepted. Attempt-specific native delegates prevent callbacks from
the timed-out attempt from completing or mutating a newer retry. If the native
SDK never delivers a terminal callback, restart the app process before
initializing again; detaching and creating another Flutter engine cannot safely
release an in-flight process-global native operation.

## Permissions and platform configuration

The plugin checks and requests permissions separately. `startTracking()` never
opens a permission dialog.

Android applications must declare:

- `android.permission.INTERNET`
- `android.permission.RECORD_AUDIO`
- `android.permission.FOREGROUND_SERVICE`
- `android.permission.FOREGROUND_SERVICE_MICROPHONE`

The plugin also declares `android.permission.POST_NOTIFICATIONS` for
foreground-notification visibility on Android 13 and later. Notification
denial does not mean microphone permission was denied and does not change the
return value of `requestRequiredPermissions()`.

Direct battery-optimization exemption is opt-in. The plugin does not inject
`android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` into consuming apps.
Without that declaration, `requestBatteryOptimizationExemption()` opens the
general battery-optimization settings. A consuming app may declare the direct
exemption permission only after confirming that its core function qualifies
under Google Play policy.

iOS applications must add `NSMicrophoneUsageDescription` and the `audio`
background mode. The Asleep iOS SDK configures and activates
`AVAudioSession.playAndRecord` for tracking and intentionally does not restore
the previous audio-session state. Applications must coordinate other audio
features accordingly. iOS process restoration is not supported; the iOS
restore result is always `false`.

The native Android artifact contains ARM device libraries only. Use an ARM64
device for tracking and on-device analysis; Intel Android emulators are not a
supported runtime target.

The native AsleepSDK 3.2.0 release is currently distributed through CocoaPods,
so this plugin cannot yet provide a complete Swift Package Manager dependency
chain.

The pinned AsleepSDK 3.2.0 CocoaPods artifact does not contain a privacy
manifest. This does not prevent pub.dev publication or the existing native SDK
from running, but applications remain responsible for App Store privacy
compliance. A future native SDK release should bundle its required-reason API
declarations directly.

## State and event semantics

`AsleepSnapshot` contains durable projected state. `AsleepEvent` contains
one-time native facts. Do not use the state stream as an event queue.

`AsleepSnapshot.isOnDeviceAnalysisEnabled` is the effective upload-analysis
policy. It becomes `true` only after `initialize()` successfully applies
`enableOnDeviceAnalysis: true`. Successful `configure()` and restoration
preserve the current value; a new client therefore remains in non-ODA mode
unless it first completes an ODA-enabled initialization. Failed setup,
failed configuration, and `dispose()` reset the value to `false`.

`TrackingStatus.paused` and `TrackingStatus.recoveryRequired` still describe a
live native session. On iOS, call `resumeTracking()` after the app returns to
the foreground when recovery is required. A successful subsequent upload is
the proof that recovery completed. Android probes and reconnects to the native
foreground service before native setup can replace the process context.

An `AsleepErrorCategory.recordingDead` failure means recording stopped while
the native session remains open. Call `stopTracking()` before starting another
session even though the projected tracking status is `idle`.

`requestAnalysis()` reflects a native platform difference:

- Android can return an immediate result after native retry processing.
- iOS returns an acknowledgement; the result arrives on `events` as
  `AnalysisResultEvent`.

The canonical cross-platform result path is the event stream.

`getReportList()` follows the native offset/limit APIs until the final partial
page, rather than silently truncating the range at 100 sessions.

## Error handling

Public commands fail with `AsleepException` for lifecycle, validation, and
native failures. For failures thrown by `AsleepClient`, `exception.error` is
the same `AsleepError` instance published through `AsleepSnapshot.error`.
Handle `exception.error.code` and `exception.error.category` for semantic
behavior, then inspect `numericCode` and `platformDetails` for native
diagnostics. Native case names and additional details remain in
`platformDetails`.

A successful command clears the error that was present when that command
started. It does not clear a newer delegate or event-stream error that arrived
while the command was pending. Similarly, a generic command rejection does not
replace a richer concurrent native event error; the richer error is published
and included in the thrown exception. Call `clearError()` only when the
application has acknowledged the current error. If native cleanup fails during
`dispose()`, the final snapshot and thrown exception still share the cleanup
error before the state stream closes. `clearError()` is an idempotent no-op
after disposal because the state stream is already closed.

Use semantic `AsleepError.code` before numeric fallback. The same numeric value
can have different historical meanings across platforms. On iOS,
`numericCode` is produced by the SDK's `error.errorCode.code` accessor, never a
Swift enum ordinal.

## Development

Regenerate the transport after editing `pigeons/asleep_messages.dart`:

```sh
flutter pub run pigeon --input pigeons/asleep_messages.dart
dart format lib/src/transport.g.dart
```

Run the Dart gates:

```sh
dart format --output=none --set-exit-if-changed lib test example/lib \
  example/test example/integration_test pigeons
flutter analyze
flutter test
(cd example && flutter test)
```

Native builds require network access to the public Asleep Android Maven and
iOS CocoaPods artifacts.

## CI and delivery

GitHub Actions runs Dart contracts on the minimum and current toolchains,
Android bridge tests and both example and clean-consumer APK builds, plus
CocoaPods validation and both example and clean-consumer iOS builds. Pushes to
`main` and manual runs retain the non-production example artifacts for seven
days.

Release tags must be signed, point to a commit contained in `main`, match the
package and changelog versions, and pass Dart, Android, iOS, archive, API, and
package-score validation. A successful automated publication is followed by
clean Android and iOS builds that resolve the exact hosted version before a
GitHub Release can be created. Maintainers can also run the `Hosted consumer`
workflow for an exact already-published version.

## Documentation, support, and security

- Read the generated [Flutter API reference][api-reference] and the
  [Asleep developer guide][developer-guide].
- For defects, integration questions, and feature requests, email
  [nocturne@asleep.ai][support-email] with the package, Flutter, Dart, native
  SDK, OS, and device versions; expected and actual behavior; a minimal
  reproduction; and redacted logs.
- Report suspected vulnerabilities privately to
  [nocturne@asleep.ai][security-email]. Include affected versions, impact,
  reproduction conditions, and a safe follow-up contact. Wait for a fix or an
  agreed disclosure date before publishing details.
- To propose a source contribution, first email
  [nocturne@asleep.ai][contribution-email]. The private repository may be
  shared after triage; a merged change does not guarantee an immediate release.

The package source repository and its issue tracker are currently private, so
they are intentionally omitted from public pub.dev metadata. The API reference
above is the canonical public Flutter documentation URL. Never send API keys,
access tokens, raw audio, sleep reports, user identifiers, signing material, or
other personal data through any intake route.

This experimental `0.x` package has no response-time SLA. Minor releases may
contain breaking changes; patch releases should remain compatible within their
minor line. Security fixes are provided for the latest published minor line.

## License

This package uses Asleep's proprietary SDK license. Use, modification, and
redistribution require authorization from Asleep.

[api-reference]: https://pub.dev/documentation/asleep_sdk_flutter/latest/
[developer-guide]: https://docs-en.asleep.ai/docs/quickstart
[support-email]: mailto:nocturne@asleep.ai?subject=%5Basleep_sdk_flutter%20support%5D%20
[security-email]: mailto:nocturne@asleep.ai?subject=%5Basleep_sdk_flutter%20security%5D%20
[contribution-email]: mailto:nocturne@asleep.ai?subject=%5Basleep_sdk_flutter%20contribution%5D%20
