# Asleep Flutter SDK Implementation Plan

Verified on: 2026-07-30

## Scope

Build an Android and iOS Flutter plugin that translates the developer journey
of `asleep-sdk-react-native` into idiomatic Dart while preserving the actual
contracts and platform differences of the Asleep Android and iOS SDKs.

The plugin is a headless primitive SDK. Applications own user interface,
business workflow, persistence, analytics, retry policy, and product-specific
state management.

## Verifiable Success Criteria

1. The public API covers setup, configuration, permissions, tracking lifecycle,
   restoration, analysis requests, reports, sessions, errors, logs, and native
   lifecycle events without exposing channel payload maps.
2. Every native call and callback has a typed Dart contract, deterministic
   serialization, documented platform behavior, and a stable unknown-value
   fallback.
3. Commands are asynchronous and lifecycle state is exposed as an immutable
   snapshot plus broadcast streams. The runtime package does not require an
   application state-management dependency.
4. Duplicate or invalid lifecycle commands fail predictably, event subscriptions
   are disposed with the client, and platform detach/re-attach behavior is
   documented.
5. Microphone permission checks and requests are separate. Starting tracking
   does not trigger application UI or silently request permission.
6. iOS error mapping uses the native SDK's documented numeric accessor when
   available and never derives a public numeric code from a Swift enum ordinal.
7. Android fatal-failure/close ordering and iOS analysis-result delivery
   differences are normalized or explicitly represented and covered by tests.
8. Unit and contract tests cover serialization, lifecycle transitions, error
   fallback, event ordering, disposal, and platform-specific result behavior.
9. `dart format`, `flutter analyze`, and `flutter test` pass. Android and iOS
   compile boundaries are exercised where native artifacts and credentials
   permit, with exact blockers recorded otherwise.
10. The example demonstrates setup, explicit permissions, start/stop, live
    state, event handling, and cleanup without defining the SDK architecture.
11. README, API usage, compatibility and migration notes, architecture ADRs,
    changelog, package metadata, and native integration requirements are
    sufficient for the experimental public 0.1.0 candidate.
12. Tag creation, publication, and other external release mutations remain
    separate approval-gated operations after the candidate is verified.

## Design Stages

1. Build a contract matrix from the React Native wrapper and both native SDKs.
2. Record decisions for state ownership, platform messaging, lifecycle,
   compatibility, and unknown metadata.
3. Scaffold with the stable Flutter tool's native plugin template.
4. Write public-contract and state-machine tests before implementation.
5. Implement Dart models, client, platform boundary, and event projection.
6. Implement Kotlin and Swift adapters against verified native APIs.
7. Complete the example and developer documentation.
8. Run static, unit, contract, and native build verification; self-review the
   complete local diff.

## Initial Assumptions

- The selected package name is `asleep_sdk_flutter`; the folder is
  `asleep-sdk-flutter`, and the verified publisher is `asleep.ai`.
- The first public candidate is experimental version `0.1.0`. Its `0.x` status
  allows compatibility to evolve but does not relax publication gates.
- Android API 24 and iOS 15 are the conservative local floors after
  reconciliation with the current native SDK projects.
- The Flutter SDK's built-in `Stream` and immutable value objects are the
  baseline state surface. Third-party state management remains outside the
  runtime dependency graph unless research demonstrates a contract-level need.
- Pigeon 27.3.0 is the selected internal transport. Generated types do not leak
  into the public API; the decision and regeneration constraints are recorded
  in ADR 0002.

## Remaining Decisions Before Publication

- Public source repository URL, issue tracker, support, security, and
  documentation URLs. Private GitHub URLs are intentionally omitted from
  public package metadata.
- Public redistribution approval for the Dart wrapper and both native SDK
  dependency paths.
- Final Flutter/Dart lower bounds across the intended consumer fleet.
- Long-term Android/iOS compatibility and deprecation policy beyond the pinned
  Android 3.2.1 and iOS 3.2.0 experimental baseline.
