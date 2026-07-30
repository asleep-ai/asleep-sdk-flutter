# Architecture

## Runtime shape

```text
Application state/UI
        |
        v
AsleepClient
  - immutable current snapshot
  - broadcast state stream
  - broadcast raw event stream
  - lifecycle guards
        |
        v
AsleepPlatform
        |
        v
Pigeon generated transport
        |
        +-------------------+
        v                   v
Kotlin adapter          Swift adapter
Android Asleep SDK      iOS Asleep SDK
foreground service      process-local audio session
```

`AsleepClient` is the only public lifecycle coordinator. It does not own product
workflow or persist application state. `AsleepPlatform` is injectable so Dart
contract tests do not require a Flutter engine or a native artifact.

## Command and event separation

Commands use `Future<T>` and complete when the platform adapter reports command
completion. Native delegate callbacks are delivered independently as
`AsleepEvent` values. Durable event consequences are projected into one
`AsleepSnapshot`.

This separation is required because native completion differs:

- iOS setup starts asynchronously; the bridge completes `initialize()` only
  after setup and native configuration-manager creation have succeeded, while
  still emitting setup progress/completion events.
- Android setup can resolve from its completion callback.
- Android analysis can return a full immediate result.
- iOS analysis returns an acknowledgement and later emits the result.

Application code first awaits `checkAndRestoreTracking()`. It then awaits
`configure()` for a surviving Android session or `initialize()` for a fresh
session. Setup events remain the progress and projected lifecycle surface, and
analysis events are the cross-platform source of truth for deferred results.

## Ownership and lifecycle

An application owner creates one `AsleepClient`, subscribes to its streams, and
disposes it. The client owns Dart subscriptions and stream controllers. Each
Flutter engine receives a native plugin instance and event sink, but the Asleep
native SDK is process-global. The first engine that calls `initialize()` or
`configure()` becomes the process owner. A second engine receives an immediate
native failure instead of replacing the first engine's native listeners.

Ownership is retained until the owning engine detaches. If detach occurs during
native initialization, ownership remains reserved until that asynchronous
operation settles, preventing a later engine from receiving the earlier
operation's callback. `AsleepClient.dispose()` closes Dart subscriptions and
streams; it does not detach the Flutter engine or transfer native ownership.

Unsolicited native events are root-isolate owned. Background isolates can perform
supported request/response channel work only after Flutter messenger setup, but
they are not a supported owner for the tracking event stream.

No public native operation exposes a cancellation token. The SDK does not claim
that cancelling a Dart `Future` cancels native work. `stopTracking()` terminates
tracking; cancelling a stream subscription stops delivery to that subscriber;
`dispose()` releases the client's Dart bridge resources.

## Serialization

Pigeon provides typed command DTOs and a typed event envelope. Rich native report
models cross the bridge as JSON because Android uses Gson snake_case models and
iOS uses Codable date/enums. Dart normalizes snake_case recursively and preserves
unknown fields in compatibility-oriented models.

Generated Pigeon files are internal. Consumer code imports only
`asleep_sdk_flutter.dart`.

## Error boundary

The bridge exposes semantic codes first, an optional native numeric diagnostic,
and additional platform details. Unknown values remain representable.

iOS numeric diagnostics must use `AsleepError.errorCode.code`, which is the
native SDK's Android-compatible accessor. Swift enum ordinals and bridged
`NSError.code` are not stable domain values.
