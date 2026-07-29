# ADR 0001: Expose SDK State with Dart Primitives

- Status: Accepted
- Date: 2026-07-29
- Decision owners: Asleep SDK maintainers

## Context

The SDK has two different kinds of observable information:

1. Durable lifecycle state, such as setup progress, the active tracking status,
   the current session identifier, and the latest error.
2. Ephemeral native events, such as tracking creation, upload, interruption,
   resume, close, and failure callbacks.

Applications need both a synchronous view of the current lifecycle and an
ordered asynchronous event surface. They must also be able to use their own
state-management architecture without adding adapters for types chosen by this
SDK.

The local toolchain used to create and verify this package is Flutter 3.44.8
with Dart 3.12.2. Package compatibility floors remain provisional until the
supported consumer fleet and both native SDK requirements are confirmed.

## Decision

The runtime SDK has no third-party state-management dependency.

- `AsleepSnapshot` is an immutable value that represents durable current state.
- `AsleepClient.state` returns the current snapshot synchronously.
- `AsleepClient.states` is a broadcast `Stream<AsleepSnapshot>` of subsequent
  snapshot changes.
- `AsleepClient.events` is a separate broadcast `Stream<AsleepEvent>` for
  ephemeral native events.
- Commands and one-shot results use `Future<T>`.
- The client owns its native subscription and stream controllers.
  `AsleepClient.dispose()` cancels the native subscription, disposes the
  platform transport, and closes both public streams.
- Consumer subscriptions remain consumer-owned and must be canceled by the
  consumer.

A stream is not used as a replay cache. A new subscriber reads
`AsleepClient.state` for the current snapshot and subscribes to
`AsleepClient.states` for later changes.

The public API does not expose `ChangeNotifier`, `ValueNotifier`, Riverpod,
Bloc, Cubit, signals, or another application-framework type. Applications may
adapt the primitive API at their own boundary.

## Alternatives Considered

Versions and package activity in this section were verified from official
project documentation and pub.dev on 2026-07-29.

| Approach | Current evidence | Advantages | Why it is not the runtime contract |
| --- | --- | --- | --- |
| Dart `Future` and `Stream` | Dart 3.12.2 standard library | No package dependency; pure Dart contracts; ordered values, errors, completion, subscription pause/resume/cancel, and standard test matchers | Selected baseline |
| `ValueNotifier` / `ChangeNotifier` | Flutter SDK 3.44.x | No external package; direct integration with Flutter builders; explicit owner disposal | Flutter-only, synchronous listener model, and no native representation for stream errors or completion. `ValueNotifier` only notifies when a replacement compares unequal and therefore assumes immutable values |
| Riverpod | `riverpod` and `flutter_riverpod` 3.4.2, published 2026-07-28 | Strong async-state representation, automatic disposal, overrides, and test containers; the core package supports Dart | Public Riverpod types would impose a provider architecture and transitive dependencies. Version 3.4.2 requires Dart `^3.12.0`, which would also raise the SDK floor for consumers |
| Bloc / Cubit | `bloc` 9.2.1; `flutter_bloc` 9.1.1 | Mature unidirectional state model, current-state access, streams, explicit close, and strong test support; `bloc` supports pure Dart | Exposing `Cubit` or `Bloc` would make a presentation architecture part of the SDK compatibility contract |
| signals.dart | `signals` 7.1.0 and `signals_core` 7.0.0 | Fine-grained reactivity, computed values, effects, cleanup, and a pure-Dart core | Signal identity, dependency tracking, and package lifecycle would become public SDK behavior. The ecosystem is active but has a faster-moving compatibility surface than Dart primitives |
| Solidart | `solidart` 2.8.6; `3.0.0-dev.1` also available | Pure-Dart signals, computed values, effects, and async resources | Smaller ecosystem, an active next-major preview, and unnecessary signal semantics in the SDK contract |
| ReArch | `rearch` 1.16.1; `flutter_rearch` 1.7.3 | Pure-Dart core, dependency inversion, async values, disposal, and mockable containers | Capsules and side effects define an application architecture rather than a neutral SDK boundary |
| state_beacon | `state_beacon` 3.1.1 | Signal composition, Future/Stream adapters, explicit disposal, and test utilities | Flutter-facing dependency graph and a young, framework-specific public surface |

Official sources:

- [Dart streams](https://dart.dev/libraries/async/using-streams)
- [Creating streams in Dart](https://dart.dev/libraries/async/creating-streams)
- [`StreamSubscription.cancel`](https://api.dart.dev/dart-async/StreamSubscription/cancel.html)
- [`ValueNotifier` limitations](https://api.flutter.dev/flutter/foundation/ValueNotifier-class.html)
- [`ChangeNotifier.dispose`](https://api.flutter.dev/flutter/foundation/ChangeNotifier/dispose.html)
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
- [Riverpod](https://pub.dev/packages/riverpod)
- [flutter_riverpod](https://pub.dev/packages/flutter_riverpod)
- [Riverpod automatic disposal](https://riverpod.dev/docs/concepts2/auto_dispose)
- [bloc](https://pub.dev/packages/bloc)
- [flutter_bloc](https://pub.dev/packages/flutter_bloc)
- [signals](https://pub.dev/packages/signals)
- [signals_core](https://pub.dev/packages/signals_core)
- [solidart](https://pub.dev/packages/solidart)
- [ReArch](https://pub.dev/packages/rearch)
- [state_beacon](https://pub.dev/packages/state_beacon)

## Example Application

The example application is not part of the SDK state contract. Its architecture
may change without changing the plugin API.

The baseline example uses Flutter and Dart primitives so it does not imply that
consumers must adopt a state-management package. If a larger example later
needs application-level caching, dependency injection, or derived async state,
Riverpod, Bloc, or another package may be added to the example only. Optional
integration recipes should consume `state`, `states`, and `events`; they must
not change those public SDK types.

## Consequences

- Consumers keep control of their state architecture and dependency versions.
- Domain models remain easy to test without a widget tree or provider
  container.
- Current state and one-shot events cannot be confused.
- Cancellation and disposal are explicit rather than inferred from widget
  lifetime.
- The SDK must maintain its own small lifecycle projection and test event
  ordering, duplicate transitions, stream closure, and disposal.
