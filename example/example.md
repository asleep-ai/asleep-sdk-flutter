# Production integration guide

This guide is the canonical Flutter integration path for
`asleep_sdk_flutter`. The package is experimental: qualify every target device,
review the native platform requirements, and use a non-production account while
building the integration.

The bundled diagnostic app implements the public lifecycle described here. Run
it from the package checkout with:

```sh
cd example
flutter run
```

## Ownership model

Create exactly one `AsleepClient` for the Flutter engine that owns sleep
tracking. That application-level owner also owns both stream subscriptions and
disposes all three resources. Do not create a client in each screen or provider.
The native SDK is process-global, while Flutter widgets are not.

```dart
final client = AsleepClient();
final current = client.state;

final stateSubscription = client.states.listen((snapshot) {
  // Render durable state. Persist only app data that your policy permits.
});
final eventSubscription = client.events.listen(
  (event) {
    // Handle one-time facts. Never treat this stream as durable state.
  },
  onError: (Object error, StackTrace stackTrace) {
    // Render only a mapped code/category from client.state.error.
    // Never retain or display the raw stream error or native details.
    renderRedactedEventError(client.state.error);
  },
);
```

Read `client.state` as the immediate snapshot. The broadcast `states` stream
does not replay the current value to a new subscriber.

Keep the API key in memory only long enough to pass it to `initialize()` or
`configure()`. Do not write it to preferences, analytics, crash reports, debug
logs, or widget labels.

## Startup order

Subscribe before issuing commands so early setup and restoration events cannot
be missed. Then use this order:

1. Read `client.state` and attach `states` and `events`.
2. Call `checkAndRestoreTracking()`.
3. If Android reports an active session, call `configure()` with runtime
   credentials. Otherwise call `initialize()`.
4. Call `checkBatteryOptimization()`.
5. Check permissions without opening UI.
6. Request permissions or open Android battery settings only from an explicit
   user action.

```dart
Future<void> prepareSdk(AsleepClient client, String runtimeApiKey) async {
  final restore = await client.checkAndRestoreTracking();
  if (restore.hasActiveSession) {
    await client.configure(
      AsleepConfiguration(apiKey: runtimeApiKey),
    );
  } else {
    await client.initialize(
      AsleepSetupOptions(
        apiKey: runtimeApiKey,
        enableOnDeviceAnalysis: true,
      ),
    );
  }

  await client.checkBatteryOptimization();
}
```

`initialize()` and `configure()` perform a defensive native restoration
preflight as well. The explicit first check is still required because it
selects the correct public setup path and makes the app's decision observable.

## State, events, and structured failures

`AsleepSnapshot` is durable projected state. `AsleepEvent` is an ordered,
one-time native fact:

```dart
bool recordingDeadCleanupRequired = false;

void handleSnapshot(AsleepSnapshot snapshot) {
  final canStop = snapshot.isTracking || recordingDeadCleanupRequired;
  // Drive buttons and status UI from snapshot and canStop.
}

void handleEvent(AsleepEvent event) {
  switch (event) {
    case TrackingUploadedEvent():
      // Upload progress, and iOS foreground-recovery proof when applicable.
      handleUploadProgress();
    case AnalysisResultEvent(:final result):
      // Canonical cross-platform analysis result.
      consumeAnalysis(result);
    case TrackingClosedEvent():
      recordingDeadCleanupRequired = false;
      // One-time close fact; durable status is also present in the snapshot.
    case TrackingFailedEvent(:final error):
      if (error.category == AsleepErrorCategory.recordingDead) {
        // Keep cleanup required even if a later command clears snapshot.error.
        recordingDeadCleanupRequired = true;
      } else if (error.category == AsleepErrorCategory.terminal) {
        recordingDeadCleanupRequired = false;
      }
    case DebugLogEvent():
      // Do not render, persist, or forward raw diagnostic text.
    default:
      break;
  }
}
```

Do not derive recording-dead cleanup solely from `snapshot.error`. A successful
unrelated command may clear that error, while the native session still requires
`stopTracking()`. Keep the application latch until `TrackingClosedEvent` or a
terminal failure proves the session ended. A successful stop request alone is
not close proof.

Public command failures are `AsleepException`. For client command failures,
`exception.error` is the same `AsleepError` instance published in
`client.state.error`:

```dart
try {
  await client.startTracking();
} on AsleepException catch (exception) {
  final error = exception.error;
  if (error == null) {
    renderGenericFailure();
    return;
  }

  switch (error.category) {
    case AsleepErrorCategory.transient:
      offerUserControlledRetry();
    case AsleepErrorCategory.recoveryRequired:
      renderForegroundRecoveryRequired();
    case AsleepErrorCategory.recordingDead:
      renderStopRequired();
    case AsleepErrorCategory.terminal:
      renderSessionEnded();
    case AsleepErrorCategory.unknown:
      renderGenericFailure();
  }
}
```

Use `error.code` and `error.category` for behavior. Restrict
`numericCode` and `platformDetails` to protected diagnostics; they may contain
native context that does not belong in user-visible text or analytics.

