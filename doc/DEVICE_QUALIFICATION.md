# Physical-Device Qualification

This is the release-blocking runtime qualification procedure for
`asleep_sdk_flutter`. Build-only CI is necessary but cannot prove microphone,
foreground/background, process-restoration, upload, analysis, or full-night
behavior.

The checked-in `qualification/evidence.template.json` intentionally records
every scenario as `not_run`. It is not release evidence.

## Candidate and device matrix

Evidence is valid for one exact Git commit and this complete version tuple:

- package, Flutter, and exact Dart runtime versions;
- Android native SDK version and an `arm64-v8a` physical device;
- iOS native SDK version and an `arm64` physical iPhone;
- minimum/current device roles with manufacturer, model, OS version, and typed
  API/OS major version;
- the device roles on which each scenario was exercised.

The Android device must run API 33 or later for the notification-denial case
and API 34 or later for the microphone foreground-service case. The current
production role must run Android 16 (API 36) or newer. Use a second device when
a single physical device cannot cover both the minimum supported OS and the
current production OS. The iOS matrix must include iOS 15 and an iOS 26 or
newer current-production device over the supported-device set before support
is claimed for both.

## Credential and data rules

Use an issued QA API key only at runtime. Never commit it, write it into the
evidence JSON, attach it to logs, or pass it through ordinary pull-request CI.
The example app accepts the key in memory. Install and launch the candidate,
enter the key interactively, and clear application data after qualification.

Evidence must contain only redacted diagnostic output and HTTPS links to
access-controlled artifacts. Do not retain audio, raw samples, sleep stages,
reports, user identifiers, access tokens, or API keys. The evidence assertions
must state that credentials were injected at runtime, were not persisted, and
that sleep data was not retained.

Scenario `notes` are fail-closed: use an empty string only while preparing
incomplete evidence, or the exact canonical sentence for the scenario status:

- `Passed with redacted evidence.`
- `Failed with redacted evidence.`
- `Blocked without retaining sensitive data.`
- `Not run.`

Do not add free-form prose. The validator recursively rejects credential,
raw-data, report, sleep-score, and user/session identifier vocabulary in every
string field, including device metadata and evidence URLs. The workflow applies
the same quiet defense-in-depth scan without printing rejected values.
Evidence JSON must not repeat object member names; the validator rejects
duplicates before decoding or retaining the submitted bytes.

## Android procedure

Run every scenario from a clean install unless the scenario explicitly tests
restoration:

1. `cold_start_without_permissions`: clear app data, launch, confirm no
   permission was pre-granted, initialize, and capture the initial state.
2. `permission_denial_and_regrant`: deny microphone/notification prompts,
   confirm the typed denial result, grant them from the app/system flow, and
   recheck.
3. `notification_denial_api_33_plus`: deny notifications and prove that the
   result is not reported as microphone denial.
4. `microphone_fgs_api_34_plus`: start tracking while the app is eligible to
   use microphone foreground service and capture the service/notification
   state.
5. `battery_settings_return_and_recheck`: open battery settings, return without
   changing the setting, recheck, then change the setting and recheck again.
6. `process_kill_and_restore`: while tracking, kill only the Flutter UI
   process, reopen the app, call `checkAndRestoreTracking()`, configure the
   active session, and prove event delivery remains attached.
7. `start_upload_analysis_stop_report`: prove start, at least one redacted
   upload signal, analysis result, stop, and report retrieval.
8. `full_night_session`: run a representative overnight session on the
   physical device and prove the lifecycle completes without a retained raw
   payload.

Capture log timestamps, state transitions, device metadata, and result only.

## iOS procedure

Run every scenario on a signed physical-device build:

1. `cold_start_without_permissions`: clean install, confirm microphone is not
   pre-granted, initialize, and capture the initial state.
2. `permission_denial_and_recovery`: deny microphone, prove the typed denial,
   grant it in Settings, foreground the app, and recheck.
3. `background_audio`: start tracking, background the app, lock the device, and
   prove audio-background tracking remains active.
4. `interruption_and_foreground_resume`: exercise an audio interruption, return
   to the foreground, call `resumeTracking()`, and prove recovery without a
   duplicate active session.
5. `later_upload_recovery`: remove connectivity during tracking, restore it
   later, and prove queued upload recovery.
6. `analysis_ack_and_event`: prove the request acknowledgement and the later
   typed analysis event are both observed.
7. `stop_and_report`: stop the session and retrieve its report.
8. `full_night_session`: run a representative overnight session on the
   physical iPhone and prove completion without a retained raw payload.

## Evidence validation and approval

Copy the template outside the repository, fill it with redacted evidence, and
validate it against the exact candidate:

```sh
dart run tool/validate_device_qualification.dart \
  --evidence /secure/path/evidence.json \
  --expected-commit "$(git rev-parse HEAD)" \
  --expected-package-version 0.1.0 \
  --expected-flutter-version 3.44.8 \
  --expected-dart-version 3.12.2 \
  --expected-android-native-version 3.2.1 \
  --expected-ios-native-version 3.2.0
```

All scenarios must be `passed`, timestamps must use canonical uppercase-`Z`
UTC form (for example, `2026-07-31T01:00:00Z`), each scenario must link to a
stable HTTPS URL without a query/fragment, and minimum/current device roles
must both be covered.

An allowlisted reviewer other than the operator must post this exact,
versioned body in an issue comment in this repository:

```text
ASLEEP_DEVICE_QUALIFICATION_APPROVAL_V1
commit=<40-character candidate SHA>
evidence_sha256=<SHA-256 of evidence.json>
```

Set `DEVICE_QUALIFICATION_REVIEWERS` to a non-empty JSON array of unique,
non-empty GitHub logins. Login uniqueness and membership are
case-insensitive. Then dispatch the workflow from a branch or tag resolving to
the candidate:

```sh
candidate_ref=main
test "$(git rev-parse "$candidate_ref")" = "$(git rev-parse HEAD)"
evidence_base64="$(base64 < /secure/path/evidence.json | tr -d '\n')"
gh workflow run device-qualification.yml \
  --ref "$candidate_ref" \
  -f evidence_base64="$evidence_base64" \
  -f approval_comment_id="<same-repository comment ID>"
unset candidate_ref evidence_base64
```

The workflow accepts only a digits-only comment ID, strictly parses the JSON
reviewer allowlist, obtains the actual comment author from GitHub, and requires
a case-insensitively distinct `github.actor`. The approval comment's parsed
timestamp must be at or after the evidence completion timestamp. The workflow
binds the exact comment, reviewer, operator, commit, and evidence digest into
an immutable run attestation. A release re-fetches the same-repository comment
and workflow run, rechecks the timestamps as parsed instants, and fails if the
comment was edited/deleted, the allowlist changed, or any reviewer, operator,
digest, or run provenance differs. This works for private repositories on the
GitHub Team plan without environment reviewer support.

Ordinary pull-request CI validates only the incomplete template structure and
unit tests. It needs no device, QA API key, or release evidence.
