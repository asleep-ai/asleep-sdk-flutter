# ADR 0002: Use Pigeon in a Single Android and iOS Plugin Package

- Status: Accepted
- Date: 2026-07-29
- Decision owners: Asleep SDK maintainers

## Context

The Dart API must call Android and iOS SDK functions and receive asynchronous
native lifecycle events. The transport must preserve nullability, enum and
object shapes, asynchronous completion, platform errors, and event ordering
without leaking stringly typed channel maps into the public API.

The initial release supports Android and iOS only. There is no current
requirement for independently versioned, third-party platform implementations.
The local toolchain is Flutter 3.44.8 with Dart 3.12.2. Pigeon 27.3.0 was
verified on 2026-07-29.

## Decision

Use Pigeon 27.3.0 as a development-time code generator inside one Flutter plugin
package.

- `AsleepHostApi` defines asynchronous Dart-to-native commands.
- `AsleepEventChannelApi` defines the native-to-Dart event stream.
- Generated Dart, Kotlin, and Swift code remains in this package and is
  regenerated together from the same Pigeon schema and version.
- The generated transport is private implementation detail. Public Dart models
  and errors are mapped explicitly at the transport boundary.
- Android and iOS implementations retain their verified platform differences;
  the Pigeon schema does not pretend that unsupported native behavior exists.
- Long-running SDK work completes through native callbacks and asynchronous
  replies. Channel handlers must not block the platform main thread.

The plugin remains a single, non-federated package until independent platform
versioning or third-party implementations become a demonstrated requirement.
The exported `AsleepPlatform` interface is the supported fake/test seam and is
therefore a SemVer-governed public API. It is not a separate published
platform-interface package.

## Why Pigeon

Pigeon generates structured, type-safe wrappers over Flutter platform channels.
It removes duplicated method-name strings and most manual codec casts while
supporting custom classes, enums, asynchronous host methods, and Kotlin/Swift
event channels.

Manual `MethodChannel` and `EventChannel` code would work, but it would require
maintaining names, nullability, payload casts, result callbacks, and errors
independently in Dart, Kotlin, and Swift. That increases contract drift and
makes refactors harder to verify.

Pigeon has an important compatibility rule: generated code produced by
different Pigeon versions has undefined behavior and can crash clients.
Official guidance specifically warns against placing generated Dart code in a
platform-interface package while placing generated host code in separate
platform packages. Keeping all generated output together and regenerating it
atomically follows that rule.

Official sources:

- [Developing Flutter packages and plugins](https://docs.flutter.dev/packages-and-plugins/developing-packages)
- [Flutter platform channels and Pigeon](https://docs.flutter.dev/platform-integration/platform-channels)
- [Pigeon 27.3.0](https://pub.dev/packages/pigeon)
- [Flutter concurrency and plugin use in isolates](https://docs.flutter.dev/perf/isolates)
- [Testing Flutter plugins](https://docs.flutter.dev/testing/testing-plugins)
- [Supported Flutter deployment platforms](https://docs.flutter.dev/reference/supported-platforms)

## Isolate and Event Ownership

The root isolate owns `AsleepClient`, the native event subscription, and the
public event and state streams.

Flutter allows a background isolate to send a platform request and receive its
response after initializing `BackgroundIsolateBinaryMessenger` with a root
isolate token. It does not allow a background isolate to receive unsolicited
host-to-Flutter messages. Asleep tracking callbacks are unsolicited lifecycle
events, so the SDK does not support moving event ownership to a background
isolate.

Consumers may perform their own CPU-only transformations in another isolate,
but they must forward data from the root-isolate subscription themselves.

## Engine and Native Resource Lifecycle

Flutter can create multiple engines. Each engine receives its own plugin
instance and can have an independent lifetime, but the native Asleep SDK is a
process-global singleton with global delegate/listener slots.

- Engine-specific messenger, handler, sink, and subscription state belongs to
  the plugin instance, not a process-global static.
- Registration installs the generated host API and event handler for that
  engine.
- Engine detach removes handlers, clears the event sink, and releases
  engine-owned resources.
- The first engine to initialize or configure claims process-wide native
  ownership. Initialization/configuration from another engine fails
  immediately and deterministically; it never overwrites the owner's listener.
- Ownership is released when the owner engine detaches. If native
  initialization is still in flight, release is deferred until its callback
  settles so that a replacement engine cannot receive a stale callback.
- Dart-side `AsleepClient.dispose()` cancels the native event subscription,
  calls platform disposal, and closes state and event streams. It does not
  detach the Flutter engine or transfer process-wide native ownership.
  Disposal is idempotent.

Native tracking ownership is not silently transferred or stopped merely
because a Dart listener pauses or cancels. Tracking continues until the
documented native lifecycle command or policy ends it.

## Cancellation

Pigeon makes a call asynchronous; it does not make the native operation
cancelable.

The SDK therefore does not return a fake `CancelableOperation` or claim that
canceling a Dart `Future` stops native work. Operations are cancelable only
when the underlying Android and iOS SDK contracts expose a real cancellation
or stop operation. Such operations must be represented by an explicit typed
method, for example `stopTracking`, and must have defined acknowledgement and
event-ordering behavior.

Canceling a Dart `StreamSubscription` only stops delivery to that subscriber.
It does not cancel the native tracking session.

## Alternatives Considered

| Alternative | Benefit | Reason rejected for the initial package |
| --- | --- | --- |
| Manual `MethodChannel` plus `EventChannel` | No generator and complete control of codecs | Duplicated string and payload contracts across three languages; weaker compile-time drift detection |
| Package-separated federated plugin | Independent platform releases and third-party implementations | No current independent-platform requirement; more packages and version coordination; conflicts with Pigeon's generated-code co-location guidance |
| Separate platform-interface package with generated Pigeon Dart code | Familiar federated layout | Pigeon explicitly warns that independently updated generated Dart and native code can have undefined behavior and crash |
| FFI | Direct native ABI calls | The native SDKs expose Android/iOS framework APIs and callbacks, not a stable shared C ABI; Flutter plugin APIs and platform lifecycle integration are still required |

## Compatibility Floors

The installed Flutter toolchain is 3.44.8 with Dart 3.12.2. The current local
draft declares Dart `^3.12.2`, Flutter `>=3.44.0`, Android API 24, and iOS 15.
These are conservative development inputs, not a final consumer support policy.
The iOS value follows the current native Asleep SDK project target rather than
Flutter's lower framework floor.

Flutter 3.44 documents Android API 24 and iOS 13 as framework-supported
deployment floors. The provisional plugin floor must be the stricter of:

1. The final Flutter/Dart language and API requirements used by this package.
2. The verified Android Asleep SDK minimum SDK.
3. The verified iOS Asleep SDK deployment target.
4. The intended Asleep consumer compatibility policy.

Until those inputs are confirmed, Android and iOS minimum versions, the final
Flutter/Dart lower bounds, native artifact versions, package identifiers, and
distribution metadata remain provisional and must not be advertised as a
public compatibility guarantee.

## Consequences

- Transport contract changes are reviewed in one schema and regenerated across
  Dart, Kotlin, and Swift.
- Generated code must be committed and updated atomically with its schema.
- Tests can inject `AsleepPlatform` fakes for public-contract tests and use
  native or integration tests for generated-channel boundaries.
- Adding a new independently maintained platform later may require revisiting
  package federation without splitting one Pigeon generation across packages.
- Native cancellation, resource ownership, and lifecycle behavior remain
  explicit design responsibilities; code generation does not solve them.
