# Asleep SDK for Flutter

Local development draft of an Android and iOS Flutter plugin for Asleep
audio-based sleep tracking.

> This package is not ready for publication. Package ownership, license,
> native artifact access, and the final compatibility policy are unresolved.
> `publish_to: none` prevents accidental `pub.dev` publication.

## Contract snapshot

| Layer | Draft baseline |
|---|---|
| React Native developer journey | `react-native-asleep` 1.2.0, `origin/main` at `58ec6aa` |
| Android native artifact | `ai.asleep:asleepsdk:3.2.1` |
| iOS native artifact | `AsleepSDK` 3.2.0 |
| Flutter tool used for generation | Flutter 3.44.8 / Dart 3.12.2 |
| Minimum platform draft | Android API 24 / iOS 15 |
| State surface | Immutable snapshot + `Future` commands + broadcast `Stream` |
| Transport | Pigeon 27.3.0, internal generated API |

See [the contract matrix](doc/CONTRACT_MATRIX.md) for the source-level
comparison and [compatibility notes](doc/COMPATIBILITY.md) before integrating.
See [the distribution contract](doc/DISTRIBUTION.md) before creating a tag or
removing `publish_to: none`.

## Developer journey

Create one client for the application owner that controls sleep tracking:

```dart
final asleep = AsleepClient();

final stateSubscription = asleep.states.listen((snapshot) {
  print(snapshot.trackingStatus);
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

Initialize, restore, and check platform prerequisites:

```dart
await asleep.initialize(
  const AsleepSetupOptions(
    apiKey: 'provided-at-runtime',
    enableOnDeviceAnalysis: true,
  ),
);

final restore = await asleep.checkAndRestoreTracking();
final battery = await asleep.checkBatteryOptimization();

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
that engine detaches; another engine receives an immediate native failure.

## Permissions and platform configuration

The plugin checks and requests permissions separately. `startTracking()` never
opens a permission dialog.

Android applications must declare:

- `android.permission.INTERNET`
- `android.permission.RECORD_AUDIO`
- `android.permission.FOREGROUND_SERVICE`
- `android.permission.FOREGROUND_SERVICE_MICROPHONE`
- `android.permission.POST_NOTIFICATIONS` for notification visibility on
  Android 13 and later

iOS applications must add `NSMicrophoneUsageDescription` and the `audio`
background mode. The Asleep iOS SDK configures and activates
`AVAudioSession.playAndRecord` for tracking and intentionally does not restore
the previous audio-session state. Applications must coordinate other audio
features accordingly.

## State and event semantics

`AsleepSnapshot` contains durable projected state. `AsleepEvent` contains
one-time native facts. Do not use the state stream as an event queue.

`TrackingStatus.paused` and `TrackingStatus.recoveryRequired` still describe a
live native session. On iOS, call `resumeTracking()` after the app returns to
the foreground when recovery is required. Android process restoration reconnects
to the native foreground service.

`requestAnalysis()` reflects a native platform difference:

- Android can return an immediate result after native retry processing.
- iOS returns an acknowledgement; the result arrives on `events` as
  `AnalysisResultEvent`.

The canonical cross-platform result path is the event stream.

## Error handling

Public commands fail with `AsleepException` for Dart lifecycle and validation
errors or a platform exception for native failures. Tracking and setup delegate
failures are projected as typed events and `AsleepSnapshot.error`.

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

Native builds require access to the Asleep Android and iOS artifacts. See
[compatibility notes](doc/COMPATIBILITY.md) for the exact unresolved boundary.

## CI and delivery

GitHub Actions runs Dart contracts, Android bridge tests and an example APK
build, plus CocoaPods validation and an iOS simulator build. Pushes to `main`
and manual runs retain the non-production example artifacts for seven days.

This internal delivery path does not publish to pub.dev, create a GitHub
release, produce a production/device-signed build, or embed an API key. Public
publishing remains disabled until the compatibility and legal blockers are
resolved.

Release-candidate tags run validation. The pub.dev OIDC and generated-notes
GitHub Release jobs remain skipped unless maintainers explicitly set
`PUBDEV_PUBLISH_ENABLED=true` or `RELEASE_CREATION_ENABLED=true`. Both variables
must remain unset before their corresponding approvals.

## Documentation

- [Implementation plan and success criteria](doc/IMPLEMENTATION_PLAN.md)
- [Architecture](doc/ARCHITECTURE.md)
- [State model ADR](doc/adr/0001-state-model.md)
- [Platform transport ADR](doc/adr/0002-platform-transport.md)
- [Contract matrix](doc/CONTRACT_MATRIX.md)
- [Compatibility and release blockers](doc/COMPATIBILITY.md)
- [Verification record](doc/VERIFICATION.md)
- [React Native migration map](doc/MIGRATION.md)
- [Distribution and release contract](doc/DISTRIBUTION.md)
