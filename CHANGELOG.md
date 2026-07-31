## Unreleased

- Verify the minimum Flutter/Dart baseline and build clean Android and iOS
  consumers from staged release candidates and exact hosted versions.
- Document the supported native build toolchains and the deliberate iOS 15
  deployment target.

## 0.1.0

- Publish the first experimental Flutter wrapper for AsleepSDK on Android and
  iOS.
- Add typed setup, configuration, permission, restoration, battery,
  tracking, analysis, report, session, error, and logging APIs.
- Align lifecycle behavior with `asleep-sdk-react-native`, including
  prerequisite checks, acknowledged native starts, automatic analysis
  cadence, recovery handling, and terminal-failure suppression.
- Add strict native payload validation, immutable public models, serialized
  lifecycle commands, and deterministic EventChannel cleanup.
- Reject conflicting setup, configuration, start, stop, restore, and analysis
  commands while preserving structured native failures and live restored
  sessions.
- Cancel timed-out or superseded native tracking starts so late callbacks
  cannot resurrect or resolve the wrong session.
- Expose the complete report-stat and sleep-session payload used by the
  supported native SDKs.
- Restore Android foreground-service listeners after UI-process recreation
  without treating iOS closed-session identifiers as active sessions.
- Preserve native SDK error codes and page report-list requests beyond the
  native 100-item page size.
- Keep notification permission optional for tracking and make direct Android
  battery-optimization exemption a consumer opt-in.
- Add Pigeon-generated Kotlin and Swift transport contracts, an example app,
  contract tests, CI validation, and guarded release workflows.

This is an experimental `0.x` release. APIs, behavior, platform requirements,
and native SDK compatibility may change without notice. Production deployment
requires Asleep credentials and application review.