Do not automatically retry lifecycle commands. A retry can duplicate a start,
resume, stop, or destructive report operation. The application owns retry
policy and should retry only known transient failures, with bounded attempts
and an explicit current-state check.

## Permissions and Android battery settings

Checking and requesting permissions are separate operations. `startTracking()`
never opens a permission dialog:

```dart
final granted = await client.hasRequiredPermissions();
if (!granted) {
  // Invoke only from a user action that explains why recording is needed.
  final accepted = await client.requestRequiredPermissions();
  if (!accepted) {
    renderPermissionHelp();
  }
}
```

Android consumers must declare:

- `android.permission.INTERNET`
- `android.permission.RECORD_AUDIO`
- `android.permission.FOREGROUND_SERVICE`
- `android.permission.FOREGROUND_SERVICE_MICROPHONE`

The plugin declares `POST_NOTIFICATIONS` for Android 13 and later.
Notification denial and microphone denial are different states. The
foreground-service notification is app-configurable when tracking starts:

```dart
await client.startTracking(
  const AsleepTrackingOptions(
    androidNotification: AndroidNotificationOptions(
      title: 'Sleep tracking',
      text: 'Monitoring sleep',
    ),
  ),
);
```

Battery optimization is also a separate, Android-owned settings journey:

```dart
final before = await client.checkBatteryOptimization();
if (!before.exempted) {
  // Invoke from an explanatory, user-triggered button.
  await client.requestBatteryOptimizationExemption();
}

// Invoke from a separate button or an app-resume flow after Settings closes.
Future<void> recheckBatteryAfterSettingsReturn() async {
  final after = await client.checkBatteryOptimization();
  renderBatteryStatus(after);
}
```

The plugin does not add
`android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. Without it, the
request opens general battery settings. Add the direct exemption permission
only if the application's core function qualifies under Google Play policy.

Android restoration reconnects to the native foreground service. Run the
startup restoration sequence before initializing a replacement context.
Tracking requires an ARM64 device; Intel Android emulators are unsupported.

## iOS configuration and foreground recovery

Add `NSMicrophoneUsageDescription` and the `audio` background mode. Coordinate
other audio features because the native SDK activates
`AVAudioSession.playAndRecord` and does not restore the previous session.

iOS process restoration is not supported. Foreground recovery is supported for
a live session whose status is `paused` or `recoveryRequired`. Guard the app
lifecycle callback by platform, lifecycle state, SDK state, and an in-flight
flag:

```dart
bool resumeInFlight = false;
bool awaitingRecoveryUpload = false;

Future<void> onAppLifecycleState(
  AppLifecycleState lifecycle,
  AsleepSnapshot snapshot,
) async {
  if (!Platform.isIOS ||
      lifecycle != AppLifecycleState.resumed ||
      resumeInFlight ||
      awaitingRecoveryUpload ||
      (snapshot.trackingStatus != TrackingStatus.paused &&
          snapshot.trackingStatus != TrackingStatus.recoveryRequired)) {
    return;
  }

  resumeInFlight = true;
  awaitingRecoveryUpload = true;
  try {
    await client.resumeTracking();
  } catch (_) {
    // No upload proof can arrive for a resume command that did not succeed.
    // Release the latch so a later foreground callback can retry.
    awaitingRecoveryUpload = false;
    rethrow;
  } finally {
    resumeInFlight = false;
  }
}
```

An early or duplicate `TrackingResumedEvent` is not recovery completion. Keep
the application in "waiting for recovery proof" until a later
`TrackingUploadedEvent` arrives:

```dart
void handleRecoveryEvent(AsleepEvent event) {
  final newRecoveryEpoch =
      event is TrackingInterruptedEvent ||
      (event is TrackingFailedEvent &&
          event.error.category == AsleepErrorCategory.recoveryRequired);
  if (newRecoveryEpoch && awaitingRecoveryUpload) {
    // A new pause epoch supersedes the upload expected by the prior resume.
    // Release now; the next foreground callback will re-arm the latch.
    awaitingRecoveryUpload = false;
    return;
  }

  if (event is TrackingUploadedEvent && awaitingRecoveryUpload) {
    awaitingRecoveryUpload = false;
    renderRecoveryComplete();
    return;
  }

  final sessionEnded =
      event is TrackingClosedEvent ||
      (event is TrackingFailedEvent &&
          (event.error.category == AsleepErrorCategory.terminal ||
              event.error.category == AsleepErrorCategory.recordingDead));
  if (sessionEnded) {
    // Release stale state without presenting the ended session as recovered.
    awaitingRecoveryUpload = false;
  }
}
```

If another `TrackingInterruptedEvent` or recovery-required failure arrives
while upload proof is pending, the session entered a new recovery epoch.
Release the prior latch and let the next foreground callback issue one new
resume and re-arm upload proof.

## Start, resume, stop, and analysis

Start only after restoration, setup, battery status, and permissions have been
handled:

```dart
await client.startTracking();
```

Call `resumeTracking()` only for `paused` or `recoveryRequired`. Call
`stopTracking()` for a live session. A `recordingDead` error still requires
`stopTracking()` before another start even though the projected status is
`idle`.

Request analysis while the session is actively tracking:

```dart
final acknowledgement = await client.requestAnalysis();
if (acknowledgement.immediateResult case final result?) {
  // Android may provide an immediate result.
  consumeAnalysis(result);
}
```

Android may return an immediate result after native retry processing. iOS
returns an acknowledgement and later emits `AnalysisResultEvent`. The event is
the canonical result path on both platforms.

## Reports and irreversible deletion

The three report forms have different purposes:

```dart
final detail = await client.getReport(sessionId);
final sessions = await client.getReportList('2026-07-01', '2026-07-31');
final average = await client.getAverageReport('2026-07-01', '2026-07-31');
```

Dates use the native report API's `YYYY-MM-DD` convention. Report availability
is eventually consistent with tracking close and backend processing. Treat a
not-ready response as a bounded, app-owned retry state, not an infinite loop.

Never make deletion the direct effect of a list-row tap. Require a dedicated
irreversible-action confirmation and call the SDK exactly once only after
confirmation:

```dart
Future<void> deleteAfterConfirmation(
  AsleepClient client,
  String sessionId,
  Future<bool> Function() confirmIrreversibleAction,
) async {
  if (!await confirmIrreversibleAction()) {
    return;
  }
  await client.deleteSession(sessionId);
  // Update app state only after the command succeeds.
}
```

## Diagnostic logging

Logging is opt-in and should be limited to a controlled diagnostic session:

```dart
await client.setLoggingEnabled(true);
try {
  await runUserApprovedDiagnostic();
} finally {
  await client.setLoggingEnabled(false);
}
```

Do not show or store raw `DebugLogEvent.message`, unknown native payloads,
credentials, native details, or report contents in ordinary logs. Apply the
application's retention, consent, and access-control policy before collecting
any diagnostic artifact.

## Deterministic cleanup

The same application owner that created the client cleans it up. Disable
logging first, cancel app subscriptions, then dispose the client. Make the
owner's cleanup idempotent so widget and application shutdown cannot run it
twice:

```dart
bool closing = false;
final activeOperations = <Future<void>>{};
Future<void>? closeFuture;

Future<void> close() {
  closing = true; // Command entry points must reject new work from here.
  return closeFuture ??= () async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> cleanUp(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await cleanUp(() async {
      await Future.wait(activeOperations.toList());
    });
    await cleanUp(() => client.setLoggingEnabled(false));
    await cleanUp(stateSubscription.cancel);
    await cleanUp(eventSubscription.cancel);
    await cleanUp(client.dispose);

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }();
}
```

Track every setup, permission, battery, lifecycle, report, deletion, and logging
operation in `activeOperations`. Reject new commands once `closing` is true,
drain the tracked operations, and only then dispose the client. Do not issue
commands after disposal. Widget shutdown cannot await `close()`; attach an
error handler so a cleanup failure does not become an unhandled asynchronous
error, and never print raw native error details.

## Responsibility boundary

| SDK duties | Application duties |
|---|---|
| Native setup, configuration, tracking, analysis, and report commands | Single-client ownership and dependency scope |
| Typed snapshots, events, and structured errors | Screens, permission rationale, and settings navigation explanation |
| Native restoration and foreground-recovery command | Lifecycle observation, deduplication, and upload-proof UI |
| Permission and battery-status primitives | User consent, policy eligibility, and recheck timing |
| Report retrieval and deletion command | Report persistence, retention, redaction, confirmation, and retries |
| Opt-in diagnostic event transport | Logging consent, filtering, secure storage, and support workflow |

## Production checklist

- [ ] One application-level owner creates one `AsleepClient`.
- [ ] State and event subscriptions are attached before restoration and setup.
- [ ] API keys are supplied at runtime and never logged or persisted.
- [ ] Android permissions, notification behavior, foreground service, and
      battery settings are tested separately on supported ARM64 devices.
- [ ] iOS microphone text, background audio, audio-session coordination, and
      guarded foreground recovery are tested.
- [ ] A post-resume `TrackingUploadedEvent` is required before showing recovery
      success.
- [ ] Start, stop, recording-dead cleanup, and bounded transient retries are
      verified from current snapshot state.
- [ ] Android immediate analysis and cross-platform `AnalysisResultEvent`
      handling are covered.
- [ ] Detailed, list, and average reports are covered without logging report
      data.
- [ ] Destructive deletion has an irreversible confirmation and updates UI only
      after success.
- [ ] Raw debug/native details are filtered under the application's privacy and
      retention policy.
- [ ] Cleanup runs once in the order logging off, subscriptions cancelled,
      client disposed.
- [ ] The release workflow's physical-device qualification evidence covers the
      intended Android and iOS production devices.

The implementation in `lib/diagnostic/diagnostic_controller.dart` and
`lib/diagnostic/diagnostic_app.dart` is compiled and exercised by the example
tests, so changes to the documented public calls fail CI instead of silently
drifting.
